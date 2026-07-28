require_relative "helper"
require "json"

# §1: how and by whom a session was started, and what it is called.
#
# Today a hand-driven exploration and an automated case are indistinguishable on
# disk, and the moment batch runs exist the session list is 95% robot. These are
# the two fields that fix that, and both are additive — a log written before
# they existed must parse exactly as it did.
class TestSessionNaming < Minitest::Test
  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.remove_entry(@dir)

  def test_the_launch_object_lands_in_session_start_through_the_existing_snapshot
    provenance = Boukensha::Launch.test(profile: "Derrano", session_name: "find_bakery #3",
                                        scenario: "find_bakery", run_id: "20260728T143000Z-a1b2c3d4",
                                        case_index: 3, goal: "Find the bakery.")

    start = first_event(model: "claude-haiku-4-5", **provenance)

    assert_equal "find_bakery #3", start["session_name"]
    assert_equal "test", start.dig("launch", "mode")
    assert_equal "boukensha-test", start.dig("launch", "runner")
    assert_equal "find_bakery", start.dig("launch", "scenario")
    assert_equal 3, start.dig("launch", "case_index")
    assert_equal "claude-haiku-4-5", start["model"], "the existing snapshot fields survive"
  end

  # An interactive launch is deliberately thin: there is no scenario, no run and
  # no batch, and saying so by omission is more honest than filling those fields
  # with nils.
  def test_an_interactive_launch_says_only_what_is_true
    provenance = Boukensha::Launch.interactive(profile: "Dummy")
    launch     = first_event(**provenance)["launch"]

    assert_equal "interactive", launch["mode"]
    assert_equal "human", launch["runner"]
    assert_equal "Dummy", launch["profile"]
    refute launch.key?("scenario")
    refute launch.key?("case_index")
  end

  def test_a_session_with_no_launch_writes_exactly_what_it_used_to
    start = first_event(model: "claude-haiku-4-5")

    refute start.key?("launch")
    refute start.key?("session_name")
    assert_equal "session_start", start["phase"]
  end

  def test_an_unknown_mode_is_rejected_rather_than_written
    assert_raises(ArgumentError) { Boukensha::Launch.build(mode: "robot", runner: "x") }
  end

  # The name is mutable and the log is append-only, so the name is the LAST one
  # the file mentions. A crashed rename cannot corrupt an earlier one, and the
  # rename is itself timestamped history.
  def test_rename_appends_rather_than_rewriting
    path = File.join(@dir, "s.jsonl")
    logger = Boukensha::Logger.new(log: path, snapshot: { session_name: "first" })
    logger.rename(name: "second")
    logger.rename(name: "third", source: "harness")
    logger.close

    events = File.readlines(path).map { |l| JSON.parse(l) }
    renames = events.select { |e| e["phase"] == "session_rename" }

    assert_equal "first", events.first["session_name"]
    assert_equal %w[second third], renames.map { |e| e["session_name"] }
    assert_equal %w[user harness], renames.map { |e| e["source"] }
    assert renames.all? { |e| e["at"] }, "a rename is timestamped history"
  end

  def test_rename_returns_the_name_so_the_repl_can_echo_it
    path = File.join(@dir, "s.jsonl")
    logger = Boukensha::Logger.new(log: path)

    assert_equal "cold map", logger.rename(name: "cold map")
  ensure
    logger&.close
  end

  # ---------- the REPL command ----------------------------------------------

  def test_slash_rename_records_the_name_and_confirms
    repl, printed, path = repl_with_logger

    assert_equal :command, repl.handle_command("/rename find bakery — cold map")
    assert_equal "find bakery — cold map", repl.session_name
    assert_match(/renamed to/, printed.join)
    assert_match(/session_rename/, File.read(path))
  end

  # Bare `/rename` prints rather than errors: the far more common reason to type
  # it alone is wanting to know what the session is already called.
  def test_bare_slash_rename_prints_the_current_name
    repl, printed, = repl_with_logger

    repl.handle_command("/rename")
    assert_match(/no name/, printed.join)

    printed.clear
    repl.handle_command("/rename cold map")
    printed.clear
    repl.handle_command("/rename")

    assert_match(/"cold map"/, printed.join)
  end

  def test_the_banner_shows_a_name_when_there_is_one
    repl, = repl_with_logger(session_name: "cold map")

    assert_match(/session:\s+cold map/, repl.banner)
    assert_match(%r{/rename}, repl.banner)
  end

  private

  def first_event(**snapshot)
    path = File.join(@dir, "session.jsonl")
    logger = Boukensha::Logger.new(log: path, snapshot: snapshot)
    logger.close
    JSON.parse(File.readlines(path).first)
  end

  def repl_with_logger(session_name: nil)
    path   = File.join(@dir, "repl.jsonl")
    logger = Boukensha::Logger.new(log: path, snapshot: { session_name: session_name }.compact)
    context = Boukensha::Context.new(system: "test", context_window: 1000)
    repl = Boukensha::Repl.new(context: context, registry: Boukensha::Registry.new(context),
                               builder: nil, client: nil, logger: logger, session_name: session_name)
    printed = []
    repl.on_output { |line| printed << line }
    [repl, printed, path]
  end
end
