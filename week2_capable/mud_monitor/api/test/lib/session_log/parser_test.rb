require "test_helper"

module SessionLog
  class ParserTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/session_logs")

    test "parses a complete session into ordered entries with turns and usage" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      assert_equal "complete", parser.id
      assert_equal "2026-07-22T10:00:00-04:00", parser.started_at
      assert_equal %i[user assistant tool assistant turn_end], parser.entries.map(&:type)
      assert_equal 300, parser.total_input_tokens
      assert_equal 30, parser.total_output_tokens
      assert_equal 2, parser.usage_series.length
      assert_equal "completed", parser.end_reason
      refute parser.stopped?
      assert_in_delta 0.0006, parser.estimated_cost, 0.0001
    end

    test "assigns a monotonically increasing seq to every entry" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      assert_equal (1..parser.entries.length).to_a, parser.entries.map(&:seq)
    end

    test "unrecognized phases pass through as type unknown with the raw event attached" do
      parser = Parser.load(FIXTURES.join("unknown_phase.jsonl"))

      unknown = parser.entries.find { |e| e.type == :unknown }
      refute_nil unknown
      assert_equal "goal", unknown.raw["phase"]
      assert_equal "reach the temple", unknown.raw["text"]
    end

    test "a truncated final line (live file mid-write) is skipped, not raised" do
      parser = Parser.load(FIXTURES.join("truncated.jsonl"))

      assert_equal %i[user], parser.entries.map(&:type)
    end

    test "a clear event becomes a :clear entry rather than passing through as unknown" do
      parser = Parser.load(FIXTURES.join("messages_timeline.jsonl"))

      clear = parser.entries.find { |e| e.type == :clear }
      refute_nil clear
      assert_equal 4, clear.dropped
      refute parser.entries.any? { |e| e.type == :unknown }
    end

    test "each request becomes a compact marker entry (a sidebar button), never a raw blob" do
      parser   = Parser.load(FIXTURES.join("request_timeline.jsonl"))
      requests = parser.entries.select { |e| e.type == :request }

      refute parser.entries.any? { |e| e.type == :unknown }, "request events must not render as raw unknown blocks"
      # one marker per request, carrying the 1-based ordinal that maps to the
      # sidebar checkpoint plus a message count for the button label
      assert_equal 4, requests.length
      assert_equal [ 1, 2, 3, 4 ], requests.map(&:request_seq)
      assert_equal [ 1, 3, 4, 1 ], requests.map(&:message_count)
      # the narrative still renders around them (assistant responses, etc.)
      assert_includes parser.entries.map(&:type), :assistant
    end

    test "an empty file parses to no entries and no crash" do
      parser = Parser.load(FIXTURES.join("empty.jsonl"))

      assert_empty parser.entries
      assert_nil parser.started_at
      assert_nil parser.estimated_cost
    end

    test "a 1s-resolution log without mono_ms reports wallclock_coarse timing" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      assert_equal "wallclock_coarse", parser.timing_source
      assert_nil parser.entries.first.mono_ms
    end

    test "an ms-resolution log without mono_ms reports wallclock timing and real sub-second durations" do
      parser = Parser.load(FIXTURES.join("wallclock_ms.jsonl"))

      assert_equal "wallclock", parser.timing_source

      tool  = parser.entries.find { |e| e.type == :tool }
      assert_equal 1000, tool.duration_ms

      turn_end = parser.entries.find { |e| e.type == :turn_end }
      assert_equal 1920, turn_end.duration_ms
    end

    test "a log with mono_ms reports monotonic timing and exact tool/model/turn durations" do
      parser = Parser.load(FIXTURES.join("monotonic.jsonl"))

      assert_equal "monotonic", parser.timing_source

      user, assistant1, tool, assistant2, turn_end = parser.entries
      assert_nil user.dt_ms # first entry has nothing to diff against

      assert_equal 120, assistant1.duration_ms # model latency: prompt -> first response
      assert_equal assistant1.dt_ms, assistant1.duration_ms

      assert_equal 2000, tool.duration_ms # exact tool_call -> tool_result round trip
      refute_equal tool.dt_ms, tool.duration_ms # dt_ms also carries the assistant's post-response overhead

      assert_equal 305, assistant2.duration_ms # model latency: tool_result -> second response
      assert_equal 2465, turn_end.duration_ms # whole-turn wall time
    end

    # ---- plan Amendment A: one file per run, task labelled -----------------

    test "a delegated sub-run parses as one session with task and depth on every entry" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      assert_equal %i[user assistant task_start tool assistant turn_end task_end tool assistant turn_end],
                   parser.entries.map(&:type)
      assert(parser.entries.all? { |e| e.task.present? }, "every entry carries a task")

      inside  = parser.entries.select { |e| e.task == "room_inspector" }
      outside = parser.entries.select { |e| e.task == "player" }

      assert_equal [ 1 ], inside.map(&:depth).uniq
      assert_equal [ 0 ], outside.map(&:depth).uniq
      assert_equal "player", parser.root_task
      assert_equal %w[player room_inspector], parser.task_roster.sort
      assert_equal 1, parser.sub_runs
      assert_equal 0, parser.unclosed_tasks
    end

    test "task_start carries the sub-run's own configuration and task_end its duration" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      start = parser.entries.find { |e| e.type == :task_start }
      assert_equal "room_inspector", start.task_name
      assert_equal "claude-haiku-4-5", start.model      # not the parent's opus
      assert_equal 12, start.max_iterations             # not the parent's 20

      finish = parser.entries.find { |e| e.type == :task_end }
      assert_equal 1000, finish.duration_ms             # mono 2100 -> 3100

      # The parent's own inspect_room tool entry measures the same interval from
      # outside; the difference is the subagent's startup overhead.
      outer = parser.entries.select { |e| e.type == :tool }.last
      assert_equal "inspect_room", outer.tool_name
      assert_equal 1100, outer.duration_ms
    end

    # The delegating call is still pending while the sub-run's own calls open and
    # close inside it, so FIFO pairing would hand each result the other one's
    # timestamps.
    test "a tool call that is still open while a sub-run runs pairs with its own result" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      inner, outer = parser.entries.select { |e| e.type == :tool }

      assert_equal "tbamud__look", inner.tool_name
      assert_equal 480, inner.duration_ms   # mono 2120 -> 2600, not the outer call's 2010
      assert_equal 1, inner.depth
      assert_equal "inspect_room", outer.tool_name
      assert_equal 0, outer.depth
    end

    test "cost breaks down per task now that responses are attributed" do
      parser = Parser.load(FIXTURES.join("delegated.jsonl"))

      by_task = parser.cost_breakdown.to_h { |row| [ row[:task], row ] }

      assert_equal %w[player room_inspector], by_task.keys.sort
      assert_equal 2, by_task["player"][:calls]
      assert_equal 1, by_task["room_inspector"][:calls]
      assert_equal "claude-haiku-4-5", by_task["room_inspector"][:model]
      assert_in_delta 0.0006, by_task["room_inspector"][:cost], 0.00001
    end

    test "a session killed mid-sub-run parses, and the unclosed group is reported" do
      parser = Parser.load(FIXTURES.join("killed_mid_sub_run.jsonl"))

      assert_equal %i[user task_start], parser.entries.map(&:type)
      assert_equal 1, parser.sub_runs
      assert_equal 1, parser.unclosed_tasks, "the group never closed — say so rather than implying it did"
      assert_nil parser.entries.find { |e| e.type == :task_end }
    end

    # ---- provenance (observ_improvements.md §1-§3) ------------------------

    test "a tool entry carries who initiated it, why, and from which seam" do
      parser = Parser.load(FIXTURES.join("provenance.jsonl"))
      by_name = parser.entries.select { |e| e.type == :tool }.to_h { |e| [ e.tool_name, e ] }

      score = by_name["tbamud__check"]
      assert_equal "hook", score.initiator
      assert_equal "player_bootstrap", score.operation
      assert_equal "before_turn", score.trigger
      assert_equal "call_boot01", score.call_id

      assert_equal "model", by_name["tbamud__move"].initiator
      assert_nil by_name["tbamud__move"].operation, "a model call has no hook operation"
    end

    # The 1.9 seconds sat next to Iteration 0 and read as model latency. It was
    # a blocking MUD `score`, and the dispatcher now says so in one field.
    test "the dispatcher's own duration is preferred over the gap between events" do
      parser = Parser.load(FIXTURES.join("provenance.jsonl"))
      score  = parser.entries.find { |e| e.tool_name == "tbamud__check" }

      assert_equal 1930, score.duration_ms
    end

    test "model and automatic tool calls are counted separately" do
      parser = Parser.load(FIXTURES.join("provenance.jsonl"))

      assert_equal 4, parser.tool_calls_count
      assert_equal 1, parser.model_tool_calls
      assert_equal 3, parser.automatic_tool_calls
      assert parser.has_provenance?
      assert_equal 2035, parser.automatic_tool_ms
    end

    test "automatic work rolls up by operation, slowest first" do
      parser = Parser.load(FIXTURES.join("provenance.jsonl"))
      rows   = parser.automatic_operations

      assert_equal %w[player_bootstrap position_refresh async_poll], rows.map { |r| r[:operation] }
      assert_equal 1930, rows.first[:duration_ms]
      assert_equal "before_turn", rows.first[:trigger]
      # An empty poll is the common case and the group summary says so rather
      # than giving each one a row in the narrative.
      assert_equal 1, rows.last[:empty]
      assert_equal 0, rows.sum { |r| r[:failed] }
    end

    # The apparent contradiction: a movement card showing a full room dump next
    # to an assistant that demonstrably saw `moved west → …`. One card, both
    # halves — never two rows that look like unrelated events.
    test "a context_transform folds into the tool card it belongs to" do
      parser = Parser.load(FIXTURES.join("provenance.jsonl"))
      move   = parser.entries.find { |e| e.tool_name == "tbamud__move" }

      assert_equal "moved west → The Reading Room", move.model_result
      assert_includes move.tool_result, "Bookshelves line the walls."
      assert_equal 72, move.raw_chars
      refute parser.entries.any? { |e| e.type == :context_transform },
             "the transform belongs inside the movement card, not beside it"
    end

    test "injected context becomes an entry of its own before the request that carried it" do
      parser   = Parser.load(FIXTURES.join("provenance.jsonl"))
      injected = parser.entries.select { |e| e.type == :injected_context }

      assert_equal 2, injected.length
      assert_equal "state_block", injected.first.kind
      assert_equal "memory", injected.first.source
      assert_equal true, injected.first.changed
      assert_includes injected.first.content, "[here] The Temple Of Midgaard"
      assert_operator injected.first.seq, :<, parser.entries.find { |e| e.type == :request }.seq
      refute parser.entries.any? { |e| e.type == :unknown }
    end

    # Old files must still load and must not be silently re-attributed. With no
    # provenance on the wire there ARE no automatic calls to report — the file
    # cannot say — so the count stays where it has always been.
    test "a log with no provenance reports every call as the model's and says the split is unknown" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      refute parser.has_provenance?
      assert_equal 1, parser.tool_calls_count
      assert_equal 1, parser.model_tool_calls
      assert_equal 0, parser.automatic_tool_calls
      assert_nil parser.automatic_tool_ms
      assert_empty parser.automatic_operations
    end

    # ---- operation spans (work_attribution.md §1) --------------------------

    test "a span records what it contained and what it spent" do
      parser = Parser.load(FIXTURES.join("operations.jsonl"))

      survey = parser.operation_ends.find { |e| e.operation == "room_survey" }
      assert_equal 310, survey.duration_ms
      assert survey.ok
      # The rollup is an open set — a new counter on the writing side reaches
      # the UI without a parser change.
      assert_equal 11, survey.rollup["db_writes"]
      assert_equal 6, survey.rollup["db_reads"]
      assert_equal 7, survey.rollup["journal_lines"]
      assert_equal 11, survey.rollup["inference_ms"]
      # The span's identity and timing are not counters and must not leak in.
      refute survey.rollup.key?("operation_id")
      refute survey.rollup.key?("duration_ms")
    end

    # The fact adjacency could not express, and the reason the whole plan
    # exists: `room_survey` ran INSIDE `position_refresh`.
    test "a nested span names its parent" do
      parser = Parser.load(FIXTURES.join("operations.jsonl"))

      survey = parser.operation_starts.find { |e| e.operation == "room_survey" }
      position = parser.operation_starts.find { |e| e.operation == "position_refresh" }

      assert_equal position.operation_id, survey.parent_operation_id
      assert_nil position.parent_operation_id
    end

    test "every automatic tool call carries the span it ran inside" do
      parser = Parser.load(FIXTURES.join("operations.jsonl"))

      exits = parser.tool_entries.find { |e| e.tool_args&.dig("kind") == "exits" }
      assert_equal "op_survey", exits.operation_id
      # The readable string stays alongside the id: it survives a log whose
      # spans were truncated mid-write.
      assert_equal "room_survey", exits.operation
    end

    # Nested counters are already inside their parent's delta. Summing every
    # span would report the survey's 11 writes twice.
    test "session totals sum root spans only, so nesting does not double-count" do
      parser = Parser.load(FIXTURES.join("operations.jsonl"))

      # op_boot wrote 2, op_pos wrote 13 (11 of them inside op_survey).
      assert_equal 15, parser.span_totals[:db_writes]
      assert_equal 10, parser.span_totals[:db_reads]
      assert_equal 11, parser.span_totals[:inference_ms]
    end

    # The process died mid-operation. Reporting it as finished would invent a
    # completion that never happened.
    test "a span with no end is reported as unclosed" do
      parser = Parser.load(FIXTURES.join("operations.jsonl"))

      assert parser.has_operations?
      assert_equal 4, parser.operations_count
      assert_equal 1, parser.unclosed_operations
    end

    test "local inference is an entry with its yield, its latency and a price of zero" do
      parser = Parser.load(FIXTURES.join("operations.jsonl"))

      row = parser.local_inferences.sole
      assert_equal "look_candidates", row.model
      assert_equal [ 23, 3 ], [ row.pool, row.kept ]
      assert_equal 11, row.duration_ms
      assert_equal 0.0, row.cost_usd
      assert row.available
      assert_equal "op_survey", row.operation_id
    end

    # A free model with no row reads as "no cost information"; the truth is
    # "free, and here is the latency it cost instead".
    test "the cost breakdown gains a local row priced at zero" do
      parser = Parser.load(FIXTURES.join("operations.jsonl"))

      row = parser.local_cost_rows.sole
      assert_equal [ "local", "look_candidates" ], [ row[:provider], row[:model] ]
      assert_equal 1, row[:calls]
      assert_equal 0.0, row[:cost]
      assert row[:cost_known]
      assert_equal 11, row[:duration_ms]
      assert_equal 0, row[:unavailable]
    end

    # Every file already on disk lacks operation_start. It must parse exactly as
    # it did, and say plainly that it has no spans rather than reporting zero
    # work.
    test "a log written before spans reports none and keeps its old shape" do
      parser = Parser.load(FIXTURES.join("provenance.jsonl"))

      refute parser.has_operations?
      assert_equal 0, parser.operations_count
      assert_equal 0, parser.unclosed_operations
      assert_empty parser.local_inferences
      assert_empty parser.local_cost_rows
      assert_equal 0, parser.span_totals[:db_writes]
      refute parser.entries.any? { |e| e.type == :unknown }
    end

    # Sessions written before Amendment A carry no task/depth at all. They are
    # one unlabelled root task, which is exactly what they were.
    test "a pre-amendment log parses with no task labels and depth 0 throughout" do
      parser = Parser.load(FIXTURES.join("unknown_phase.jsonl"))

      assert_equal [ 0 ], parser.entries.map(&:depth).uniq
      assert_equal 0, parser.sub_runs
      assert_empty parser.task_roster
      assert_nil parser.root_task
    end

    # ---- provenance and naming (batch_sesssion_testing.md §1) --------------

    test "reads how and by whom a session was started" do
      parser = Parser.load(FIXTURES.join("named_test_case.jsonl"))

      assert_equal "test", parser.launch_mode
      assert_equal "boukensha-test", parser.launch["runner"]
      assert_equal "find_bakery", parser.launch["scenario"]
      assert_equal "20260728T143000Z-a1b2c3d4", parser.launch["run_id"]
      assert_equal 3, parser.launch["case_index"]
      assert_equal "sha256:9f21", parser.launch["settings_digest"]
    end

    # A name is mutable and the log is append-only, so the name is the LAST one
    # the file mentions — not the first, and not a merge of them.
    test "folds session_start and every rename into one name, last one wins" do
      parser = Parser.load(FIXTURES.join("named_test_case.jsonl"))

      assert_equal "the one that examined the menu", parser.name
    end

    # Everything above is additive and optional. A file written before the
    # contract existed must parse exactly as it did, reporting "we cannot say"
    # rather than a guess — the same discipline `has_provenance?` follows.
    test "a legacy log has no name and no launch rather than an invented one" do
      parser = Parser.load(FIXTURES.join("complete.jsonl"))

      assert_nil parser.name
      assert_nil parser.launch
      assert_nil parser.launch_mode
    end

  end
end
