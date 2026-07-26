require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "operation"

module Boukensha
  # Best-effort, profile-scoped exception diagnostics. This deliberately does
  # not depend on Logger or OpenTelemetry: either may be the thing that failed.
  class ErrorLog
    DEFAULT_FILENAME = "error.log".freeze
    DEFAULT_MESSAGE_BYTES = 16 * 1024
    DEFAULT_BACKTRACE_FRAMES = 200

    attr_reader :path

    def initialize(path: nil, profile_id: nil, warning_io: $stderr, clock: Time,
                   message_max_bytes: DEFAULT_MESSAGE_BYTES,
                   backtrace_max_frames: DEFAULT_BACKTRACE_FRAMES)
      @path = path || File.join(Boukensha.config.profile_dir, DEFAULT_FILENAME)
      @profile_id = profile_id || File.basename(File.dirname(@path))
      @warning_io = warning_io
      @clock = clock
      @message_max_bytes = message_max_bytes
      @backtrace_max_frames = backtrace_max_frames
      @warning_emitted = false
      @warning_lock = Mutex.new
    end

    # Returns the durable error id, or nil if even the diagnostic sink failed.
    def record(exception, component:, boundary:, severity: "error", context: nil)
      record = build_record(exception, component: component, boundary: boundary,
                            severity: severity, context: context)
      line = JSON.generate(record) << "\n"
      FileUtils.mkdir_p(File.dirname(@path))
      File.open(@path, File::WRONLY | File::CREAT | File::APPEND, 0o600) do |io|
        io.flock(File::LOCK_EX)
        io.write(line)
        io.flush
      ensure
        io&.flock(File::LOCK_UN)
      end
      File.chmod(0o600, @path)
      record[:id]
    rescue StandardError => logging_error
      warn_once(logging_error)
      nil
    end

    private

    def build_record(exception, component:, boundary:, severity:, context:)
      message, message_meta = truncate_message(redact(exception.message.to_s))
      frames = Array(exception.backtrace).map { |frame| redact(frame.to_s) }
      kept_frames = frames.first(@backtrace_max_frames)
      frame_meta = if frames.length > kept_frames.length
        { backtrace_truncated: true, backtrace_original_frames: frames.length }
      else
        {}
      end
      frame = Operation.current

      {
        id: "err_#{SecureRandom.hex(8)}",
        at: @clock.now.iso8601(3),
        mono_ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round,
        severity: severity.to_s,
        component: component.to_s,
        boundary: boundary.to_s,
        exception_class: exception.class.name,
        message: message,
        backtrace: kept_frames,
        profile_id: @profile_id,
        session_id: Operation.session_id,
        operation_id: frame&.id,
        operation: frame&.name,
        trace_id: frame&.trace_id,
        span_id: frame&.span_id,
        pid: Process.pid,
        thread_id: Thread.current.object_id,
        context: safe_context(context)
      }.compact.merge(message_meta).merge(frame_meta)
    end

    def truncate_message(message)
      return [message, {}] if message.bytesize <= @message_max_bytes

      kept = message.byteslice(0, @message_max_bytes).scrub
      [kept, { message_truncated: true, message_original_bytes: message.bytesize }]
    end

    # Only scalar identifiers explicitly supplied by a boundary are accepted.
    def safe_context(context)
      return nil unless context.is_a?(Hash)

      context.each_with_object({}) do |(key, value), out|
        next unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) ||
                    value == true || value == false

        out[key.to_s] = redact(value.to_s)
      end
    end

    def redact(text)
      secrets = ENV.each_with_object([]) do |(name, value), out|
        next unless name.match?(/(?:API_KEY|TOKEN|PASSWORD|SECRET)\z/i)
        next if value.to_s.length < 6

        out << value
      end
      secrets.reduce(text) { |value, secret| value.gsub(secret, "[REDACTED]") }
        .gsub(/\bBearer\s+\S+/i, "Bearer [REDACTED]")
        .gsub(/\bsk-[A-Za-z0-9_-]{12,}\b/, "[REDACTED]")
    end

    def warn_once(error)
      @warning_lock.synchronize do
        return if @warning_emitted

        @warning_emitted = true
        @warning_io&.puts("[error_log] #{error.class}: #{error.message}")
      end
    rescue StandardError
      nil
    end
  end
end
