require_relative "extractors/word_piece"
require_relative "extractors/structural"
require_relative "extractors/model"

module Boukensha
  # Enrichers for the room survey. Today there is exactly one — `look_candidates`
  # (docs/plans/week_2/look_candidates_runtime.md) — assembled here so the survey
  # gets a plain lambda and never learns what an ONNX session is.
  module Extractors
    DEFAULT_DIR = "models/look_candidates".freeze

    # The seam the scripted survey injects into `RoomParser`:
    #
    #   ->(name:, description:, exit_targets:, exclude:) { [String] }
    #
    # `exclude` is the caller's own additions; the structural exclusions (exit
    # destination names, mob/object keywords) are folded in here so no caller has
    # to remember them. Returns [] when disabled or when no model is installed,
    # because `look_candidates` is advisory and must never break a survey.
    # `model_dir:` is honoured but undocumented — the tests point it at a temp
    # directory. There is no threshold/top_k setting on purpose: those are swept
    # at build time and written into the artifact's manifest, so they travel with
    # the weights they were measured against. A settings override would let a
    # rebuild silently decouple the number from its evidence.
    #
    # `logger:` — this is the only place that holds BOTH the model and the
    # knowledge of what it just did, so the `local_inference` event is written
    # here (work_attribution.md §2). Until it existed the classifier was
    # completely unmeasured: not its ~10ms, not its yield, and not whether the
    # weights were installed at all — so a room record could carry a
    # `look_candidates` field produced by a model that had silently degraded to
    # Null, with nothing in the session saying so.
    def self.look_candidates(config: Boukensha.config, logger: nil)
      settings = config.dig(:tools, :room_survey, :look_candidates) || {}
      # `extractor: none` is the documented A/B switch. It is not a degraded
      # model and must not be logged as one — nothing ran, so nothing is
      # reported.
      return ->(**) { [] } if settings["extractor"].to_s == "none"

      root  = config.root_dir
      dir   = expand(settings["model_dir"]) || File.join(root, DEFAULT_DIR)
      model = Model.load(dir)

      lambda do |name:, description:, exit_targets: {}, mobs: [], objects: [], exclude: Set.new|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        kept = model.call(name: name, description: description, exit_targets: exit_targets,
                          exclude: exclude | Structural.exclusions(exit_targets: exit_targets,
                                                                   mobs: mobs, objects: objects))
        # The pool is what the room was SCORED against, and "23 candidates
        # scored, 3 kept" is the number that argues for or against keeping this
        # model at all. Re-derived rather than plumbed out of #call: it is one
        # regex scan of a description we already hold, against ~10ms of
        # inference.
        report(logger, model, dir, root,
               kept: kept, pool: model.candidates(description).size,
               duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
        kept
      end
    end

    # `threshold`/`top_k` are logged PER CALL, from the artifact's manifest,
    # precisely so a room record stays explainable by the calibration that
    # produced it after a retrain has moved on.
    #
    # The ~110ms one-time graph load is deliberately absent: it belongs on the
    # session_start snapshot, and putting it on a per-room event would report it
    # once and mislead about the steady state every other time.
    def self.report(logger, model, dir, root, kept:, pool:, duration_ms:)
      return unless logger

      available = model.available?
      logger.local_inference(
        model: "look_candidates", backend: (available ? "onnx" : nil),
        artifact: relative(model.onnx_path || dir, root),
        duration_ms: duration_ms, pool: pool, kept: kept.size,
        threshold: (model.threshold if available), top_k: (model.top_k if available),
        available: available, reason: model.reason
      )
    rescue StandardError
      # Telemetry never breaks a survey. `look_candidates` is advisory; a
      # logger that raised must not be the reason a room went unrecorded.
      nil
    end
    private_class_method :report

    # Artifact paths are absolute at runtime and identical across every event.
    # The interesting part is which build under the profile is answering.
    def self.relative(path, root)
      p = path.to_s
      root = root.to_s
      p.start_with?("#{root}/") ? p.delete_prefix("#{root}/") : p
    end
    private_class_method :relative

    # settings.yaml paths may use ${VAR}, matching the mcp_servers `env:` block.
    def self.expand(path)
      path&.gsub(/\$\{(\w+)\}/) { ENV.fetch(::Regexp.last_match(1), "") }
    end
    private_class_method :expand
  end
end
