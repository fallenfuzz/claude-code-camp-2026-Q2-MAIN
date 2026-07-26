require "test_helper"
require "tempfile"

module SessionLog
  class TraceProjectionTest < ActiveSupport::TestCase
    test "normalizes old and current names and preserves unknown work" do
      projection = project([
        event("operation_start", "old", "llm.generate", 0),
        event("operation_end", "old", "llm.generate", 10, duration_ms: 10),
        event("operation_start", "new", "execute_tool move", 20),
        event("operation_end", "new", "execute_tool move", 25, duration_ms: 5),
        event("operation_start", "mystery", "future_widget", 30),
        event("operation_end", "mystery", "future_widget", 31, duration_ms: 1)
      ])

      assert_equal "chat", projection.spans["old"][:semantic_kind]
      assert_equal "execute_tool", projection.spans["new"][:semantic_kind]
      assert_equal "internal", projection.spans["mystery"][:semantic_kind]
    end

    test "uses operation ids for out of order ends" do
      projection = project([
        event("operation_start", "outer", "invoke_agent player", 0),
        event("operation_start", "inner", "chat model", 10, parent_operation_id: "outer"),
        event("operation_end", "outer", "invoke_agent player", 50),
        event("operation_end", "inner", "chat model", 30)
      ])

      assert_equal 50, projection.spans["outer"][:duration_ms]
      assert_equal 20, projection.spans["inner"][:duration_ms]
    end

    test "unions overlapping child intervals for self time" do
      projection = project([
        event("operation_start", "root", "invoke_agent player", 0),
        event("operation_start", "a", "chat a", 10, parent_operation_id: "root"),
        event("operation_start", "b", "chat b", 30, parent_operation_id: "root"),
        event("operation_end", "a", "chat a", 60, duration_ms: 50),
        event("operation_end", "b", "chat b", 80, duration_ms: 50),
        event("operation_end", "root", "invoke_agent player", 100, duration_ms: 100)
      ])

      assert_equal 30.0, projection.spans["root"][:self_ms]
    end

    # session_story_tree.md Phase 2: reading order. A child span is keyed by
    # its own operation_start seq, so the timeline can interleave it with
    # entries the span owns directly without the UI walking both lists itself.
    test "timeline interleaves owned entries and child spans in log sequence order" do
      projection = project([
        event("operation_start", "chat", "chat model", 0),
        content_event("injected_context", "chat", 1),
        content_event("request", "chat", 2),
        event("operation_end", "chat", "chat model", 3, duration_ms: 3)
      ])

      timeline = projection.spans["chat"][:timeline]
      assert_equal [
        { kind: "entry", seq: 2 },
        { kind: "entry", seq: 3 }
      ], timeline
    end

    test "a chat span owns its injected context, request, plan and response by stamped operation_id" do
      projection = project([
        event("operation_start", "chat", "chat model", 0),
        content_event("injected_context", "chat", 1),
        content_event("request", "chat", 2),
        event("operation_end", "chat", "chat model", 3, duration_ms: 3),
        content_event("plan", "chat", 4),
        content_event("response", "chat", 5)
      ])

      # `response` parses to an `:assistant` entry — the phase name on the
      # wire and the entry TYPE the reader gets differ for exactly this event.
      owned_phases = projection.spans["chat"][:direct_entry_seqs].map { |seq| @entries_by_seq[seq] }
      assert_equal %w[injected_context request plan assistant], owned_phases
    end

    # Nothing in the log may be unreachable from the tree — content written
    # before any span existed (or genuinely orphaned) is folded under one
    # synthetic root rather than silently dropped.
    test "a synthetic session root owns orphaned entries with no containing span" do
      projection = project([
        content_event("compaction", nil, 0),
        event("operation_start", "root", "invoke_agent player", 1),
        event("operation_end", "root", "invoke_agent player", 5, duration_ms: 4)
      ])

      assert_includes projection.roots, "session_root"
      root = projection.spans["session_root"]
      assert_equal "session", root[:semantic_kind]
      # seq 1: the compaction line is first in the file, and structural
      # operation_start/operation_end events consume the seq counter too.
      assert_equal [ 1 ], root[:direct_entry_seqs]
      assert_equal [ { kind: "entry", seq: 1 } ], root[:timeline]
    end

    test "a well-instrumented session with nothing left over gets no synthetic root" do
      projection = project([
        event("operation_start", "root", "invoke_agent player", 0),
        event("operation_end", "root", "invoke_agent player", 5, duration_ms: 5)
      ])

      refute_includes projection.spans.keys, "session_root"
    end

    # Read from the stamped attribute first, falling back to the per-entry
    # turn/iteration the parser already tracks for every line.
    test "turn and iteration numbers are read from stamped span attributes" do
      projection = project([
        event("operation_start", "root", "invoke_agent player", 0,
              attributes: { "boukensha.turn.n" => 2 })
      ])

      assert_equal 2, projection.spans["root"][:turn]
    end

    test "turn falls back to the per-entry tracking when the span carries no attribute" do
      Tempfile.create([ "trace", ".jsonl" ]) do |file|
        file.puts({ phase: "session_start", at: "2026-01-01T00:00:00Z", mono_ms: 0 }.to_json)
        file.puts({ phase: "turn", n: 4, mono_ms: 1, at: iso(1) }.to_json)
        file.puts(event("operation_start", "root", "invoke_agent player", 2).to_json)
        file.puts(event("operation_end", "root", "invoke_agent player", 5, duration_ms: 3).to_json)
        file.flush
        projection = TraceProjection.new(Parser.load(file.path), live: false)

        assert_equal 4, projection.spans["root"][:turn]
      end
    end

    # The legacy fallback (fix_transcripts.md): a file with no operation_id on
    # its content events still resolves each one to its narrowest containing
    # window, and the rewritten sweep must answer exactly what the old
    # brute-force scan did.
    test "unstamped entries still resolve to the narrowest containing span" do
      projection = project([
        event("operation_start", "outer", "invoke_agent player", 0),
        event("operation_start", "inner", "chat model", 10, parent_operation_id: "outer"),
        content_event("response", nil, 15),
        event("operation_end", "inner", "chat model", 20),
        event("operation_end", "outer", "invoke_agent player", 30)
      ])

      # seq 3: operation_start(outer)=1, operation_start(inner)=2, response=3.
      assert_equal [ 3 ], projection.spans["inner"][:direct_entry_seqs]
      assert_equal [], projection.spans["outer"][:direct_entry_seqs]
      assert_includes projection.spans["inner"][:diagnostics], "inferred_entries"
    end

    private

    def project(events)
      Tempfile.create(["trace", ".jsonl"]) do |file|
        file.puts({ phase: "session_start", at: "2026-01-01T00:00:00Z", mono_ms: 0 }.to_json)
        events.each { |row| file.puts(row.to_json) }
        file.flush
        parser = Parser.load(file.path)
        @entries_by_seq = parser.entries.to_h { |e| [ e.seq, e.type.to_s ] }
        return TraceProjection.new(parser, live: false)
      end
    end

    def event(phase, id, operation, mono_ms, **extra)
      { phase: phase, operation_id: id, operation: operation, mono_ms: mono_ms, at: iso(mono_ms) }.merge(extra)
    end

    # A content event with no span identity of its own, the way an unstamped
    # (or genuinely orphaned) line looks on disk: `operation_id` present only
    # when a caller passes one, never as an explicit null.
    def content_event(phase, operation_id, mono_ms, **extra)
      { phase: phase, mono_ms: mono_ms, at: iso(mono_ms) }
        .merge(operation_id ? { operation_id: operation_id } : {})
        .merge(extra)
    end

    def iso(mono_ms)
      (Time.utc(2026, 1, 1) + mono_ms / 1000.0).iso8601(3)
    end
  end
end
