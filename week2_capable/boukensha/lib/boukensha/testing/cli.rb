require "json"
require_relative "fixtures"
require_relative "overrides"
require_relative "runner"
require_relative "session_facts"
require_relative "expectations"
require_relative "judge"
require_relative "report"
require_relative "map_memory"
require_relative "run_log"

module Boukensha
  module Testing
    # The test harness's entry point. Everything ARGV-shaped lives here; nothing
    # below this file knows a flag exists.
    #
    #   boukensha -ts find_bakery                  # one case
    #   boukensha -ts find_bakery --batch 20       # same scenario, 20 times
    #   boukensha -tsp banking                     # a plan
    #   boukensha -ts find_bakery --dry-run        # resolve and print, run nothing
    #   boukensha -ts find_bakery --no-judge       # tier 1 only, zero judge cost
    class CLI
      def initialize(options, root_dir:, out: $stdout)
        @options  = options
        @root_dir = root_dir
        @out      = out
      end

      def run
        case @options[:mode]
        when :case         then run_case
        when :list         then list
        when :snapshot_map then snapshot_map
        when :scenario     then run_suite(kind: "scenario")
        when :plan         then run_suite(kind: "plan")
        else
          warn "boukensha: unknown test mode #{@options[:mode].inspect}"
          1
        end
      rescue Fixtures::Error, Overrides::Error, MapMemory::Error => e
        # A fixture problem is a sentence, not a backtrace: it is a thing the
        # author typed, and they are the one reading this.
        warn "boukensha: #{e.message}"
        1
      end

      # ---------- modes ------------------------------------------------------

      # The internal child mode (§5.2). One case, this process, then exit.
      def run_case
        require_relative "case_runner"
        raw     = @options[:payload]
        payload = File.file?(raw) ? JSON.parse(File.read(raw)) : JSON.parse(raw)
        CaseRunner.run(payload)
      end

      def list
        names = @options[:kind] == :plans ? fixtures.plan_names : fixtures.scenario_names
        names.each { |name| @out.puts name }
        0
      end

      # `--snapshot-map <name>` pins whatever the profile holds RIGHT NOW;
      # `--snapshot-map <name> --from-session <id>` pins the map a retained
      # session ended with. The second form is how a good exploration run
      # becomes a fixture after the fact — by the time a run has been read, the
      # profile's live map belongs to whatever ran next.
      def snapshot_map
        profile = @options[:profile] || ENV["BOUKENSHA_PROFILE"]
        unless profile
          warn "boukensha: --snapshot-map needs --profile NAME (whose map are we pinning?)"
          return 1
        end

        source = @options[:from_session]
        path   = map_memory(profile).snapshot!(@options[:name], from_session: source)
        @out.puts "Wrote map snapshot: #{path}#{" (from session #{source})" if source}"
        0
      end

      def map_memory(profile)
        MapMemory.new(
          profile_dir:  File.join(@root_dir, "profiles", profile),
          profiles_dir: File.join(@root_dir, "profiles"),
          maps_dir:     fixtures.maps_dir,
          sessions_dir: fixtures.session_maps_dir(profile)
        )
      end

      def run_suite(kind:)
        cases  = resolve_cases(kind)
        run_id = Report.new_run_id

        return dry_run(cases, run_id: run_id, kind: kind) if @options[:dry_run]

        # Opened BEFORE anything slow, so the very first thing a reader sees is
        # what is about to happen rather than a blank terminal.
        log = RunLog.new(path: run_log_path(run_id), echo: (@out unless @options[:quiet]))
        env = environment(cases)
        log.say "run    #{@options[:name]} — #{cases.size} case#{'s' unless cases.size == 1}, " \
                "profile #{cases.map(&:player_profile).uniq.join(', ')}, model #{env[:model]}"
        cases.uniq(&:base_initial_state).each { |k| log.event("fixture", describe_state(k)) }

        report = Report.new(kind: kind, name: @options[:name], run_id: run_id, environment: env)
        runner = Runner.new(root_dir: @root_dir, work_dir: work_dir(run_id), run_log: log,
                            verbose: @options[:verbose])

        runner.run(cases, run_id: run_id, plan: (@options[:name] if kind == "plan")) do |outcome|
          row = assess(outcome, run_id: run_id)
          report << row
          log.event("grade", grade_line(row), index: outcome.index, total: cases.size)
        end

        path = report.write!(fixtures.reports_dir, path: @options[:report])
        log.say "run    #{summary_line(report)}"
        log.say "run    report #{path}"
        log.say "run    log    #{log.path}" if log.path
        log.close
        # A run that produced a report has done its job. The exit status
        # reflects the AGENT's results, so a batch can gate CI without the
        # caller parsing JSON.
        report.summary[:failed].zero? && report.summary[:errored].zero? ? 0 : 1
      end

      # ---------- resolution ---------------------------------------------------

      def resolve_cases(kind)
        cli_state = Overrides.parse_sets(@options[:set])
        common = { cli_state: cli_state, profile: @options[:profile], map_memory: @options[:map_memory] }

        if kind == "plan"
          fixtures.resolve_plan(@options[:name], batch: @options[:batch], **common)
        else
          fixtures.resolve_scenario(@options[:name], batch: @options[:batch] || 1, **common)
        end
      end

      def dry_run(cases, run_id:, kind:)
        runner = Runner.new(root_dir: @root_dir)
        @out.puts JSON.pretty_generate(
          run_id: run_id, kind: kind, name: @options[:name], cases: cases.size,
          resolved: runner.payloads(cases, run_id: run_id, plan: (@options[:name] if kind == "plan"))
        )
        0
      end

      # ---------- assessment ---------------------------------------------------

      # Tier 1 first, always. `expect:` is a projection of the session log and a
      # model should never be asked to judge something a grep can decide — nor
      # be paid to.
      def assess(outcome, run_id:)
        kase        = outcome.case
        profile_dir = File.join(@root_dir, "profiles", kase.player_profile)
        session_id  = outcome.result&.dig("session_id")
        map         = outcome.result&.dig("map_memory") || {}
        session_path = session_id && File.join(profile_dir, "sessions", "#{session_id}.jsonl")

        row = {
          index: outcome.index,
          scenario: kase.scenario,
          session_id: session_id,
          session_name: kase.session_name,
          profile: kase.player_profile,
          resolved_state: kase.state,
          base_initial_state: kase.base_initial_state,
          map_memory: map,
          seed_log: outcome.seed_log
        }

        unless session_path && File.file?(session_path)
          return row.merge(status: "error", error: outcome.error || "no session log was written",
                           error_kind: outcome.error_kind || "no_session")
        end

        facts = SessionFacts.load(session_path,
                                  knowledge_db: File.join(profile_dir, Mud::Memory::Store::FILENAME),
                                  rooms_at_start: map["rooms_at_start"])
        row[:facts]  = facts.to_h
        row[:errors] = facts.errors(File.join(profile_dir, "error.log"))

        # A child that failed is an ERROR whatever its (partial) log says. A
        # broken harness and a failing agent are different findings, and
        # conflating them is how you spend an afternoon debugging a model that
        # was never called.
        if outcome.status == "error"
          return row.merge(status: "error", error: outcome.error, error_kind: outcome.error_kind)
        end

        results = Expectations.evaluate(kase.expect, facts)
        row[:expectations] = results.map(&:as_json)
        passed = Expectations.passed?(results)

        verdict = judge_case(kase, facts, run_id: run_id) unless @options[:no_judge] || kase.evaluation.empty?
        row[:judge] = verdict.as_json if verdict

        row.merge(status: Judge.merge_status(passed, verdict))
      end

      def judge_case(kase, facts, run_id:)
        judge.call(facts: facts, goal: kase.goal, evaluation: kase.evaluation,
                   case_label: facts.session_id)
      end

      def judge
        @judge ||= Judge.new(log_dir: File.join(fixtures.reports_dir, "judge"))
      end

      # ---------- reporting ----------------------------------------------------

      # A batch of 20 is a measurement of ONE configuration. `settings_digest`
      # is what lets a reader refuse to compare two runs that were not.
      def environment(cases)
        config = Boukensha.config
        {
          profile: cases.map(&:player_profile).uniq.join(", "),
          provider: config.provider_type,
          model: config.model,
          boukensha_version: VERSION,
          git_sha: Launch.git_sha,
          settings_digest: Launch.settings_digest(config),
          judge: judge_environment
        }.compact
      rescue StandardError
        # The report is worth more than its header. A config that will not load
        # here would have failed the cases anyway, and they carry their own
        # provenance in `session_start`.
        {}
      end

      def judge_environment
        return nil if @options[:no_judge]

        settings = Boukensha.config.tasks("judge")
        return nil if settings.nil? || settings.empty?

        { provider: settings["provider"], model: settings["model"] }.compact
      end

      # The verdict, with the REASON on the same line. "fail" alone sends the
      # reader to the JSON; "fail — execute_route never called" usually does not.
      def grade_line(row)
        mark   = { "pass" => "✓", "fail" => "✗", "error" => "!" }[row[:status]]
        return "#{mark} #{row[:status]} — #{row[:error_kind]}: #{row[:error]}" if row[:status] == "error"

        why = Array(row[:expectations]).reject { |e| e[:ok] }
                                       .map { |e| "#{e[:rule]}#{" (#{e[:detail]})" if e[:detail]}" }
        why << "judge: #{row.dig(:judge, :reasoning)}" if row.dig(:judge, :verdict) == "fail"
        "#{mark} #{row[:status]}#{" — #{why.first(3).join('; ')}" unless why.empty?}"
      end

      # What the case is starting from, said once per distinct state rather than
      # once per case — twenty identical lines is not information.
      def describe_state(kase)
        state = kase.state || {}
        bits = [
          ("state #{kase.base_initial_state}" if kase.base_initial_state),
          ("level #{state['level']}" if state["level"]),
          ("room #{state['location']}" if state["location"]),
          ("#{state['money']['gold']} gold" if state.dig("money", "gold")),
          ("#{Array(state['inventory']).size} items" if state["inventory"]),
          ("#{Array(state['equipment']).size} equipped" if state["equipment"])
        ].compact
        bits.join(", ")
      end

      def summary_line(report)
        s = report.summary
        "#{s[:cases]} case#{'s' unless s[:cases] == 1}: #{s[:passed]} passed, #{s[:failed]} failed, #{s[:errored]} errored " \
          "(#{s[:pass_rate] ? (s[:pass_rate] * 100).round(1) : '—'}%)  " \
          "agent #{format('$%.4f', s.dig(:cost_usd, :agent).to_f)} / " \
          "judge #{format('$%.4f', s.dig(:cost_usd, :judge).to_f)}"
      end

      def fixtures
        @fixtures ||= Fixtures.new(dir: File.join(@root_dir, "tests"),
                                   profiles_dir: File.join(@root_dir, "profiles"))
      end

      def work_dir(run_id)
        File.join(fixtures.reports_dir, ".work", run_id)
      end

      # Same directory and same stem as the report it belongs to, so a run's
      # evidence sits together and one `ls` shows both.
      def run_log_path(run_id)
        base = @options[:report] ? @options[:report].sub(/\.json\z/, "") : nil
        base ||= File.join(fixtures.reports_dir, safe(@options[:name].to_s), run_id)
        "#{base}.log"
      end

      def safe(text) = text.gsub(/[^\w.-]+/, "_")
    end
  end
end
