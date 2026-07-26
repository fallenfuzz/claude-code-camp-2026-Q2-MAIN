require_relative "helper"

class TestErrorLog < Minitest::Test
  def exception(message = "missing keyword: :kind")
    raise ArgumentError, message
  rescue ArgumentError => e
    e
  end

  def test_records_exception_and_backtrace_as_one_json_line
    Dir.mktmpdir do |dir|
      path = File.join(dir, "error.log")
      id = Boukensha::ErrorLog.new(path: path, profile_id: "Dummy").record(
        exception, component: "mud_hooks", boundary: "before_tools"
      )
      row = JSON.parse(File.read(path))

      assert_match(/\Aerr_[0-9a-f]+\z/, id)
      assert_equal id, row["id"]
      assert_equal "ArgumentError", row["exception_class"]
      assert_equal "missing keyword: :kind", row["message"]
      assert row["backtrace"].any? { |frame| frame.include?("test_error_log.rb") }
      assert_equal "Dummy", row["profile_id"]
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_concurrent_records_remain_complete_lines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "error.log")
      log = Boukensha::ErrorLog.new(path: path)
      threads = 8.times.map do |i|
        Thread.new { log.record(exception("failure #{i}"), component: "test", boundary: "thread") }
      end
      threads.each(&:join)

      rows = File.readlines(path).map { |line| JSON.parse(line) }
      assert_equal 8, rows.length
      assert_equal 8, rows.map { |row| row["id"] }.uniq.length
    end
  end

  def test_truncates_message_and_backtrace_explicitly
    Dir.mktmpdir do |dir|
      error = exception("abcdefgh")
      error.set_backtrace(%w[one two three])
      path = File.join(dir, "error.log")
      Boukensha::ErrorLog.new(path: path, message_max_bytes: 4,
                             backtrace_max_frames: 2).record(
        error, component: "test", boundary: "limits"
      )
      row = JSON.parse(File.read(path))

      assert_equal "abcd", row["message"]
      assert_equal true, row["message_truncated"]
      assert_equal %w[one two], row["backtrace"]
      assert_equal true, row["backtrace_truncated"]
      assert_equal 3, row["backtrace_original_frames"]
    end
  end

  def test_write_failure_warns_once_and_never_raises
    Dir.mktmpdir do |dir|
      warnings = StringIO.new
      log = Boukensha::ErrorLog.new(path: dir, warning_io: warnings)

      assert_nil log.record(exception, component: "test", boundary: "failure")
      assert_nil log.record(exception, component: "test", boundary: "failure")
      assert_equal 1, warnings.string.lines.length
    end
  end

  def test_includes_ambient_operation_correlation
    Dir.mktmpdir do |dir|
      path = File.join(dir, "error.log")
      Boukensha::Operation.session_id = "session-1"
      Boukensha::Operation.open("async_poll") do |frame|
        frame.trace_id = "trace-1"
        frame.span_id = "span-1"
        Boukensha::ErrorLog.new(path: path).record(
          exception, component: "mud_hooks", boundary: "guard"
        )
      end
      row = JSON.parse(File.read(path))

      assert_equal "session-1", row["session_id"]
      assert_equal "async_poll", row["operation"]
      assert_equal "trace-1", row["trace_id"]
      assert_equal "span-1", row["span_id"]
    ensure
      Boukensha::Operation.session_id = nil
      Boukensha::Operation.reset!
    end
  end
end
