require "json"
require_relative "../tasks/judge"

module Boukensha
  module Testing
    # Tier 2: the model's verdict on one case.
    #
    # Two rules the harness enforces around it, both of which are the reason
    # tier 1 runs first:
    #
    # - **The judge cannot overturn tier 1.** A case failing a hard `expect` is
    #   `fail`, whatever the judge says. The judge can only downgrade a
    #   mechanical pass, never rescue a mechanical fail.
    # - **A malformed response is an error, not a silent pass.** A judge that
    #   returned prose has told us nothing, and nothing is not agreement.
    class Judge
      class Error < StandardError; end

      # The judge is given a DIGEST, not the transcript: a few hundred tokens
      # rather than the tens of thousands the raw log holds. `RESULT_CHARS` is
      # what makes that true — a room description is 400 characters of prose
      # the rubric never asks about, and the first line of it is enough to tell
      # a successful `look` from a refusal.
      RESULT_CHARS = 240

      Verdict = Struct.new(:verdict, :desired, :undesired, :reasoning, :confidence,
                           :session_id, :error, keyword_init: true) do
        def failed?  = verdict.to_s == "fail"
        def errored? = !error.nil?

        def as_json
          { verdict: verdict, confidence: confidence, reasoning: reasoning,
            desired: desired, undesired: undesired, session_id: session_id,
            error: error }.compact
        end
      end

      def initialize(log_dir: nil, runner: nil)
        @log_dir = log_dir
        # Injectable so the harness's own tests can assert the parsing and the
        # tier-1 precedence without spending a model call on it.
        @runner  = runner || method(:run_task)
      end

      # facts: SessionFacts. evaluation: the scenario's `evaluation:` block.
      def call(facts:, goal:, evaluation:, case_label: nil)
        digest = digest_for(facts, goal: goal, evaluation: evaluation)
        log    = log_path(case_label || facts.session_id)
        raw    = @runner.call(digest, log)
        parse(raw, session_id: (log && File.basename(log, ".jsonl")))
      rescue StandardError => e
        Verdict.new(verdict: "error", error: e.message)
      end

      # ---------- the digest -------------------------------------------------

      # Hook traffic is excluded. The rubric is written about what the agent
      # CHOSE, and the framework's bootstrap `score`/`look` is noise that
      # reliably confuses a judge into penalising the agent for calls it did not
      # make.
      def digest_for(facts, goal:, evaluation:)
        trace = facts.tool_calls.select(&:model?).map do |call|
          {
            call_id: call.call_id,
            tool: call.name,
            args: call.args,
            ok: call.ok,
            result: truncate(call.result)
          }.compact
        end

        {
          goal: goal.to_s,
          desired_behaviour: evaluation["desired_behaviour"].to_s,
          undesired_behaviour: evaluation["undesired_behaviour"].to_s,
          trace: trace,
          said: assistant_turns(facts),
          final_answer: assistant_turns(facts).last,
          outcome: { end_reason: facts.end_reason, final_room: facts.final_room }
        }
      end

      def to_prompt(digest) = JSON.pretty_generate(digest)

      # ---------- parsing ----------------------------------------------------

      # Strict, but tolerant of a model that wrapped its JSON in a fence — that
      # is a formatting slip, not a refusal to answer, and treating it as one
      # would throw away a verdict that is right there.
      def parse(raw, session_id: nil)
        text = raw.to_s.strip
        text = Regexp.last_match(1).strip if text =~ /```(?:json)?\s*(.+?)```/m
        # A model that prefaced its JSON with a sentence still answered; take
        # the outermost object and ignore the sentence.
        text = text[text.index("{")..text.rindex("}")] if text.include?("{") && text.include?("}")

        doc = JSON.parse(text)
        raise Error, "judge returned #{doc.class}, expected an object" unless doc.is_a?(Hash)

        verdict = doc["verdict"].to_s
        raise Error, "judge verdict #{verdict.inspect} is neither pass nor fail" unless %w[pass fail].include?(verdict)

        Verdict.new(
          verdict: verdict,
          desired: Array(doc["desired"]),
          undesired: Array(doc["undesired"]),
          reasoning: doc["reasoning"].to_s,
          confidence: doc["confidence"],
          session_id: session_id
        )
      rescue JSON::ParserError => e
        Verdict.new(verdict: "error", session_id: session_id,
                    error: "judge did not return JSON (#{e.message}): #{raw.to_s[0, 200].inspect}")
      rescue Error => e
        Verdict.new(verdict: "error", session_id: session_id, error: e.message)
      end

      # The merge rule, in one place. Tier 1 is sovereign.
      def self.merge_status(expectations_passed, verdict)
        return "fail" unless expectations_passed
        return "error" if verdict&.errored?
        return "fail"  if verdict&.failed?

        "pass"
      end

      private

      def run_task(digest, log)
        # `tools: false` — the judge reads text and answers text. Registering
        # the MUD server for it would open a second telnet login for a task
        # that cannot use one.
        Boukensha.run_task(Tasks::Judge, to_prompt(digest), log: log, tools: false)
      end

      # A judge call is itself a session log, openable in mud_monitor when you
      # distrust a verdict. That is the whole reason it goes through run_task
      # rather than straight at a backend.
      def log_path(label)
        return nil unless @log_dir

        FileUtils.mkdir_p(@log_dir)
        File.join(@log_dir, "#{label.to_s.gsub(/[^\w.-]+/, '_')}.jsonl")
      end

      def assistant_turns(facts)
        facts.events.select { |e| e["phase"] == "response" }
             .map { |e| e["text"].to_s.strip }
             .reject(&:empty?)
      end

      def truncate(text)
        text = text.to_s
        return nil if text.empty?
        return text if text.length <= RESULT_CHARS

        "#{text[0, RESULT_CHARS]}… (#{text.length} chars)"
      end
    end
  end
end
