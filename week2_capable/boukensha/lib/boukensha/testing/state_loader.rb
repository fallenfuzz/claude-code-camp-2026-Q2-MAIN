module Boukensha
  module Testing
    # Puts the MUD into a scenario's starting state.
    #
    # `bin/seed_player` was a good mechanism trapped in a bad container: `HOST`,
    # `PORT`, `PLAYER_NAME`, `PLAYER_CLASS` and the whole `UPLIFT` hash were
    # frozen top-level constants you edited by hand before every run.
    # `MudManager::CharacterSeeder` underneath it was already fully
    # config-driven and needed no changes at all.
    #
    # So this is everything ABOVE `CharacterSeeder.new(config).run`, rebuilt to
    # take the same config hash from (resolved state + profile + settings)
    # instead of from constants. `bin/seed_player` keeps working because it is
    # now a thin shim over this.
    #
    # Host and port stop being duplicated constants and come from the `mud:`
    # MCP server block in settings.yaml, which is already the only place they
    # are configured for the agent itself.
    class StateLoader
      class Error < StandardError; end

      DEFAULT_TIMEOUT = 10.0
      ADMIN_NAME_DEFAULT = "admin".freeze
      ADMIN_PASSWORD_ENV = "MUD_PASSWORD_ADMIN".freeze

      # tbaMUD's class-selection menu takes a single letter, and profile.yaml
      # spells the class out. One table, here, rather than a second opinion in
      # every scenario file.
      CLASS_LETTERS = { "magic_user" => "M", "cleric" => "C", "thief" => "T", "warrior" => "W" }.freeze
      GENDER_LETTERS = { "m" => "M", "f" => "F", "n" => "M" }.freeze

      attr_reader :config_hash

      # state:   the resolved state hash (Overrides#resolve output, string keys)
      # profile: the profile mapping from profile.yaml (`player:` block)
      # mud:     the mud MCP server's env — MUD_HOST / MUD_PORT
      def initialize(state:, profile:, mud: {}, output: $stdout, seeder_class: nil)
        @state   = state || {}
        @profile = profile || {}
        @mud     = stringify(mud)
        @output  = output
        @seeder_class = seeder_class
        @config_hash  = build_config
      end

      def apply!
        seeder_class.new(@config_hash, output: @output).run
      rescue StandardError => e
        raise Error, "seeding #{@config_hash[:player_name]} failed: #{e.message}"
      end

      # The config hash `bin/seed_player` used to assemble from constants.
      # Public and built in the constructor so `--dry-run` can print exactly
      # what would be sent without opening a socket.
      def build_config
        name = @profile["name"] or raise Error, "profile has no player.name"

        {
          host:            @mud.fetch("MUD_HOST", "localhost"),
          port:            Integer(@mud.fetch("MUD_PORT", 4000)),
          timeout:         DEFAULT_TIMEOUT,
          admin_name:      ENV.fetch("MUD_ADMIN_NAME", ADMIN_NAME_DEFAULT),
          admin_password:  secret!(ENV.fetch("MUD_ADMIN_PASSWORD_ENV", ADMIN_PASSWORD_ENV)),
          player_name:     name.to_s,
          player_password: secret!(@profile["password_env"]),
          gender:          letter!(GENDER_LETTERS, @profile["gender"], "gender"),
          player_class:    letter!(CLASS_LETTERS, @profile["class"], "class"),
          uplift:          uplift
        }
      end

      # The state file's own vocabulary, converted to the seeder's. Symbol keys
      # and integer values, because `validate_uplift!` type-checks both and a
      # YAML string that looks like a number is exactly the failure this
      # conversion exists to prevent.
      def uplift
        {
          level:     Integer(@state.fetch("level", 1)),
          location:  (@state["location"] && Integer(@state["location"])),
          money:     integer_map(@state["money"]),
          stats:     integer_map(@state["stats"]),
          # Skill names stay strings, verbatim: "cure light" is two words in
          # tbaMUD and `skillset` is handed exactly what the file said.
          skills:    (@state["skills"] || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = Integer(v) },
          inventory: items(@state["inventory"]),
          equipment: items(@state["equipment"])
        }.compact
      end

      private

      # A caller that already loaded mud_manager from source (bin/seed_player
      # does, by relative path) must NOT have the installed gem loaded on top of
      # it. `require "mud_manager"` in that situation resolves to the gem, whose
      # copy of `CharacterSeeder` reopens the class and REDEFINES `apply_uplift`
      # — silently reverting the `location:` step to a version that has none, so
      # every case would start wherever the character happened to be while the
      # state file insisted otherwise. Checked, not required, when the constant
      # is already there.
      def seeder_class
        @seeder_class ||= begin
          require "mud_manager" unless defined?(MudManager::CharacterSeeder)
          MudManager::CharacterSeeder
        rescue LoadError => e
          raise Error, "the mud_manager gem is not available, so no state can be seeded (#{e.message})"
        end
      end

      def items(list)
        Array(list).map do |entry|
          entry = stringify(entry)
          out = {
            vnum:     Integer(entry.fetch("vnum")),
            keyword:  entry.fetch("keyword").to_s,
            quantity: Integer(entry.fetch("quantity", 1))
          }
          out[:wear] = entry["wear"].to_s if entry["wear"]
          out
        rescue KeyError => e
          raise Error, "state item #{entry.inspect} is missing #{e.key}"
        end
      end

      def integer_map(hash)
        (hash || {}).each_with_object({}) { |(k, v), out| out[k.to_sym] = Integer(v) }
      end

      def letter!(table, value, field)
        letter = table[value.to_s]
        return letter if letter

        raise Error, "profile player.#{field} #{value.inspect} is not one of #{table.keys.join(', ')}"
      end

      def secret!(variable_name)
        raise Error, "profile has no password_env" if variable_name.to_s.empty?

        value = ENV[variable_name.to_s]
        raise Error, "#{variable_name} is missing or empty in the boukensha .env" if value.to_s.empty?

        value
      end

      def stringify(hash)
        (hash || {}).each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end
    end
  end
end
