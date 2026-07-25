require_relative "helper"
require "json"

# mud_monitor spec §4.1: `at` gains millisecond resolution and every event
# carries a monotonic `mono_ms`, so cross-layer joins (telnet/manager/agent)
# compare like with like and durations survive NTP steps / DST.
class TestLogger < Minitest::Test
  def test_write_log_stamps_millisecond_at_and_monotonic_mono_ms
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      logger = Boukensha::Logger.new(session_id: "test", log: path)
      logger.turn(n: 0)
      logger.close

      lines = File.readlines(path).map { |l| JSON.parse(l) }
      turn_event = lines.find { |e| e["phase"] == "turn" }

      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/, turn_event["at"])
      assert_kind_of Integer, turn_event["mono_ms"]
    end
  end

  def test_mono_ms_is_non_decreasing_across_events
    Dir.mktmpdir do |dir|
      path = File.join(dir, "session.jsonl")
      logger = Boukensha::Logger.new(session_id: "test", log: path)
      logger.turn(n: 0)
      logger.turn(n: 1)
      logger.close

      mono = File.readlines(path).map { |l| JSON.parse(l)["mono_ms"] }

      assert_equal mono.sort, mono
    end
  end

  # --- clear/compact visibility -------------------------------------------

  def test_clear_writes_a_clear_event_recording_the_dropped_count
    events = capture do |logger|
      logger.clear(before: 12)
    end

    clear = events.find { |e| e["phase"] == "clear" }
    refute_nil clear
    assert_equal 12, clear["before"]
    assert_equal 12, clear["dropped"]
  end

  # --- request: the definitive payload ------------------------------------

  def test_request_logs_the_full_payload_system_tools_and_messages
    events = capture do |logger|
      logger.request(payload: {
        model: "claude-haiku-4-5",
        system: "You are a MUD player.",
        max_tokens: 1024,
        tools: [ { name: "look", input_schema: {} } ],
        messages: [ { role: "user", content: "hi" } ]
      })
    end

    req = events.find { |e| e["phase"] == "request" }
    refute_nil req
    assert_equal "claude-haiku-4-5", req["model"]
    assert_equal "You are a MUD player.", req["system"]
    assert_equal 1, req["tool_count"]
    assert_equal "look", req["tools"].first["name"]
    assert_equal 1, req["message_count"]
    assert_equal "hi", req["messages"].first["content"]
  end

  def test_request_omits_unchanged_system_and_tools_on_repeat_calls
    payload = {
      model: "m", system: "S", max_tokens: 10,
      tools: [ { name: "look" } ],
      messages: [ { role: "user", content: "a" } ]
    }

    events = capture do |logger|
      logger.request(payload: payload)
      logger.request(payload: payload.merge(messages: [ { role: "user", content: "a" },
                                                        { role: "assistant", content: "b" } ]))
    end

    reqs = events.select { |e| e["phase"] == "request" }
    # first call carries system + tools in full
    assert_equal "S", reqs[0]["system"]
    refute reqs[0].key?("system_unchanged")
    assert reqs[0].key?("tools")
    # second call: constants unchanged, only messages re-logged in full
    assert reqs[1]["system_unchanged"]
    assert reqs[1]["tools_unchanged"]
    refute reqs[1].key?("system")
    refute reqs[1].key?("tools")
    assert_equal 1, reqs[1]["tool_count"]          # carried count still reported
    assert_equal 2, reqs[1]["message_count"]       # messages always logged in full
  end

  def test_request_relogs_system_and_tools_when_they_change
    events = capture do |logger|
      logger.request(payload: { system: "S1", tools: [ { name: "a" } ], messages: [] })
      logger.request(payload: { system: "S2", tools: [ { name: "a" }, { name: "b" } ], messages: [] })
    end

    reqs = events.select { |e| e["phase"] == "request" }
    assert_equal "S2", reqs[1]["system"]
    assert_equal 2, reqs[1]["tool_count"]
    refute reqs[1]["system_unchanged"]
  end

  # --- provenance and correlation (observ_improvements.md §1, §2) ----------

  # The failure this fixes: a hook's cold-start `score` and `look` were logged
  # as ordinary tool_calls at task "player", depth 0 — indistinguishable from
  # calls the model chose, which is why a 1.9s blocking MUD read read as model
  # latency next to Iteration 0.
  # `operation`/`trigger` are no longer arguments: they come off the span the
  # call is happening inside, so no hop between Hooks and the dispatcher can
  # forget to forward them (work_attribution.md §1).
  def test_a_tool_call_records_who_initiated_it_and_why
    events = capture do |logger|
      logger.operation("player_bootstrap", trigger: "before_turn") do
        logger.tool_call(name: "tbamud__check", args: { kind: "score" }, initiator: "hook")
      end
    end

    call = events.find { |e| e["phase"] == "tool_call" }
    assert_equal "hook", call["initiator"]
    assert_equal "player_bootstrap", call["operation"]
    assert_equal "before_turn", call["trigger"]
    assert_equal events.find { |e| e["phase"] == "operation_start" }["operation_id"],
                 call["operation_id"]
  end

  # Pairing by name+depth is ambiguous the moment two identical calls are in
  # flight. The id is generated here so no call site can forget it.
  def test_a_call_id_is_returned_and_carried_onto_the_matching_result
    call_id = nil
    events = capture do |logger|
      call_id = logger.tool_call(name: "tbamud__look", args: {}, initiator: "hook")
      logger.tool_result(name: "tbamud__look", result: "a room", call_id: call_id,
                         initiator: "hook", duration_ms: 42)
    end

    assert_match(/\Acall_\h+\z/, call_id)
    assert_equal call_id, events.find { |e| e["phase"] == "tool_call" }["call_id"]

    result = events.find { |e| e["phase"] == "tool_result" }
    assert_equal call_id, result["call_id"]
    assert_equal 42, result["duration_ms"]
  end

  # Additive, or every session file already on disk stops parsing. A caller
  # that passes no provenance writes exactly the event shape it used to.
  def test_provenance_fields_are_omitted_entirely_when_not_supplied
    events = capture do |logger|
      logger.tool_call(name: "look", args: {})
      logger.tool_result(name: "look", result: "ok")
    end

    call = events.find { |e| e["phase"] == "tool_call" }
    refute call.key?("initiator")
    refute call.key?("operation")
    refute call.key?("parent_call_id")

    result = events.find { |e| e["phase"] == "tool_result" }
    assert_equal "ok", result["result"]
    assert_equal true, result["ok"]
    assert result.key?("error"), "ok/error stay on the wire for the existing reader"
  end

  # The apparent contradiction the monitor used to show: a movement card
  # displaying a full room dump beside an assistant that demonstrably saw
  # `moved west → …`. Both are now recorded, correlated, and neither is lost.
  def test_context_transform_records_the_model_visible_replacement
    events = capture do |logger|
      logger.context_transform(call_id: "call_abc", kind: "tool_result_replacement",
                               raw_chars: 512, content: "moved west → The Reading Room")
    end

    t = events.find { |e| e["phase"] == "context_transform" }
    assert_equal "call_abc", t["call_id"]
    assert_equal "tool_result_replacement", t["kind"]
    assert_equal 512, t["raw_chars"]
    assert_equal "moved west → The Reading Room", t["content"]
  end

  def test_injected_context_records_what_the_hook_appended
    events = capture do |logger|
      logger.injected_context(kind: "state_block", content: "[here] The Temple Of Midgaard",
                              source: "memory", changed: true)
    end

    i = events.find { |e| e["phase"] == "injected_context" }
    assert_equal "state_block", i["kind"]
    assert_equal "memory", i["source"]
    assert_equal true, i["changed"]
    assert_includes i["content"], "[here] The Temple Of Midgaard"
  end

  # --- Amendment A: the task stack ----------------------------------------

  def test_every_event_carries_the_root_task_at_depth_zero
    events = capture do |logger|
      logger.turn(n: 0)
      logger.tool_call(name: "look", args: {})
    end

    assert_equal %w[player player player], events.map { |e| e["task"] }
    assert_equal [ 0, 0, 0 ], events.map { |e| e["depth"] }
  end

  def test_task_brackets_a_sub_run_and_labels_only_its_events
    events = capture do |logger|
      logger.turn(n: 0)
      logger.task("room_inspector", snapshot: { model: "claude-haiku-4-5", max_iterations: 12 }) do
        logger.tool_call(name: "tbamud__look", args: {})
      end
      logger.tool_result(name: "inspect_room", result: "{}")
    end

    labelled = events.map { |e| [ e["phase"], e["task"], e["depth"] ] }

    assert_equal [
      [ "session_start", "player",         0 ],
      [ "turn",          "player",         0 ],
      [ "task_start",    "room_inspector", 1 ],
      [ "tool_call",     "room_inspector", 1 ],
      [ "task_end",      "room_inspector", 1 ],
      [ "tool_result",   "player",         0 ]
    ], labelled

    start = events.find { |e| e["phase"] == "task_start" }
    assert_equal "room_inspector", start["task_name"]
    assert_equal 12, start["max_iterations"]   # the sub-run's own config, not the parent's
  end

  def test_task_returns_the_blocks_value
    capture { |logger| assert_equal "json", logger.task("room_inspector") { "json" } }
  end

  def test_nested_delegation_reaches_depth_two_and_unwinds
    events = capture do |logger|
      logger.task("room_inspector") do
        logger.task("appraiser") { logger.turn(n: 1) }
      end
      logger.turn(n: 2)
    end

    depths = events.each_with_object({}) { |e, h| (h[e["phase"]] ||= []) << e["depth"] }

    assert_equal [ 2 ], depths["turn"].first(1)   # innermost event
    assert_equal 0, events.last["depth"]           # stack fully unwound
    assert_equal "player", events.last["task"]
  end

  # The regression that mislabels everything after a failed sub-run: without
  # `ensure`, the stack would never pop and the player's later events would be
  # filed under room_inspector.
  def test_a_raise_inside_a_sub_run_still_closes_the_group_and_pops
    events = capture do |logger|
      assert_raises(RuntimeError) do
        logger.task("room_inspector") { raise "subagent blew up" }
      end
      logger.turn(n: 1)
    end

    assert_equal "task_end", events[-2]["phase"]
    assert_equal [ "player", 0 ], [ events[-1]["task"], events[-1]["depth"] ]
  end

  def test_current_task_reports_what_is_running_now
    capture do |logger|
      assert_equal "player", logger.current_task
      logger.task("room_inspector") { assert_equal "room_inspector", logger.current_task }
      assert_equal "player", logger.current_task
    end
  end

  # --- operation spans (work_attribution.md §1) ----------------------------
  #
  # A unit of work as an EVENT: a thing that started, contained other things,
  # and finished, having spent this much of what. Everything else in this log is
  # instantaneous, which is why the monitor was reduced to inferring containment
  # from adjacency.

  def test_an_operation_brackets_its_work_with_a_start_and_an_end
    events = capture do |logger|
      logger.operation("room_survey", trigger: "before_model") { :done }
    end

    start, finish = events.select { |e| e["phase"].to_s.start_with?("operation_") }
    assert_equal %w[operation_start operation_end], [ start["phase"], finish["phase"] ]
    assert_match(/\Aop_\h+\z/, start["operation_id"])
    assert_equal start["operation_id"], finish["operation_id"]
    assert_equal "before_model", start["trigger"]
    assert_nil start["parent_operation_id"]
    assert finish["ok"]
    assert_kind_of Integer, finish["duration_ms"]
  end

  # The fact adjacency could not express. `room_survey` runs INSIDE
  # `position_refresh`, and this is the field the monitor builds the tree from.
  def test_a_nested_operation_records_its_parent_and_inherits_its_trigger
    events = capture do |logger|
      logger.operation("position_refresh", trigger: "before_model") do
        logger.operation("room_survey") { nil }
      end
    end

    outer, inner = events.select { |e| e["phase"] == "operation_start" }
    assert_equal "position_refresh", outer["operation"]
    assert_equal outer["operation_id"], inner["parent_operation_id"]
    # The survey names no seam of its own — it cannot know one — so it inherits.
    assert_equal "before_model", inner["trigger"]
  end

  # Same argument as `task`'s ensure: a span left open by a raise would file
  # every later event under an operation that had already finished.
  def test_a_raise_inside_an_operation_still_closes_it_and_marks_it_failed
    events = capture do |logger|
      assert_raises(RuntimeError) { logger.operation("room_survey") { raise "mud died" } }
      logger.tool_call(name: "tbamud__look", args: {})
    end

    finish = events.find { |e| e["phase"] == "operation_end" }
    refute finish["ok"]
    assert_nil events.find { |e| e["phase"] == "tool_call" }["operation_id"]
    assert_nil Boukensha::Operation.current
  end

  # The rollup. A span reports what it spent, and the counters are deltas over
  # its own interval — so a nested span's cost shows up in its parent exactly
  # once, which is what nesting means.
  def test_an_operation_reports_the_round_trips_made_inside_it
    events = capture do |logger|
      logger.operation("outer") do
        logger.tool_result(name: "tbamud__look", result: "a room", duration_ms: 100)
        logger.operation("inner") do
          logger.tool_result(name: "tbamud__check", result: "exits", duration_ms: 40)
        end
      end
    end

    inner, outer = events.select { |e| e["phase"] == "operation_end" }
    assert_equal [ 1, 40 ], inner.values_at("mud_calls", "mud_ms")
    assert_equal [ 2, 140 ], outer.values_at("mud_calls", "mud_ms")
  end

  # `memory_conflict` rides tool_result as a carrier for a fact that cost no
  # round trip. Counting it would overstate what the MUD was asked for.
  def test_a_result_with_no_duration_is_not_counted_as_a_round_trip
    events = capture do |logger|
      logger.operation("outer") do
        logger.tool_result(name: "memory_conflict", result: "{}")
      end
    end

    assert_nil events.find { |e| e["phase"] == "operation_end" }["mud_calls"]
  end

  # A key in the rollup is a key some meter is REPORTING. A span with no store
  # attached omits `db_reads` rather than claiming zero — "we did not read" and
  # "we cannot say" are different answers.
  def test_a_registered_meter_contributes_its_delta_to_the_rollup
    meter = Struct.new(:counters).new({ db_reads: 3, db_writes: 0 })
    events = capture do |logger|
      logger.add_meter(meter)
      logger.operation("first") { meter.counters = { db_reads: 9, db_writes: 4 } }
      logger.operation("second") { nil }
    end

    first, second = events.select { |e| e["phase"] == "operation_end" }
    assert_equal [ 6, 4 ], first.values_at("db_reads", "db_writes")
    assert_equal [ 0, 0 ], second.values_at("db_reads", "db_writes")
  end

  def test_a_span_in_a_session_with_no_meters_reports_no_db_counters
    events = capture { |logger| logger.operation("first") { nil } }

    finish = events.find { |e| e["phase"] == "operation_end" }
    assert_nil finish["db_reads"]
    assert_nil finish["db_writes"]
  end

  # --- local inference (work_attribution.md §2) ----------------------------

  def test_local_inference_records_the_yield_and_says_the_cost_is_zero
    events = capture do |logger|
      logger.operation("room_survey") do
        logger.local_inference(model: "look_candidates", backend: "onnx",
                               artifact: "models/look_candidates/model.onnx",
                               duration_ms: 11, pool: 23, kept: 3,
                               threshold: 0.62, top_k: 5)
      end
    end

    event = events.find { |e| e["phase"] == "local_inference" }
    assert_equal [ 23, 3 ], event.values_at("pool", "kept")
    assert_equal [ 0.0, "local" ], event.values_at("cost_usd", "unit")
    assert event["available"]
    assert_equal events.find { |e| e["phase"] == "operation_start" }["operation_id"],
                 event["operation_id"]
    assert_equal 11, events.find { |e| e["phase"] == "operation_end" }["inference_ms"]
  end

  private

  def capture
    Dir.mktmpdir do |dir|
      path   = File.join(dir, "session.jsonl")
      logger = Boukensha::Logger.new(session_id: "test", log: path)
      begin
        yield logger
      ensure
        logger.close
      end
      return File.readlines(path).map { |l| JSON.parse(l) }
    end
  end
end
