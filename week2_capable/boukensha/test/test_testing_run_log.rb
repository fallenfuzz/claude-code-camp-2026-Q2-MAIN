require_relative "helper"
require "stringio"
require "boukensha/testing/run_log"

# The run log is for watching NOW, which makes two of its properties
# load-bearing in a way a report's are not: every line must be flushed as it is
# written, and a parent and a child appending concurrently must never splice.
class TestTestingRunLog < Minitest::Test
  RL = Boukensha::Testing::RunLog

  def setup = @dir = Dir.mktmpdir
  def teardown = FileUtils.remove_entry(@dir)

  def test_writes_the_same_line_to_the_file_and_the_echo
    echo = StringIO.new
    log  = RL.new(path: path, echo: echo)
    log.event("seed", "Derrano ← cleric", index: 1, total: 20)
    log.close

    assert_equal echo.string, File.read(path)
    assert_match(/\[1\/20\] seed\s+Derrano ← cleric/, echo.string)
  end

  # Elapsed, not wall-clock: the question this log answers is "what is taking so
  # long", and elapsed answers it with no arithmetic from the reader.
  def test_every_line_carries_elapsed_time_since_the_run_started
    log = RL.new(path: path, echo: StringIO.new, started_at: Time.now.to_f - 75.5)
    log.say "run    starting"
    log.close

    assert_match(/\A01:15\.\d/, File.read(path))
  end

  # A child measures from the RUN's start, not its own — otherwise every case
  # restarts the clock and the one number you want is the one you cannot see.
  def test_a_child_continues_the_parents_clock
    parent = RL.new(path: path, echo: StringIO.new)
    child  = RL.new(path: path, echo: StringIO.new, started_at: parent.started_at)

    assert_equal parent.started_at, child.started_at
  end

  # `--quiet` still writes the file; it only stops the echo, because the file is
  # the artifact and the echo is the convenience.
  def test_quiet_writes_the_file_and_echoes_nothing
    log = RL.new(path: path, echo: nil)
    log.event("seed", "Derrano")
    log.close

    assert_match(/seed/, File.read(path))
  end

  def test_a_log_with_no_path_still_echoes
    echo = StringIO.new
    RL.new(path: nil, echo: echo).event("seed", "Derrano")

    assert_match(/seed/, echo.string)
  end

  # Two processes append to one file. `O_APPEND` plus one write per whole line
  # is what makes that safe without a lock.
  def test_concurrent_appenders_produce_whole_lines_never_spliced
    threads = 4.times.map do |n|
      Thread.new do
        log = RL.new(path: path, echo: nil)
        50.times { |i| log.event("case#{n}", "message #{i} #{'x' * 200}") }
        log.close
      end
    end
    threads.each(&:join)

    lines = File.readlines(path)
    assert_equal 200, lines.length
    lines.each { |line| assert_match(/\A\d\d:\d\d\.\d  case\d\s+message \d+ x+\n\z/, line) }
  end

  # A child killed at the wall timeout must leave its last milestone on disk —
  # that line is precisely what says what it died doing.
  def test_lines_are_flushed_immediately_rather_than_buffered
    log = RL.new(path: path, echo: nil)
    log.event("agent", "iteration 3")

    assert_match(/iteration 3/, File.read(path), "unflushed lines are lost when a child is SIGKILLed")
  end

  # A closed stdout (piped to `head`) costs the echo, never the run.
  def test_a_broken_echo_does_not_take_the_run_down
    broken = Object.new
    def broken.write(*) = raise(Errno::EPIPE)
    def broken.sync=(_value)
      nil
    end

    log = RL.new(path: path, echo: broken)
    log.event("seed", "one")
    log.event("seed", "two")
    log.close

    assert_equal 2, File.readlines(path).length
  end

  private

  def path = File.join(@dir, "run.log")
end
