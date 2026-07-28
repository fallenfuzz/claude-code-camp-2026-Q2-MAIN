require "digest"
require "open3"

module Boukensha
  # How and by whom a session was started, recorded once in `session_start`.
  #
  # Today a hand-driven exploration in the TUI and an automated test case are
  # indistinguishable on disk — same directory, same filename shape, same
  # events. The moment batch runs exist the session list is 95% robot, so the
  # single field that earns its place most here is `mode`: `interactive` for a
  # human at the REPL, `test` for a harness case. Everything else is additive
  # and optional, and a log written before this existed parses exactly as it
  # did, with `launch` absent — which a reader treats as "legacy / unknown
  # provenance", the same shape `has_provenance?` already uses.
  module Launch
    MODES = %w[interactive test].freeze

    module_function

    # The launch object for a human at the REPL. Deliberately thin: there is no
    # scenario, no run, no batch — saying so by omission is more honest than
    # filling those fields with nils.
    def interactive(profile: nil, session_name: nil, config: nil)
      build(mode: "interactive", runner: "human", profile: profile,
            session_name: session_name, config: config)
    end

    # The launch object for one test case. `extra` carries the scenario / plan /
    # run_id / case_index / state / map_memory / goal fields the harness knows
    # and this module has no business computing.
    def test(profile: nil, session_name: nil, config: nil, **extra)
      build(mode: "test", runner: "boukensha-test", profile: profile,
            session_name: session_name, config: config, **extra)
    end

    def build(mode:, runner:, profile: nil, session_name: nil, config: nil, **extra)
      raise ArgumentError, "launch mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode.to_s)

      launch = {
        mode: mode.to_s,
        runner: runner.to_s,
        profile: profile,
        boukensha_version: (VERSION if defined?(VERSION)),
        git_sha: git_sha,
        settings_digest: settings_digest(config)
      }.merge(extra).compact

      { session_name: session_name, launch: launch }.compact
    end

    # Best-effort. Outside a repo, or without git on PATH, this is nil rather
    # than an exception — provenance is worth having and never worth failing a
    # run over.
    def git_sha(dir = nil)
      out, status = Open3.capture2("git", "rev-parse", "--short", "HEAD",
                                   chdir: (dir || Dir.pwd).to_s, err: File::NULL)
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end

    # SHA-256 over the resolved `settings.yaml` plus the system prompt actually
    # in force. A batch of 20 is a measurement of ONE configuration; comparing
    # runs across a prompt edit is the single easiest way to draw a wrong
    # conclusion, and this is what lets a report refuse to aggregate two
    # different digests into one number.
    def settings_digest(config = nil)
      config ||= (Boukensha.config if Boukensha.respond_to?(:config))
      return nil unless config

      digest = Digest::SHA256.new
      [File.join(config.root_dir, "settings.yaml"),
       File.join(config.user_prompts_dir, "player", "system.md"),
       File.join(Config::PROMPTS_DIR, "system.md")].each do |path|
        digest << path.to_s
        digest << (File.file?(path) ? File.read(path) : "")
      end
      "sha256:#{digest.hexdigest}"
    rescue StandardError
      nil
    end
  end
end
