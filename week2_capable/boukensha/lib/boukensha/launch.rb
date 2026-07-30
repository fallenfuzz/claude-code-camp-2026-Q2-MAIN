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

    # SHA-256 over the RESOLVED settings plus the system prompt actually in
    # force. A batch of 20 is a measurement of ONE configuration; comparing runs
    # across a prompt edit is the single easiest way to draw a wrong conclusion,
    # and this is what lets a report refuse to aggregate two different digests
    # into one number.
    #
    # It hashes the parse rather than the file's bytes, and that is the whole of
    # settings_sweep.md §4. A per-run override is applied in memory and does not
    # change the file, so a byte hash would give every arm of a sweep an
    # identical digest — the field that exists to stop two configurations being
    # compared as one would be actively asserting that six of them were the same
    # one. Hashing the parse is also strictly more honest in the ordinary case: a
    # comment edit or a reflow used to change the digest and changed nothing
    # about the run.
    #
    # `overrides:` digests what WOULD be in force with those overrides applied,
    # which is how the harness's parent process stamps a case it is not itself
    # running under.
    #
    # One-time discontinuity, recorded here and in Report's schema note: a
    # canonical serialisation of a parsed YAML document does not hash to the same
    # value as the document's bytes, so every digest changed on the day this
    # landed even though no configuration did. Reports written either side of it
    # cannot be compared on digest equality. Dropping the prompt paths from the
    # hash (below) is part of the same discontinuity and was found by the same
    # tests: it means a run on one machine is now comparable with a run on
    # another, which it never was.
    def settings_digest(config = nil, overrides: nil)
      config ||= (Boukensha.config if Boukensha.respond_to?(:config))
      return nil unless config

      digest = Digest::SHA256.new
      digest << "settings:"
      digest << canonical(config.settings_with(overrides))
      # Each prompt slot is labelled by its ROLE, not by where it lives. The
      # absolute path used to go into the hash, which made the same configuration
      # in two checkouts digest differently and quietly defeated comparing a run
      # on one machine against a run on another. What has to be distinguished is
      # the user's override slot from the bundled default, and the labels do that.
      { "prompt:user/player/system" => File.join(config.user_prompts_dir, "player", "system.md"),
        "prompt:default/system"     => File.join(Config::PROMPTS_DIR, "system.md") }.each do |slot, path|
        digest << slot
        digest << (File.file?(path) ? File.read(path) : "")
      end
      "sha256:#{digest.hexdigest}"
    rescue StandardError
      nil
    end

    # A deterministic rendering of a parsed YAML document: mapping keys sorted,
    # scalars written with `inspect` so the string "1" and the integer 1 do not
    # collide into one digest.
    def canonical(value)
      case value
      when Hash
        pairs = value.map { |k, v| [k.to_s, v] }.sort_by(&:first)
        "{#{pairs.map { |k, v| "#{k}=#{canonical(v)}" }.join(',')}}"
      when Array then "[#{value.map { |v| canonical(v) }.join(',')}]"
      else value.inspect
      end
    end
  end
end
