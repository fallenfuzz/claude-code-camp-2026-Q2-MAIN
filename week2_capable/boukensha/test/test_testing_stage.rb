require_relative "helper"
require "json"
require "boukensha/testing/stage"
require "boukensha/backends/anthropic"
require "boukensha/mud/navigation/reasoners"

# Staged model answers (mocking_messages.md §3, §12).
#
# The claim these tests are protecting is that a staged run is EVIDENCE rather
# than theatre: a staged reasoner answer still goes through the real parser, a
# staged player turn still dispatches real tools, and a task nobody staged is
# untouched and still talks to the network. Everything below runs with no model,
# no key and no MUD.
class TestTestingStage < Minitest::Test
  Stage = Boukensha::Testing::Stage

  def teardown = Boukensha.stage = nil

  # ---------- addressing ----------------------------------------------------

  def test_answers_are_consumed_one_per_call_in_order
    stage = build("navigator" => [{ "direction" => "north" }, { "direction" => "east" }])

    assert_equal "north", answer(stage, "navigator")["direction"]
    assert_equal "east",  answer(stage, "navigator")["direction"]
  end

  # The obvious addressing scheme is "the seventh model call of the run", and it
  # is the wrong one: global ordering is precisely what varies between runs, so
  # one extra player iteration would renumber every navigator answer after it
  # and a scenario correct on Monday would stage the wrong answers on Tuesday
  # (§3.2).
  def test_an_extra_player_call_does_not_renumber_the_navigator_s_answers
    stage = build("player"    => [{ "text" => "one" }, { "text" => "two" }, { "text" => "three" }],
                  "navigator" => [{ "direction" => "north" }, { "direction" => "east" }])

    text(stage, "player")
    assert_equal "north", answer(stage, "navigator")["direction"]
    text(stage, "player")
    text(stage, "player")
    assert_equal "east", answer(stage, "navigator")["direction"],
                 "the navigator's second answer stays its second, however many turns the player took"
  end

  def test_a_task_nobody_staged_is_untouched
    stage = build("navigator" => [{ "direction" => "north" }])

    assert stage.staged?("navigator")
    refute stage.staged?("cartographer"), "anything not named stays live — the default is the real thing"
    refute stage.staged?("player")
    assert_equal %w[player cartographer judge], stage.live_tasks
  end

  # A run that quietly started paying for real calls halfway through would
  # produce a report describing a configuration nobody chose.
  def test_running_off_the_end_names_the_task_and_the_call_number
    stage = build("navigator" => [{ "direction" => "north" }])
    answer(stage, "navigator")

    error = assert_raises(Stage::Error) { answer(stage, "navigator") }

    assert_match(/stage\.navigator ran out/, error.message)
    assert_match(/call 2 was made and only 1 answer is staged/, error.message)
  end

  # `Agent#wrap_up` calls the same client for its wind-down turn, so a staged
  # run must have an answer ready for it or a case that trips a ceiling punches
  # through to the network on its last breath. This is the one easy thing to
  # forget, so the error says so (§2).
  def test_the_exhaustion_message_names_wrap_up
    stage = build("player" => [{ "text" => "done" }])
    text(stage, "player")

    assert_match(/wrap_up/, assert_raises(Stage::Error) { text(stage, "player") }.message)
  end

  # ---------- what a staged answer IS ---------------------------------------

  # A reasoner answer is handed back as text and goes through Reasoners.parse
  # exactly as a live one would, so the parser's fence-stripping tolerance and
  # its nil-on-garbage behaviour stay under test rather than being bypassed.
  def test_a_reasoner_answer_arrives_as_text_the_real_parser_reads
    stage = build("navigator" => [{ "direction" => "north", "scope_suspect" => true,
                                    "scope_reason" => "sixteen doors at a median of six" }])
    body = stage.answer!(task: "navigator", backend: backend)

    assert_equal "end_turn", body["stop_reason"]
    parsed = Boukensha::Mud::Navigation::Reasoners.parse(body["content"].first["text"])
    assert_equal "north", parsed["direction"]
    assert_equal true, parsed["scope_suspect"]
  end

  # A staged player answer carrying a tool_use block makes the REAL tool run —
  # which is the whole reason staging supersedes prefilling the transcript with
  # fabricated tool results (§4).
  def test_a_player_answer_with_tools_produces_real_tool_use_blocks
    stage = build("player" => [{ "tools" => [{ "name" => "move_to",
                                               "args" => { "destination" => "the mayor's office" } }] }])
    body = stage.answer!(task: "player", backend: backend)

    assert_equal "tool_use", body["stop_reason"]
    block = body["content"].first
    assert_equal "move_to", block["name"]
    assert_equal({ "destination" => "the mayor's office" }, block["input"])
    assert_match(/\Astage_/, block["id"], "an id nobody can trace to an API response should say where it came from")
  end

  # The agent parses the body it is handed, so the shape has to survive the
  # backend's own parse_response rather than merely look plausible.
  def test_the_synthesised_body_survives_the_backend_s_own_parser
    stage = build("player" => [{ "text" => "I've reached the far bank.",
                                 "tools" => [{ "name" => "move_to", "args" => { "destination" => "x" } }] }])
    parsed = backend.parse_response(stage.answer!(task: "player", backend: backend))

    assert_equal "tool_use", parsed[:stop_reason]
    assert_equal %w[text tool_use], parsed[:content].map { |b| b["type"] }
  end

  # Nothing was spent. A staged call reporting invented usage would put a price
  # on a journey that was asserted rather than taken.
  def test_a_staged_call_reports_no_spend
    stage = build("player" => [{ "text" => "hello" }])
    usage = stage.answer!(task: "player", backend: backend)["usage"]

    assert_equal 0, usage["input_tokens"]
    assert_equal 0, usage["output_tokens"]
  end

  # ---------- validation, at load time --------------------------------------

  def test_a_stage_needs_a_because
    error = assert_raises(Stage::Error) { Stage.new("navigator" => [{ "direction" => "north" }]) }

    assert_match(/because/, error.message)
  end

  def test_an_unknown_task_is_a_typo_and_is_refused
    error = assert_raises(Stage::Error) { build("navigater" => [{ "direction" => "north" }]) }

    assert_match(/navigater/, error.message)
    assert_match(/player, navigator, cartographer, judge/, error.message)
  end

  def test_an_empty_queue_is_refused_rather_than_meaning_live
    assert_raises(Stage::Error) { build("navigator" => []) }
  end

  # An entry carrying both `text:` and `direction:` could mean either, and a
  # wrong guess stages an answer nobody wrote.
  def test_an_entry_mixing_a_turn_with_answer_fields_is_refused
    error = assert_raises(Stage::Error) { build("navigator" => [{ "text" => "hi", "direction" => "north" }]) }

    assert_match(/mixes an agent turn/, error.message)
  end

  def test_a_tool_call_without_a_name_is_refused
    assert_raises(Stage::Error) { build("player" => [{ "tools" => [{ "args" => {} }] }]) }
  end

  # ---------- provenance (§7) ------------------------------------------------

  def test_the_launch_record_names_what_was_staged_and_what_was_live
    stage = build("player" => [{ "text" => "a" }], "navigator" => [{ "direction" => "north" }])

    assert_equal({ "player" => 1, "navigator" => 1 }, stage.as_launch["staged"])
    assert_equal %w[cartographer judge], stage.as_launch["live"]
    assert_match(/Run A/, stage.as_launch["because"])
  end

  # Staging changes which agent was doing the thinking, which is a larger
  # difference than any setting — so it is part of the arm key and a report
  # cannot average a staged row together with a live one.
  def test_the_arm_label_names_the_live_task
    assert_equal "live: cartographer,judge",
                 build("player" => [{ "text" => "a" }], "navigator" => [{ "direction" => "n" }]).arm_label
  end

  def test_a_fully_staged_run_says_so
    every = Stage::TASKS.to_h { |task| [task, [{ "text" => "x" }]] }

    assert build(**every).fully_staged?
    refute build("player" => [{ "text" => "x" }]).fully_staged?
  end

  private

  def build(**tasks)
    Stage.new({ "because" => "Run A of mocking_messages.md §1." }.merge(tasks.transform_keys(&:to_s)))
  end

  def backend
    @backend ||= Boukensha::Backends::Anthropic.new(api_key: "none", model: "claude-haiku-4-5")
  end

  def answer(stage, task)
    JSON.parse(text(stage, task))
  end

  def text(stage, task)
    stage.answer!(task: task, backend: backend)["content"].first["text"]
  end
end
