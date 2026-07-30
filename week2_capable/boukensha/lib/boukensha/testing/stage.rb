require "json"
require "securerandom"

module Boukensha
  module Testing
    # Staged model answers, addressed by (task, ordinal) — mocking_messages.md
    # §3.
    #
    # The problem this exists for is that the region pipeline has three
    # consumers of a model and each is unobservable for a different reason: the
    # player has to walk far enough to build a sprawling region, the navigator
    # has to volunteer `scope_suspect: true`, and the cartographer only runs
    # once the navigator has. Staging the calls we are not measuring and leaving
    # exactly one live turns "we have never seen a region split" into a run that
    # costs one model call.
    #
    # It installs as a wrapper around ONE method. Every model call in the system
    # passes through `Client#call`, and the three construction sites
    # (`Boukensha.run`, `.repl`, `.run_task`) each know which task they are
    # building for, so no task gains a test mode: the navigator gains nothing at
    # all and is simply answered by something other than the network.
    #
    # Two properties worth stating because they are what make a staged run
    # evidence rather than theatre:
    #
    # * A staged answer for a reasoner is handed back as TEXT and goes through
    #   `Reasoners.parse` exactly as a live answer would, so the parser, its
    #   fence-stripping tolerance and its nil-on-garbage behaviour all stay
    #   under test rather than being bypassed.
    # * A staged player answer carrying `tools:` produces real `tool_use` blocks
    #   which `Agent#handle_tool_calls` really dispatches, so the character
    #   really walks, the store is really written, and the tool result the model
    #   receives is genuine. That is the whole reason this supersedes the
    #   earlier idea of prefilling the transcript with fabricated tool results
    #   (§4): a fabricated result is fiction, a staged turn is a real code path.
    class Stage
      class Error < StandardError; end

      # The tasks a scenario may address. A closed set, because the population
      # of likely mistakes here is entirely typos of these four names and a
      # misspelt task would otherwise stage nothing, cost real money, and
      # produce a report describing a configuration nobody chose.
      TASKS = %w[player navigator cartographer judge].freeze

      # The keys that make an entry an AGENT TURN rather than a field document.
      # Everything else in an entry is taken to be the JSON the reasoner would
      # have answered with.
      TURN_KEYS = %w[text tools].freeze

      Answer = Struct.new(:text, :tools, keyword_init: true)

      # `spec` is kept verbatim because it is what travels to the child: the
      # payload is a JSON file and the parsed queues are not JSON, so the child
      # rebuilds the Stage from the same document the parent validated rather
      # than from a serialisation of the parent's parse of it.
      attr_reader :because, :queues, :spec

      # spec: the scenario's `stage:` block, already normalized to string keys.
      def self.build(spec)
        return nil if spec.nil? || spec.empty?

        new(spec)
      end

      def initialize(spec)
        @spec      = spec.transform_keys(&:to_s)
        @because   = @spec["because"].to_s
        @queues    = self.class.validate!(@spec)
        @consumed  = Hash.new(0)
      end

      # ---------- validation, at LOAD time -----------------------------------

      # Everything below fails with a sentence before anything is seeded. A
      # staged run that discovers its own misconfiguration halfway through has
      # already spent the money the staging existed to save.
      def self.validate!(spec)
        because = spec["because"].to_s.strip
        # Required, and prose. A staged run is a claim about what the other
        # agents would have said, and the claim needs an author.
        raise Error, "stage: needs a `because:` saying what this run is measuring and why the " \
                     "staged agents are staged — a staged run is a claim about what the other " \
                     "agents would have said, and the claim needs an author" if because.empty?

        tasks = spec.reject { |key, _| key == "because" }
        raise Error, "stage: names no tasks (known: #{TASKS.join(', ')}); anything not named stays live" if tasks.empty?

        tasks.each_with_object({}) do |(task, entries), out|
          unless TASKS.include?(task)
            raise Error, "stage: names no task #{task.inspect} (known: #{TASKS.join(', ')})"
          end
          unless entries.is_a?(Array) && !entries.empty?
            raise Error, "stage.#{task} must be a non-empty list of answers, consumed one per call in order, " \
                         "got #{entries.inspect}"
          end

          out[task] = entries.each_with_index.map { |entry, index| answer_for(task, index, entry) }
        end
      end

      # An entry is either an agent turn (`text:` / `tools:`) or the field
      # document a reasoner's prompt asks for. Mixing the two is refused rather
      # than guessed at: an entry carrying both `text:` and `direction:` could
      # mean either, and a wrong guess stages an answer nobody wrote.
      def self.answer_for(task, index, entry)
        label = "stage.#{task}[#{index}]"
        raise Error, "#{label} must be a mapping, got #{entry.inspect}" unless entry.is_a?(Hash)

        entry = entry.transform_keys(&:to_s)
        turn  = entry.keys & TURN_KEYS
        other = entry.keys - TURN_KEYS

        if !turn.empty? && !other.empty?
          raise Error, "#{label} mixes an agent turn (#{turn.join(', ')}) with answer fields " \
                       "(#{other.join(', ')}) — an entry is either what the agent SAID or the " \
                       "JSON document its prompt asks for, and which one this is cannot be guessed"
        end

        return Answer.new(text: JSON.pretty_generate(entry), tools: []) if turn.empty?

        Answer.new(text: entry["text"].to_s, tools: tool_calls_for(label, entry["tools"]))
      end

      def self.tool_calls_for(label, tools)
        return [] if tools.nil?
        raise Error, "#{label}.tools must be a list of { name:, args: }" unless tools.is_a?(Array)

        tools.each_with_index.map do |call, index|
          call = call.is_a?(Hash) ? call.transform_keys(&:to_s) : {}
          name = call["name"].to_s
          raise Error, "#{label}.tools[#{index}] names no tool" if name.empty?

          args = call["args"] || {}
          raise Error, "#{label}.tools[#{index}].args must be a mapping" unless args.is_a?(Hash)

          { "name" => name, "args" => args }
        end
      end

      # ---------- answering ---------------------------------------------------

      def staged?(task) = @queues.key?(task.to_s)

      def staged_tasks = @queues.keys
      def live_tasks   = TASKS - staged_tasks

      # Every task is staged, so nothing in this run is a measurement of a
      # model — which is a legitimate thing to want once (a shape test) and
      # never a thing to want five times (§14).
      def fully_staged? = live_tasks.empty?

      # The next answer for `task`, as a provider-shaped response body — the
      # same thing the network would have returned, so nothing downstream of the
      # client knows the difference.
      #
      # Running off the end is an ERROR that names the task and the call number,
      # never a silent fall-through to the network: a run that quietly started
      # paying for real calls halfway through would produce a report describing
      # a configuration nobody chose.
      def answer!(task:, backend:)
        task    = task.to_s
        queue   = @queues.fetch(task) { raise Error, "task #{task.inspect} is not staged" }
        ordinal = @consumed[task]
        answer  = queue[ordinal] or raise Error, exhausted(task, queue.size)

        @consumed[task] += 1
        backend.staged_response(text: answer.text, tools: answer.tools)
      end

      def answered(task) = @consumed[task.to_s]

      def exhausted(task, staged)
        "stage.#{task} ran out: call #{staged + 1} was made and only #{staged} answer" \
          "#{'s' unless staged == 1} #{staged == 1 ? 'is' : 'are'} staged. Every model call the task makes " \
          "consumes one, including the wind-down call `Agent#wrap_up` makes when a run trips " \
          "`max_iterations` or `max_turn_tokens` — that is the one easy to forget."
      end

      # ---------- provenance (§7) --------------------------------------------

      # What the `launch` record carries, and therefore what the report row and
      # the session view show. The most valuable line in the report for a staged
      # run is not the pass rate, it is which task was LIVE, because that is the
      # only column that says what the run actually measured.
      def as_launch
        { "because" => @because, "staged" => counts, "live" => live_tasks }
      end

      def counts = @queues.transform_values(&:size)

      # The arm label's suffix. A staged run and a live one are not two samples
      # of one population — staging changes which agent was doing the thinking,
      # which is a larger difference than any setting — so the staged set is
      # part of the arm key and a report cannot average across it.
      def arm_label = "live: #{live_tasks.empty? ? 'nothing' : live_tasks.join(',')}"

      # `--dry-run`'s view, so the whole of §3 is reviewable before anything is
      # seeded and before anything is paid for.
      def describe
        staged = counts.map { |task, n| "#{task} ×#{n}" }.join(", ")
        "staged #{staged}; live #{live_tasks.empty? ? '(nothing)' : live_tasks.join(', ')}"
      end
    end
  end
end
