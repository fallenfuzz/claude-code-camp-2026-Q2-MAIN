require "fileutils"
require "tempfile"

module MudManager
  # Destructive, developer-only orchestration for replacing and populating one
  # fixture character. Protocol regexps are injected because login/creation
  # wording varies between CircleMUD/tbaMUD forks.
  class CharacterSeeder
    class Error < StandardError; end

    LOGIN_PROMPT = /By what name do you wish to be known.*\?/i
    EXISTS_OR_NEW = /Password|Did I get that right/i
    NEW_NAME_CONFIRM = /Did I get that right.*(?:\(|\[)?\s*y\s*\/\s*n/i
    NEW_PASSWORD = /(?:Give me a password(?:\s+for\s+\S+)?|New character.*password|Password)\s*:/i
    RETYPE_PASSWORD = /(?:retype|confirm).*(?:password)/i
    GENDER_PROMPT = /(?:sex|gender).*(?:male|female|m\s*\/\s*f)/i
    CLASS_PROMPT = /(?:select|choose|what is).*(?:class)|class.*(?:select|choose)/i
    PRESS_RETURN = /press return|press enter/i
    MAIN_MENU = /enter the game|main menu/i
    LOGIN_PASSWORD = /Password/i
    LOGIN_RESULT = /Welcome|Reconnecting|already in use|Wrong password/i
    DELETE_PASSWORD = /Enter your password for verification/i
    DELETE_CONFIRM = /Please type ["']?yes["']? to confirm|Incorrect password/i
    DELETE_SUCCESS = /character.*deleted|deleted.*character|goodbye/i
    COMMAND_REFUSAL = /Huh\?!|not a valid|invalid|no such|no one by that name|don't seem to have|cannot|can't|unable|failed/i

    attr_reader :captures

    def initialize(config, output: $stdout, session_factory: nil)
      @config = config
      @output = output
      @session_factory = session_factory || lambda { |id|
        Session.new(host: config.fetch(:host), port: config.fetch(:port),
                    timeout: config.fetch(:timeout, Session::DEFAULT_TIMEOUT),
                    session_id: id)
      }
      @captures = {}
    end

    def run
      validate!
      banner "Resetting #{@config[:player_name]}: delete -> recreate -> uplift"
      delete_existing_player if character_exists?
      raise Error, "deletion could not be verified" if character_exists?

      player = create_character
      admin = login(@config[:admin_name], @config[:admin_password], "seed-admin")
      apply_uplift(admin)
      dress_player(player)
      capture_player(player)
      verify_captures!
      print_summary
      self
    ensure
      player&.close
      admin&.close
    end

    def validate!
      required_strings = %i[host admin_name admin_password player_name player_password gender player_class]
      required_strings.each do |key|
        raise Error, "#{key} is required" if @config[key].to_s.strip.empty?
      end
      raise Error, "player name must differ from admin name" if same_name?(:player_name, :admin_name)
      raise Error, "port must be a positive integer" unless @config[:port].is_a?(Integer) && @config[:port].positive?
      validate_uplift!
      true
    end

    def character_exists?
      session = build_session("seed-probe")
      session.open
      session.read_until(LOGIN_PROMPT)
      session.send_command(@config[:player_name])
      response = session.read_until(EXISTS_OR_NEW)
      return true if response.match?(/Password/i)
      return false if response.match?(/Did I get that right/i)

      raise Error, "could not classify player existence: #{response.inspect}"
    ensure
      session&.close
    end

    def delete_existing_player
      banner "Deleting existing #{@config[:player_name]}"
      session = open_deletion_login
      login_response = session[:response]
      connection = session[:connection]
      if login_response.match?(/Wrong password/i)
        raise Error, "existing player authentication failed; refusing to seed over it"
      end

      if login_response.match?(/Reconnecting|already in use/i)
        # A previous failed seed may have left the character link-dead. Taking
        # over enters the game directly, so quit fully and login once more to
        # regain the main menu where deletion lives.
        connection.send_command("quit")
        connection.read_until(/Goodbye/i)
        connection.close
        session = open_deletion_login
        login_response = session[:response]
        connection = session[:connection]
        unless login_response.match?(/Welcome/i)
          raise Error, "could not return link-dead player to the main menu"
        end
      end

      # tbaMUD deletion is main-menu choice 5, not an in-world command.
      connection.send_command(:return)
      connection.read_until(MAIN_MENU)
      announce "main menu: delete character (5)"
      connection.send_command(5)
      connection.read_until(DELETE_PASSWORD)
      connection.send_command(@config[:player_password], redact: true)
      confirmation = connection.read_until(DELETE_CONFIRM)
      if confirmation.match?(/Incorrect password/i)
        raise Error, "deletion password verification failed"
      end
      connection.send_command("yes")
      response = connection.read_until(DELETE_SUCCESS)
      @output.puts response
    ensure
      connection&.close
    end

    def create_character
      banner "Creating #{@config[:player_name]} from scratch"
      session = build_session("seed-player")
      session.open
      session.read_until(LOGIN_PROMPT)
      session.send_command(@config[:player_name])
      session.read_until(NEW_NAME_CONFIRM)
      session.send_command("Y")
      session.read_until(NEW_PASSWORD)
      session.send_command(@config[:player_password], redact: true)
      session.read_until(RETYPE_PASSWORD)
      session.send_command(@config[:player_password], redact: true)
      session.read_until(GENDER_PROMPT)
      session.send_command(@config[:gender])
      session.read_until(CLASS_PROMPT)
      session.send_command(@config[:player_class])
      finish_creation_menu(session)

      score = issue(session, Primitives.info_self("score"), label: "Verify new player")
      raise Error, "new player is not level 1" unless score.match?(/\bLevel\s*[: ]\s*1\b|\blevel 1\b/i)
      @captures[:score_level_1] = score
      @captures[:inventory_empty] = issue(session, Primitives.info_self("inventory"))
      @captures[:practice_refuse] = issue(
        session, Primitives.practice, allow_refusal: true
      )
      session
    rescue StandardError
      session&.close
      raise
    end

    private

    def validate_uplift!
      uplift = @config.fetch(:uplift)
      level = uplift.fetch(:level)
      raise Error, "uplift level must be a positive integer" unless level.is_a?(Integer) && level.positive?

      uplift.fetch(:money, {}).merge(uplift.fetch(:stats, {})).each do |field, value|
        raise Error, "invalid uplift field #{field.inspect}" unless field.to_s.match?(/\A[[:alnum:]_]+\z/)
        raise Error, "#{field} must be an integer" unless value.is_a?(Integer)
      end
      uplift.fetch(:skills, {}).each do |skill, percent|
        raise Error, "skill name is required" if skill.to_s.strip.empty?
        raise Error, "#{skill} percent must be 0..100" unless percent.is_a?(Integer) && percent.between?(0, 100)
      end
      seed_items.each do |entry|
        raise Error, "item vnum must be positive" unless entry[:vnum].is_a?(Integer) && entry[:vnum].positive?
        raise Error, "item keyword must be one token" unless entry[:keyword].to_s.match?(/\A[[:alnum:]_]+\z/)
        raise Error, "item quantity must be positive" unless entry[:quantity].is_a?(Integer) && entry[:quantity].positive?
        next unless entry[:wear]
        raise Error, "unsupported wear operation #{entry[:wear].inspect}" unless Primitives::EQUIP_OPS.include?(entry[:wear])
      end
    end

    def seed_items
      uplift = @config.fetch(:uplift)
      uplift.fetch(:inventory, []) + uplift.fetch(:equipment, [])
    end

    def same_name?(left, right)
      @config[left].casecmp?(@config[right])
    end

    def build_session(id)
      @session_factory.call(id)
    end

    def open_deletion_login
      connection = build_session("seed-delete")
      connection.open
      connection.read_until(LOGIN_PROMPT)
      connection.send_command(@config[:player_name])
      connection.read_until(LOGIN_PASSWORD)
      connection.send_command(@config[:player_password], redact: true)
      { connection: connection, response: connection.read_until(LOGIN_RESULT) }
    rescue StandardError
      connection&.close
      raise
    end

    def login(name, password, id)
      session = build_session(id)
      session.open
      session.login(name, password)
      session
    rescue StandardError
      session&.close
      raise
    end

    def finish_creation_menu(session)
      response = session.read_until(/#{PRESS_RETURN.source}|#{MAIN_MENU.source}/i)
      if response.match?(PRESS_RETURN)
        session.send_command(:return)
        response = session.read_until(MAIN_MENU)
      end
      raise Error, "creation did not reach the main menu" unless response.match?(MAIN_MENU)
      session.send_command(1)
      session.read_until_prompt
    end

    def apply_uplift(admin)
      banner "Applying uplift"
      uplift = @config[:uplift]
      issue(admin, Primitives.advance(@config[:player_name], uplift[:level]))
      uplift.fetch(:money, {}).merge(uplift.fetch(:stats, {})).each do |field, value|
        issue(admin, Primitives.set_field(@config[:player_name], field.to_s, value))
      end
      uplift.fetch(:skills, {}).each do |skill, percent|
        issue(admin, Primitives.skillset(@config[:player_name], skill, percent))
      end
      # `load obj` creates objects in the immortal's inventory and `give`
      # targets only characters in the same room.
      issue(admin, Primitives.goto(@config[:player_name])) unless seed_items.empty?
      seed_items.each do |entry|
        entry[:quantity].times do
          issue(admin, Primitives.load_obj(entry[:vnum]))
          issue(admin, Primitives.give(entry[:keyword], @config[:player_name]))
        end
      end
    end

    def dress_player(player)
      banner "Equipping player"
      @config[:uplift].fetch(:equipment, []).each do |entry|
        entry[:quantity].times do
          issue(player, Primitives.equip(entry[:wear], entry[:keyword]))
        end
      end
    end

    def capture_player(player)
      banner "Capturing player state"
      @captures[:score] = issue(player, Primitives.info_self("score"))
      @captures[:inventory] = issue(player, Primitives.info_self("inventory"))
      @captures[:equipment] = issue(player, Primitives.info_self("equipment"))
      @captures[:practice] = issue(player, Primitives.practice, allow_refusal: true)
    end

    def verify_captures!
      level = @config.dig(:uplift, :level)
      unless @captures[:score].match?(/\bLevel\s*[: ]\s*#{Regexp.escape(level.to_s)}\b|\blevel #{Regexp.escape(level.to_s)}\b/i)
        raise Error, "final score does not show configured level #{level}"
      end

      @config[:uplift].fetch(:inventory, []).each do |entry|
        assert_capture_contains!(:inventory, entry[:keyword])
      end
      @config[:uplift].fetch(:equipment, []).each do |entry|
        assert_capture_contains!(:equipment, entry[:keyword])
      end
      unless @captures[:practice].match?(COMMAND_REFUSAL)
        @config[:uplift].fetch(:skills, {}).each_key do |skill|
          assert_capture_contains!(:practice, skill)
        end
      end
    end

    def assert_capture_contains!(capture, value)
      return if @captures.fetch(capture).match?(/\b#{Regexp.escape(value)}\b/i)
      raise Error, "#{capture} does not contain configured #{value.inspect}"
    end

    public

    def emit_fixtures(directory)
      raise Error, "run the seeder successfully before emitting fixtures" unless @captures[:score]
      FileUtils.mkdir_p(directory)
      files = {
        "score.txt" => @captures[:score],
        "inventory.txt" => @captures[:inventory],
        "inventory_empty.txt" => @captures[:inventory_empty],
        "equipment.txt" => @captures[:equipment]
      }
      practice_name = @captures[:practice].match?(COMMAND_REFUSAL) ? "practice_refuse.txt" : "practice_guild.txt"
      files[practice_name] = @captures[:practice]
      files["practice_refuse.txt"] ||= @captures[:practice_refuse]

      files.each { |name, contents| atomic_write(File.join(directory, name), contents) }
      files.keys
    end

    private

    def atomic_write(path, contents)
      Tempfile.create([".seed-player-", ".tmp"], File.dirname(path)) do |file|
        file.binmode
        file.write(contents)
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end

    def issue(session, command, label: nil, allow_refusal: false)
      banner label if label
      # Session#login may leave a late menu/prompt fragment in the buffer.
      # A seed command must be paired with its own response, never the tail of
      # the previous interaction.
      session.drain
      announce command.raw
      session.send_command(command)
      response = session.read_until_quiet(0.5)
      @output.puts response
      if !allow_refusal && response.match?(COMMAND_REFUSAL)
        raise Error, "command refused: #{command.raw.inspect}"
      end
      response
    end

    def print_summary
      banner "Seed complete"
      @output.puts "Created #{@config[:player_name]} from scratch."
      @output.puts "Configured level: #{@config.dig(:uplift, :level)}"
      @output.puts "Captured: #{@captures.keys.join(', ')}"
    end

    def banner(message)
      @output.puts "\n=== #{message} ==="
    end

    def announce(command)
      @output.puts "> #{command}"
    end
  end
end
