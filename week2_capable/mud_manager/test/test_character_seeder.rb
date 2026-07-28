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

  # ---- placement (batch_sesssion_testing.md §3.2) -------------------------

  def placement_config(location)
    config.merge(uplift: config[:uplift].merge(location: location))
  end

  # Sessions scripted for a full run whose player already exists, plus however
  # many extra admin prompts the placement step consumes.
  def placement_sessions(placement_reads)
    # `run` probes twice — once to decide whether to delete, once to verify the
    # deletion took — so an absent character still consumes two probe sessions.
    probes = Array.new(2) { ScriptedSession.new(reads: ["Name? ", "Did I get that right (Y/N)?"]) }
    creating = ScriptedSession.new(
      reads: [
        "Name? ", "Did I get that right (Y/N)?", "Give me a password for Andrew:",
        "Please retype password:", "Sex (M/F)?", "Select a class:", "Main Menu - Enter the game"
      ],
      prompts: [
        "Welcome.\r\n<100hp> ", "Level: 1\r\n<100hp> ", "You are not carrying anything.\r\n<100hp> ",
        "You can't practice here.\r\n<100hp> ", "You wield a dagger.\r\n<100hp> ",
        "Level: 10 Gold: 5000\r\n<100hp> ", "a bottle\r\n<100hp> ",
        "<wielded> a dagger\r\n<100hp> ", "kick 75%\r\n<100hp> "
      ]
    )
    # advance + two fields + skill + goto + two load/give pairs = 9, then placement
    admin = ScriptedSession.new(prompts: Array.new(9, "Okay.\r\n<100hp> ") + placement_reads)
    factory = lambda do |id|
      { "seed-probe" => probes, "seed-player" => [creating], "seed-admin" => [admin] }
        .fetch(id).shift || raise("unexpected session #{id}")
    end
    [factory, admin]
  end

  # `teleport <victim> <location>`, NOT `transfer` — the MUD's help file is
  # explicit that `trans` takes no destination and pulls the target to the
  # immortal instead. Since this step runs after `goto <player>` has already
  # moved the immortal TO the player, a `trans` here would "succeed" by leaving
  # the character exactly where it already was.
  def test_location_teleports_the_player_and_verifies_the_room
    factory, admin = placement_sessions([
      "Okay.\r\n<100hp> ",
      "The Temple\r\nAndrew the Believer is standing here.\r\n<100hp> "
    ])

    MudManager::CharacterSeeder.new(placement_config(3001), output: StringIO.new,
                                    session_factory: factory).run

    assert_includes admin.sent.map(&:first), "teleport Andrew 3001"
    assert_includes admin.sent.map(&:first), "at 3001 look"
    refute_includes admin.sent.map(&:first), "transfer Andrew 3001"
  end

  # THE regression the strip exists for. tbaMUD colours the character list, and
  # a colour code ends in `m` — a word character — so there is no word boundary
  # before the name in "\e[0;33mAndrew the Believer" and a naive `\bAndrew`
  # never matches. This is a real seed that failed against a live MUD while the
  # character was demonstrably standing in the room.
  def test_placement_matches_through_ansi_colour_codes
    factory, = placement_sessions([
      "Okay.\r\n<100hp> ",
      "\e[0;33mThe Temple\e[0m\r\n\e[0;33mAndrew the Believer is standing here.\r\n\e[0m<100hp> "
    ])

    MudManager::CharacterSeeder.new(placement_config(3001), output: StringIO.new,
                                    session_factory: factory).run
  end

  # Silent placement failure means every case in a batch starts somewhere
  # unintended and the whole run is garbage that looks like data.
  def test_a_player_absent_from_the_room_fails_the_seed
    factory, = placement_sessions([
      "Okay.\r\n<100hp> ",
      "The Temple\r\nA newbie dummy mob is here.\r\n<100hp> "
    ])

    error = assert_raises(MudManager::CharacterSeeder::Error) do
      MudManager::CharacterSeeder.new(placement_config(3001), output: StringIO.new,
                                      session_factory: factory).run
    end
    assert_match(/not in room 3001/, error.message)
  end

  def test_a_state_with_no_location_never_teleports
    factory, admin = placement_sessions([])

    MudManager::CharacterSeeder.new(config, output: StringIO.new, session_factory: factory).run

    refute_includes admin.sent.map(&:first), "at 3001 look"
    assert_empty admin.sent.map(&:first).grep(/\Ateleport /)
  end

  def test_a_non_integer_location_is_rejected_before_anything_connects
    assert_raises(MudManager::CharacterSeeder::Error) do
      MudManager::CharacterSeeder.new(placement_config("3001"), output: StringIO.new).validate!
    end
  end

end
