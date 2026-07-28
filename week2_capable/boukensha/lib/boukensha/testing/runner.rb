require "json"
require "fileutils"
require "tmpdir"
require "rbconfig"

module Boukensha
  module Testing
    # The PARENT half of a run: N cases, serially, each in its own child
    # process, collected into one report.
    #
    # One process per case, for three reasons all learned from what is in this
    # codebase:
    #
    # 1. `Mud::Memory::Store` is opened once per process and torn down by
    #    `at_exit`; the MCP `mud` server is a spawned daemon holding one telnet
    #    login. Resetting both in-process is a pile of lifecycle code that
    #    exists only to save a fork.
    # 2. A case that raises, hangs, or takes the MUD connection down with it
    #    must cost ONE case. The parent enforces `wall_timeout_s` and records
    #    `error`/`timeout` as a RESULT, not as a crash.
    # 3. Serial is not a performance compromise, it is a correctness
    #    requirement: **one player profile is one telnet login**, and two cases
    #    logged in as `Derrano` at once is the "already in use / Reconnecting"
    #    path `CharacterSeeder` has to work around. Parallelism is available
    #    only across DISTINCT profiles, which a plan can already express by
    #    assigning `player_profile` per case — future work, not built here.
    class Runner
      DEFAULT_WALL_TIMEOUT_S = 600
      # After SIGTERM, how long a child gets to close its log and its telnet
      # session before SIGKILL. A killed child leaves a half-written session
      # file, which parses (the reader already tolerates a truncated last line)
      # but loses the turn_end.
      GRACE_S = 10

      Outcome = Struct.new(:index, :case, :result, :status, :error, :error_kind,
                           :session_path, :seed_log, keyword_init: true)

      def initialize(root_dir:, work_dir: nil, executable: nil, on_event: nil, run_log: nil, verbose: false)
        @verbose    = verbose
        @root_dir   = root_dir
        @work_dir   = work_dir || File.join(Dir.tmpdir, "boukensha-test-#{Process.pid}")
        @executable = executable || default_executable
        @on_event   = on_event || ->(_kind, _payload) {}
        @run_log    = run_log
      end

      # Runs every case in order and yields each Outcome as it completes, so a
      # long batch reports progress rather than going quiet for twenty minutes.
      def run(cases, run_id:, plan: nil)
        FileUtils.mkdir_p(@work_dir)
        cases.each_with_index.map do |kase, index|
          outcome = run_one(kase, index: index + 1, total: cases.size, run_id: run_id, plan: plan)
          @on_event.call(:case_finished, outcome)
          yield outcome if block_given?
          outcome
        end
      end

      def run_one(kase, index:, total:, run_id:, plan: nil)
        result_path = File.join(@work_dir, "case-#{index}.json")
        seed_log    = File.join(@work_dir, "case-#{index}-seed.log")
        payload     = payload_for(kase, index: index, total: total, run_id: run_id, plan: plan,
                                  result_path: result_path, seed_log: seed_log)

        @on_event.call(:case_started, { index: index, total: total, case: kase })
        log(index, total, "start", "#{kase.session_name} — #{kase.goal.to_s.inspect}")
        status, error = spawn_case(payload, timeout: timeout_for(kase))
        result = read_result(result_path)

        # A child that died before writing its result file tells us nothing
        # except that it died; the exit status is then the only evidence there
        # is, and it is reported as such rather than silently becoming a pass.
        if error.nil? && result.nil?
          error = "case produced no result file (child exited #{status.inspect})"
        end
        if error
          log(index, total, "exit", error)
        else
          log(index, total, "exit", "child exited cleanly — grading")
        end

        Outcome.new(
          index: index, case: kase, result: result,
          status: (error || result&.dig("ok") == false) ? "error" : "ran",
          error: error || result&.dig("error"),
          error_kind: error ? "timeout_or_crash" : result&.dig("error_kind"),
          seed_log: (seed_log if File.file?(seed_log))
        )
      end

      # What a `--dry-run` prints: the resolved payload for every case, with no
      # MUD seeded and no model called. Resolving a 20-case override chain
      # wrong otherwise costs 20 real seeds and 20 real model runs; this costs
      # nothing.
      def payloads(cases, run_id:, plan: nil)
        cases.each_with_index.map do |kase, i|
          payload_for(kase, index: i + 1, total: cases.size, run_id: run_id, plan: plan,
                      result_path: nil, seed_log: nil)
        end
      end

      private

      def payload_for(kase, index:, total:, run_id:, plan:, result_path:, seed_log:)
        {
          "scenario"           => kase.scenario,
          "plan"               => plan,
          "run_id"             => run_id,
          "case_index"         => index,
          "batch_size"         => total,
          "session_name"       => kase.session_name,
          "player_profile"     => kase.player_profile,
          "goal"               => kase.goal,
          "state"              => kase.state,
          "base_initial_state" => kase.base_initial_state,
          "map_memory"         => kase.map_memory,
          "limits"             => kase.limits,
          "result_path"        => result_path,
          "seed_log"           => seed_log,
          # The child appends its own milestones to the SAME file, and measures
          # elapsed from the run's start rather than its own — otherwise every
          # case restarts the clock and the one number you want is the one you
          # cannot see.
          "run_log"            => @run_log&.path,
          "run_started_at"     => @run_log&.started_at,
          "verbose"            => @verbose
        }.compact
      end

      def log(index, total, kind, message)
        @run_log&.event(kind, message, index: index, total: total)
      end

      def timeout_for(kase)
        value = kase.limits["wall_timeout_s"] || DEFAULT_WALL_TIMEOUT_S
        Integer(value)
      rescue ArgumentError, TypeError
        DEFAULT_WALL_TIMEOUT_S
      end

      # The payload travels as a FILE, not as an argv string. A resolved state
      # with a dozen items is well past the point where quoting it into a
      # command line is a good idea, and a file is also the artifact you want
      # when reproducing a case by hand.
      def spawn_case(payload, timeout:)
        payload_path = File.join(@work_dir, "case-#{payload['case_index']}-input.json")
        File.write(payload_path, JSON.generate(payload))

        env = { "BOUKENSHA_DIR" => @root_dir, "BOUKENSHA_PROFILE" => payload["player_profile"] }
        pid = Process.spawn(env, *@executable, "--test-case", payload_path)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          finished, status = Process.waitpid2(pid, Process::WNOHANG)
          return [status, nil] if finished
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.2
        end

        [nil, terminate(pid, timeout)]
      rescue Errno::ECHILD
        [nil, nil]
      end

      def terminate(pid, timeout)
        Process.kill("TERM", pid) rescue nil
        grace = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GRACE_S
        until Process.clock_gettime(Process::CLOCK_MONOTONIC) > grace
          finished, = Process.waitpid2(pid, Process::WNOHANG)
          break if finished

          sleep 0.2
        end
        Process.kill("KILL", pid) rescue nil
        Process.waitpid(pid) rescue nil
        "wall_timeout_s of #{timeout}s exceeded"
      end

      def read_result(path)
        return nil unless path && File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      # The same binary, re-invoked. Resolved through RbConfig rather than
      # trusting `boukensha` to be on PATH, so a child runs the checkout the
      # parent is running and not whichever version happens to be installed.
      def default_executable
        [RbConfig.ruby, File.expand_path("../../../bin/boukensha", __dir__)]
      end
    end
  end
end
