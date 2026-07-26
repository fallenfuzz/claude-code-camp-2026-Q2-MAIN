require "time"

module SessionLog
  # A single, compatibility-aware trace model shared by every session-detail
  # consumer. Span names remain labels; semantic_kind is the UI contract.
  class TraceProjection
    SEMANTIC_KINDS = %w[
      invoke_agent iteration chat execute_tool hook state after_tool
      compaction wrap_up internal
    ].freeze

    attr_reader :roots, :spans, :orphan_entry_seqs

    def initialize(parser, live:)
      @parser = parser
      @live = live
      @roots = []
      @spans = {}
      @orphan_entry_seqs = []
      build
    end

    def as_json(*)
      { roots: roots, spans: spans, orphan_entry_seqs: orphan_entry_seqs }
    end

    def self.semantic_kind(name, recorded = nil)
      return recorded if SEMANTIC_KINDS.include?(recorded)

      value = name.to_s
      return "invoke_agent" if value == "turn" || value.start_with?("invoke_agent ")
      return "iteration" if value == "iteration"
      return "chat" if value == "llm.generate" || value.start_with?("chat ")
      return "execute_tool" if value.start_with?("tool.") || value.start_with?("execute_tool ")
      return "after_tool" if ["after_tool", "record outcome"].include?(value)
      return "compaction" if value == "compaction"
      return "wrap_up" if value == "wrap_up"
      return "hook" if ["player_bootstrap", "bootstrap player", "position_refresh",
                        "establish position", "room_disambiguation", "room_survey",
                        "async_poll", "poll"].include?(value)
      return "state" if value.include?("state") || value.include?("render")

      "internal"
    end

    private

    def build
      ends = @parser.operation_ends.to_h { |entry| [entry.operation_id, entry] }
      @parser.operation_starts.each do |start|
        next unless start.operation_id

        finish = ends[start.operation_id]
        attributes = (start.attributes || {}).merge(finish&.attributes || {})
        @spans[start.operation_id] = {
          id: start.operation_id, parent_id: start.parent_operation_id,
          child_ids: [], trace_id: start.trace_id || finish&.trace_id,
          span_id: start.span_id || finish&.span_id, name: start.operation,
          semantic_kind: self.class.semantic_kind(start.operation, start.semantic_kind),
          task: start.task, initiator: start.initiator || attributes["boukensha.tool.initiator"],
          trigger: start.trigger || attributes["boukensha.trigger"],
          # Read from the stamped attribute first (session_story_tree.md
          # Phase 1.3), falling back to the per-entry turn/iteration the
          # parser already tracks for every line — present even on a log
          # written before that attribute existed.
          turn: attributes["boukensha.turn.n"] || start.turn,
          iteration: attributes["boukensha.iteration.n"] || start.iteration,
          start_at: start.at, start_mono_ms: start.mono_ms,
          end_at: finish&.at, duration_ms: finish&.duration_ms,
          self_ms: nil, status: span_status(finish),
          attributes: attributes, rollup: finish&.rollup || {},
          direct_entry_seqs: [], diagnostics: [], timeline: []
        }
      end
      link_hierarchy
      assign_entries
      build_session_root
      @spans.each_value { |span| span[:self_ms] = self_time(span) }
      @spans.each_value { |span| span[:timeline] = build_timeline(span) }
    end

    def span_status(finish)
      return finish.ok == false ? "error" : "ok" if finish

      @live ? "running" : "incomplete"
    end

    def link_hierarchy
      @spans.each_value do |span|
        parent_id = span[:parent_id]
        if parent_id && @spans[parent_id] && !cycle?(span[:id], parent_id)
          @spans[parent_id][:child_ids] << span[:id]
        else
          span[:diagnostics] << (parent_id ? "broken_parent" : "root")
          span[:parent_id] = nil
          @roots << span[:id]
        end
      end
    end

    def cycle?(id, parent_id)
      seen = { id => true }
      cursor = parent_id
      while cursor
        return true if seen[cursor]

        seen[cursor] = true
        cursor = @spans[cursor]&.dig(:parent_id)
      end
      false
    end

    def assign_entries
      structural = %i[operation_start operation_end]
      candidates = @parser.entries.reject { |entry| structural.include?(entry.type) }
      inferred_owners = narrowest_owners(candidates)

      candidates.each do |entry|
        owner = @spans[entry.operation_id]
        inferred = owner.nil?
        owner ||= inferred_owners[entry.seq]

        if owner
          owner[:direct_entry_seqs] << entry.seq
          owner[:diagnostics] << "inferred_entries" if inferred &&
            !owner[:diagnostics].include?("inferred_entries")
        else
          @orphan_entry_seqs << entry.seq
        end
      end
    end

    # The legacy fallback for entries an unstamped log never attached to a
    # span: the narrowest span whose [start_seq, end_seq) window contains it.
    #
    # Rewritten as a single seq-ordered sweep rather than a span-per-entry
    # scan (fix_transcripts.md flagged the O(n·m) cost): span opens/closes and
    # the entries needing inference are merged into one seq-ordered list, and
    # an "active spans" set is maintained across the sweep. A query costs
    # O(current nesting depth) — bounded by how deep the log actually nests —
    # instead of O(total spans in the session), while answering exactly the
    # same question the brute-force scan did: the minimum-width interval
    # currently open.
    def narrowest_owners(candidates)
      needing = candidates.reject { |entry| @spans[entry.operation_id] }
      return {} if needing.empty?

      events = []
      @spans.each_value do |span|
        events << [start_seq(span[:id]), 0, :open, span[:id]]
        finish = end_seq(span[:id])
        events << [finish, 2, :close, span[:id]] unless finish == Float::INFINITY
      end
      needing.each { |entry| events << [entry.seq, 1, :query, entry] }
      events.sort_by! { |seq, order, _kind, _payload| [seq, order] }

      active = {}
      owners = {}
      events.each do |_seq, _order, kind, payload|
        case kind
        when :open
          active[payload] = end_seq(payload) - start_seq(payload)
        when :close
          active.delete(payload)
        when :query
          next if active.empty?

          narrowest_id = active.min_by { |_id, width| width }.first
          owners[payload.seq] = @spans[narrowest_id]
        end
      end
      owners
    end

    # session_story_tree.md Phase 2: nothing in the log may be unreachable
    # from the tree. Today that means everything `assign_entries` could not
    # attach to any span (a genuine orphan, or content the writer emitted
    # before any span had opened) — folded under one synthetic root rather
    # than silently dropped. Absent entirely from a well-instrumented session
    # with nothing left over.
    SESSION_ROOT_ID = "session_root".freeze

    def build_session_root
      return if @orphan_entry_seqs.empty?

      @spans[SESSION_ROOT_ID] = {
        id: SESSION_ROOT_ID, parent_id: nil, child_ids: [],
        trace_id: nil, span_id: nil, name: "session",
        semantic_kind: "session", task: nil, initiator: nil, trigger: nil,
        turn: nil, iteration: nil,
        start_at: nil, start_mono_ms: nil, end_at: nil, duration_ms: nil,
        self_ms: nil, status: @live ? "running" : "ok",
        attributes: {}, rollup: {},
        direct_entry_seqs: @orphan_entry_seqs.dup, diagnostics: ["synthetic"],
        timeline: []
      }
      @roots.unshift(SESSION_ROOT_ID)
    end

    # Reading order: a child span is keyed by its OWN operation_start seq, so
    # "the injected context came before the chat child and the tool card came
    # after it" is answerable by sorting one list instead of the UI walking
    # entries and children separately and re-discovering the interleaving.
    def build_timeline(span)
      items = span[:direct_entry_seqs].map { |seq| [seq, { kind: "entry", seq: seq }] }
      items += span[:child_ids].map { |id| [start_seq(id), { kind: "span", id: id }] }
      items.sort_by(&:first).map(&:last)
    end

    def start_seq(id)
      @start_seqs ||= @parser.operation_starts.to_h { |entry| [entry.operation_id, entry.seq] }
      @start_seqs[id] || -1
    end

    def end_seq(id)
      @end_seqs ||= @parser.operation_ends.to_h { |entry| [entry.operation_id, entry.seq] }
      @end_seqs[id] || Float::INFINITY
    end

    def self_time(span)
      total = span[:duration_ms]
      return nil unless total

      intervals = span[:child_ids].filter_map do |id|
        child = @spans[id]
        child_interval(child)
      end.sort_by(&:first)
      covered = intervals.each_with_object([]) do |(left, right), merged|
        if merged.empty? || left > merged.last[1]
          merged << [left, right]
        else
          merged.last[1] = [merged.last[1], right].max
        end
      end.sum { |left, right| right - left }
      [total.to_f - covered, 0].max.round(3)
    end

    def child_interval(span)
      return nil unless span[:duration_ms]

      left = span[:start_mono_ms] || parse_time(span[:start_at])
      return nil unless left

      [left.to_f, left.to_f + span[:duration_ms].to_f]
    end

    def parse_time(value)
      Time.iso8601(value).to_f * 1000 if value
    rescue ArgumentError
      nil
    end
  end
end
