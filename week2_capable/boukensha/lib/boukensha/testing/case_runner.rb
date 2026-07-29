require "json"
require "fileutils"
require_relative "fixtures"
require_relative "state_loader"
require_relative "map_memory"
require_relative "run_log"

module Boukensha
  module Testing
    # The CHILD half of a run: one case, in its own process, start to finish.
    #
    # Resolve state → seed the MUD → prepare map memory → run the agent → write
    # a result file and exit. Nothing here talks back to the parent except
    # through that file, which is the point: a case that hangs, raises, or takes
    # the MUD connection down with it costs one case, not the remaining
    # nineteen.
    #
    # The result file exists rather than a stdout protocol because the agent
    # prints, the TUI prints, and the MCP servers print. A dedicated file cannot
    # be corrupted by any of them.
    class CaseRunner
      def self.run(payload)
        new(payload).run
      end

      def initialize(payload)
        @payload = payload.transform_keys(&:to_s)
      end

      def run
        result = { "ok" => true }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          BoukenshaLoader.apply_profile!(@payload.fetch("player_profile"))
          config = Boukensha.config

          map = prepare_map_memory(config)
          result["map_memory"] = map.as_json
          log("map", describe_map(map))

          unless @payload["skip_seed"]
            log("seed", "#{@payload['player_profile']} ← #{@payload['base_initial_state'] || 'inline state'}" \
                        "#{"  (log: #{@payload['seed_log']})" if @payload['seed_log']}")
            seed!(config)
            log("seeded", describe_seeded)
          end

          launch = Launch.test(
            profile: @payload["player_profile"],
            session_name: @payload["session_name"],
            config: config,
            scenario: @payload["scenario"],
            plan: @payload["plan"],
            run_id: @payload["run_id"],
            case_index: @payload["case_index"],
            batch_size: @payload["batch_size"],
            state: @payload["base_initial_state"],
            map_memory: @payload["map_memory"],
            goal: @payload["goal"]
          )

          limits = @payload["limits"] || {}
          log("agent", "starting (max_iterations #{limits['max_iterations'] || 'default'}, " \
                       "wall_timeout #{limits['wall_timeout_s'] || 'default'}s)")
          agent_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          BoukenshaLoader.run_case(goal: @payload.fetch("goal"), launch: launch,
                                   on_progress: method(:log_progress))
          log("done", format("agent turn finished in %.1fs — closing MUD session and memory",
                             Process.clock_gettime(Process::CLOCK_MONOTONIC) - agent_started))
          # The logger stamps the session id on every line it writes and names
          # the file after it, so the parent needs no id handed back — only
          # which file, and `Operation.session_id` is the one value in this
          # process that knows.
          result["session_id"] = Operation.session_id
          retain_map_memory!(result)
        rescue StandardError => e
          result["ok"]         = false
          result["error"]      = "#{e.class}: #{e.message}"
          result["error_kind"] = error_kind(e)
          result["backtrace"]  = e.backtrace&.first(8)
          result["session_id"] ||= Operation.session_id
          log("failed", "#{error_kind(e)}: #{e.message}")
          # A case that died halfway still built a map, and that map is usually
          # the evidence for WHY it died. Retained on the failure path for the
          # same reason it is retained on the success one.
          retain_map_memory!(result)
        end
        result["duration_ms"] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        write_result(result)
        run_log&.close
        result["ok"] ? 0 : 1
      end

      private

      # The child appends to the run log the parent opened, measuring elapsed
      # from the RUN's start so a case's timings sit on the same clock as
      # everything around it.
      def run_log
        return @run_log if defined?(@run_log)

        @run_log = if @payload["run_log"]
                     RunLog.new(path: @payload["run_log"], echo: $stdout,
                                started_at: @payload["run_started_at"])
                   end
      end

      def log(kind, message)
        run_log&.event(kind, message, index: @payload["case_index"], total: @payload["batch_size"])
      end

      # The longest single stretch is the agent running, and it is the one
      # stretch that can legitimately take a minute. A line per iteration turns
      # "hung" into "on iteration 3 of 15".
      def log_progress(iteration:, tool_calls:, cost_usd:)
        log("agent", "iteration #{iteration} · #{tool_calls} tool call#{'s' unless tool_calls == 1}" \
                     "#{format(' · $%.4f', cost_usd) if cost_usd&.positive?}")
      end

      def describe_map(map)
        json = map.as_json
        rooms = json[:rooms_at_start]
        [json[:mode],
         ("archived #{File.basename(json[:archived_to])}" if json[:archived_to]),
         ("#{rooms} room#{'s' unless rooms == 1} known#{' — starting cold' if rooms.to_i.zero?}" unless rooms.nil?)
        ].compact.join(" — ")
      end

      def describe_seeded
        state = @payload["state"] || {}
        [("level #{state['level']}" if state["level"]),
         ("#{state.dig('money', 'gold')} gold" if state.dig("money", "gold")),
         ("placed in room #{state['location']}" if state["location"])].compact.join(", ")
      end

      def prepare_map_memory(config)
        fixtures = Fixtures.new(dir: config.tests_dir, profiles_dir: File.join(config.root_dir, "profiles"))
        @map_memory = MapMemory.new(
          profile_dir:  config.profile_dir,
          profiles_dir: File.join(config.root_dir, "profiles"),
          maps_dir:     fixtures.maps_dir,
          sessions_dir: fixtures.session_maps_dir(@payload.fetch("player_profile"))
        )
        @map_memory.apply!(@payload.fetch("map_memory", "none"))
      end

      # The map this case ENDED with, filed under the session that built it.
      #
      # This runs here rather than at the start of the next case because that is
      # the ordering bug it exists to fix: an archive taken before a case begins
      # holds the PREVIOUS case's map under the timestamp at which THIS one
      # started, and nothing joins it to the run that produced it. By this line
      # both the finished map and `Operation.session_id` are in hand.
      #
      # Never fatal. A case whose agent did the work and whose map could not be
      # copied is a case that passed, and reporting it as an error would be a
      # confident mislabel of the harness's problem as the agent's.
      def retain_map_memory!(result)
        session_id = result["session_id"]
        return unless @map_memory && session_id

        path = @map_memory.retain!(session_id)
        return log("memory", "nothing to retain — the case wrote no knowledge database") unless path

        result["map_memory_retained"] = path
        pruned = @map_memory.prune_retained!
        log("memory", "retained #{File.basename(path)}" \
                      "#{" — pruned #{pruned.size} older (keeping #{MapMemory::RETAIN_LIMIT})" unless pruned.empty?}")
      rescue StandardError => e
        log("memory", "not retained: #{e.message}")
      end

      def seed!(config)
        StateLoader.new(
          state:   @payload.fetch("state", {}),
          profile: config.profile["player"],
          mud:     config.mcp_servers.dig("mud", :env) || {},
          # The seeder narrates every telnet exchange it makes. In a batch of
          # twenty that is thousands of lines of noise between the numbers you
          # ran the batch for, so it goes to a file next to the case's session.
          output:  seed_log
        ).apply!
      end

      # The seeder narrates every telnet exchange it makes — hundreds of lines
      # per case of MUD prose. Inlining that in the run log would bury the
      # milestones under exactly the noise the run log exists to cut through, so
      # it gets its own file and the run log prints that file's path instead.
      #
      # `--verbose` is the escape hatch for when seeding ITSELF is what is
      # broken, which is the one time the transcript is the thing you want.
      def seed_log
        path = @payload["seed_log"]
        return $stdout unless path

        FileUtils.mkdir_p(File.dirname(path))
        io = File.open(path, "a")
        io.sync = true
        @payload["verbose"] ? Tee.new(io, $stdout) : io
      end

      # `CharacterSeeder` writes through `@output.puts` and nothing else, so
      # this is the whole interface.
      class Tee
        def initialize(*targets) = @targets = targets
        def puts(*args) = @targets.each { |t| t.puts(*args) }
        def write(*args) = @targets.each { |t| t.write(*args) }
      end

      # Seeding failures and agent failures are different things and the report
      # says which. Everything else is "error" — an honest shrug beats a
      # confident mislabel.
      def error_kind(error)
        case error
        when StateLoader::Error then "seed_failed"
        when MapMemory::Error   then "map_memory_failed"
        when Fixtures::Error    then "fixture_error"
        else error.class.name.split("::").last
        end
      end

      def write_result(result)
        path = @payload["result_path"] or return
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(result))
      end
    end
  end
end
