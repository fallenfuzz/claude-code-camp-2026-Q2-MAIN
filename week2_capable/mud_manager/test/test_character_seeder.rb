require_relative "helper"

class TestCharacterSeeder < Minitest::Test
  class ScriptedSession
    attr_reader :sent, :logins

    def initialize(reads: [], prompts: [])
      @reads = reads.dup
      @prompts = prompts.dup
      @sent = []
      @logins = []
    end

    def open = self
    def close = nil
    def drain = ""

    def login(name, password)
      @logins << [name, password]
    end

    def send_command(command, redact: false)
      raw = command.respond_to?(:raw) ? command.raw : command.to_s
      @sent << [raw, redact]
      raw
    end

    def read_until(_pattern, timeout: nil)
      raise "unexpected read_until" if @reads.empty?
      @reads.shift
    end

    def read_until_prompt(timeout: nil)
      raise "unexpected read_until_prompt" if @prompts.empty?
      @prompts.shift
    end

    def read_until_quiet(_quiet_seconds = 1.0, timeout: nil)
      read_until_prompt(timeout: timeout)
    end
  end

  def config
    {
      host: "localhost",
      port: 4000,
      timeout: 1,
      admin_name: "admin",
      admin_password: "admin-secret",
      player_name: "Andrew",
      player_password: "player-secret",
      gender: "M",
      player_class: "W",
      uplift: {
        level: 10,
        money: { gold: 5000 },
        stats: { exp: 1234 },
        skills: { "kick" => 75 },
        inventory: [{ vnum: 3001, keyword: "bottle", quantity: 1 }],
        equipment: [{ vnum: 3020, keyword: "dagger", quantity: 1, wear: "wield" }]
      }
    }
  end

  def test_full_run_deletes_recreates_and_uplifts
    probe_existing = ScriptedSession.new(reads: ["Name? ", "Password: "])
    deleting_reconnect = ScriptedSession.new(
      reads: [
        "Name? ",
        "Password: ",
        "You take over your own body, already in use!",
        "Goodbye, friend."
      ]
    )
    deleting = ScriptedSession.new(
      reads: [
        "Name? ",
        "Password: ",
        "Welcome to CircleMUD!",
        "Main Menu\r\n1) Enter the game",
        "Enter your password for verification: ",
        "Please type \"yes\" to confirm: ",
        "Character 'Andrew' deleted! Goodbye."
      ]
    )
    probe_absent = ScriptedSession.new(reads: ["Name? ", "Did I get that right (Y/N)?"])
    creating = ScriptedSession.new(
      reads: [
        "Name? ",
        "Did I get that right (Y/N)?",
        "Give me a password for Andrew:",
        "Please retype password:",
        "Sex (M/F)?",
        "Select a class:",
        "Main Menu - Enter the game"
      ],
      prompts: [
        "Welcome.\r\n<100hp> ",
        "Level: 1\r\n<100hp> ",
        "You are not carrying anything.\r\n<100hp> ",
        "You can't practice here.\r\n<100hp> ",
        "You wield a dagger.\r\n<100hp> ",
        "Level: 10 Gold: 5000\r\n<100hp> ",
        "a bottle\r\n<100hp> ",
        "<wielded> a dagger\r\n<100hp> ",
        "kick 75%\r\n<100hp> "
      ]
    )
    # advance + two fields + skill + goto + two pairs of load/give
    admin = ScriptedSession.new(prompts: Array.new(9, "Okay.\r\n<100hp> "))

    sessions = {
      "seed-probe" => [probe_existing, probe_absent],
      "seed-delete" => [deleting_reconnect, deleting],
      "seed-player" => [creating],
      "seed-admin" => [admin]
    }
    factory = ->(id) { sessions.fetch(id).shift || raise("unexpected session #{id}") }

    output = StringIO.new
    seeder = MudManager::CharacterSeeder.new(config, output: output, session_factory: factory)
    seeder.run

    assert_includes deleting_reconnect.sent, ["quit", false]
    assert_includes deleting.sent, ["5", false]
    assert_equal 2, deleting.sent.count { |raw, redacted| raw == "player-secret" && redacted }
    assert_includes deleting.sent, ["yes", false]
    assert_includes creating.sent, ["player-secret", true]
    assert_includes admin.sent.map(&:first), "advance Andrew 10"
    assert_includes admin.sent.map(&:first), "set Andrew gold 5000"
    assert_includes admin.sent.map(&:first), "skillset Andrew 'kick' 75"
    assert_includes admin.sent.map(&:first), "goto Andrew"
    assert_includes admin.sent.map(&:first), "load obj 3020"
    assert_includes creating.sent.map(&:first), "wield dagger"
    assert_equal %i[score_level_1 inventory_empty practice_refuse score inventory equipment practice],
                 seeder.captures.keys

    Dir.mktmpdir("seed-player-fixtures") do |directory|
      files = seeder.emit_fixtures(directory)
      assert_includes files, "score.txt"
      assert_includes files, "inventory_empty.txt"
      assert_includes files, "practice_refuse.txt"
      assert_equal seeder.captures[:equipment],
                   File.binread(File.join(directory, "equipment.txt"))
    end
  end

  def test_refuses_admin_as_player
    bad = config.merge(player_name: "ADMIN")
    error = assert_raises(MudManager::CharacterSeeder::Error) do
      MudManager::CharacterSeeder.new(bad).validate!
    end
    assert_match(/differ/, error.message)
  end

  def test_rejects_item_without_deterministic_keyword
    bad = config
    bad[:uplift][:inventory][0] = { vnum: 3001, quantity: 1 }
    error = assert_raises(MudManager::CharacterSeeder::Error) do
      MudManager::CharacterSeeder.new(bad).validate!
    end
    assert_match(/keyword/, error.message)
  end
end
