require_relative "helper"
require "json"
require "boukensha/testing/stage"
require "boukensha/backends/anthropic"

# The claim mocking_messages.md §4 rests on, tested end to end through a real
# Agent, a real Registry and a real Client.
#
# The earlier idea was to prefill the player's conversation with fabricated
# messages, and staging supersedes it for one reason worth proving rather than
# asserting: a fabricated `tool_result` is FICTION, whereas a staged assistant
# turn carrying a `tool_use` block makes the real tool actually execute.
# `Agent#handle_tool_calls` dispatches whatever blocks the response contains, so
# a staged player answer naming a tool reaches the tool by the ordinary code
# path and the model then genuinely receives its output.
#
# Observed through the registry — did the tool body run, with what — rather than
# through the transcript, which is what a prefilled message could have faked.
class TestStageDispatchesTools < Minitest::Test
  Stage = Boukensha::Testing::Stage

  def teardown = Boukensha.stage = nil

  def test_a_staged_tool_call_really_runs_the_tool
    Boukensha.stage = Stage.new(
      "because" => "§4: a staged turn is a code path, not a description of one",
      "player" => [
        { "tools" => [{ "name" => "move_to", "args" => { "destination" => "the mayor's office" } }] },
        { "text" => "That is as far as the walk got." }
      ]
    )

    calls, text = run_agent

    assert_equal [{ "destination" => "the mayor's office" }], calls,
                 "the tool body ran, with the arguments the scenario staged"
    assert_equal "That is as far as the walk got.", text
  end

  # The tool's return value becomes a real `tool_result` the next staged turn is
  # produced in response to — which is what makes the second answer an answer
  # rather than a script playing on regardless.
  def test_the_tool_result_lands_in_the_transcript_the_model_would_have_seen
    Boukensha.stage = Stage.new(
      "because" => "§4",
      "player" => [
        { "tools" => [{ "name" => "move_to", "args" => { "destination" => "x" } }] },
        { "text" => "done" }
      ]
    )

    _calls, _text, context = run_agent

    results = context.messages.select { |m| m.role == :tool_result }
    assert_equal 1, results.size
    assert_match(/walked 3 rooms/, results.first.content)
  end

  # The wind-down call `Agent#wrap_up` makes when a ceiling trips goes through
  # the same client, so a staged run must have an answer ready for it. This is
  # §2's "one easy thing to forget", and the failure is loud rather than a
  # silent call to the network.
  def test_a_tripped_ceiling_consumes_a_staged_answer_for_wrap_up
    Boukensha.stage = Stage.new(
      "because" => "§2: wrap_up calls the same client",
      "player" => [
        { "tools" => [{ "name" => "move_to", "args" => { "destination" => "x" } }] },
        { "text" => "I ran out of actions, but I reached the square." }
      ]
    )

    _calls, text = run_agent(max_iterations: 1)

    assert_equal "I ran out of actions, but I reached the square.", text,
                 "the wind-down turn was answered from the queue like any other call"
  end

  def test_a_ceiling_with_an_empty_queue_fails_by_name_rather_than_calling_out
    Boukensha.stage = Stage.new(
      "because" => "§2",
      "player" => [{ "tools" => [{ "name" => "move_to", "args" => { "destination" => "x" } }] }]
    )

    error = assert_raises(Stage::Error) { run_agent(max_iterations: 1) }

    assert_match(/stage\.player ran out/, error.message)
  end

  private

  # A real Agent over a real Registry, with the ONLY fake being the transport —
  # and the transport is fake because `Boukensha.stage` answered it, which is
  # the thing under test.
  def run_agent(max_iterations: 10)
    calls   = []
    context = Boukensha::Context.new(system: "t")
    registry = Boukensha::Registry.new(context)
    registry.tool("move_to", description: "walk somewhere",
                  parameters: { destination: { type: "string", description: "where" } }) do |**args|
      calls << { "destination" => args[:destination] }
      "[move_to] walked 3 rooms, arrived at The Temple Square"
    end

    logger = Boukensha::Logger.new(log: File.join(Dir.mktmpdir, "s.jsonl"))
    builder = Boukensha::PromptBuilder.new(context, backend)
    client  = Boukensha::Client.new(builder, task: "player")
    agent   = Boukensha::Agent.new(context: context, registry: registry, builder: builder,
                                   client: client, logger: logger, max_iterations: max_iterations)

    context.add_message(:user, "Find the mayor's office.")
    text = agent.run
    logger.close
    [calls, text, context]
  end

  def backend
    Boukensha::Backends::Anthropic.new(api_key: "none", model: "claude-haiku-4-5")
  end
end
