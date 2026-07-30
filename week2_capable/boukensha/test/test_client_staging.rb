require_relative "helper"
require "boukensha/testing/stage"
require "boukensha/backends/anthropic"

# The seam itself (mocking_messages.md §2): every model call in the system
# passes through `Client#call`, so staging is a wrapper around ONE method rather
# than a feature threaded through four call paths.
#
# The property under test is the sharp one — a staged task is answered without
# touching the network, and an UNSTAGED task in the very same process still
# tries to reach it. Nothing else about staging matters if that split is wrong.
class TestClientStaging < Minitest::Test
  Stage = Boukensha::Testing::Stage

  def setup
    @stage = Stage.new("because" => "the seam test",
                       "navigator" => [{ "direction" => "north", "reason" => "the promenade" }])
    Boukensha.stage = @stage
  end

  def teardown = Boukensha.stage = nil

  def test_a_staged_task_is_answered_from_its_queue_without_a_socket
    body = client("navigator").call

    assert_equal "end_turn", body["stop_reason"]
    assert_match(/"direction": "north"/, body["content"].first["text"])
  end

  # The whole point of `live` being the default: a task the scenario did not
  # name behaves exactly as it did before staging existed, which is to say it
  # takes the network path.
  def test_an_unstaged_task_still_goes_to_the_network
    assert_raises(WentToTheNetwork) { client("cartographer").call }
  end

  # A client with no task at all — every construction site passes one today, but
  # a caller that did not must not silently start consuming somebody's queue.
  def test_a_client_with_no_task_is_never_staged
    assert_raises(WentToTheNetwork) { client(nil).call }
  end

  def test_no_stage_installed_is_exactly_today_s_behaviour
    Boukensha.stage = nil

    assert_raises(WentToTheNetwork) { client("navigator").call }
  end

  private

  def client(task) = Boukensha::Client.new(FakeBuilder.new, task: task)

  # Raised by the fake builder the moment the client asks for a URL, which is
  # its first act on the network path. Asserting the BRANCH rather than the
  # failure it would eventually produce keeps the test off the wire entirely and
  # out of the client's retry backoff.
  class WentToTheNetwork < StandardError; end

  # Stands in for PromptBuilder.
  class FakeBuilder
    def backend
      @backend ||= Boukensha::Backends::Anthropic.new(api_key: "none", model: "claude-haiku-4-5")
    end

    def url     = raise(WentToTheNetwork)
    def headers = { "Content-Type" => "application/json" }
    def to_api_payload(**_opts) = { model: "claude-haiku-4-5", messages: [] }
  end
end
