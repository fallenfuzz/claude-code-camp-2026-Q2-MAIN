require "fileutils"

module Boukensha
  module Testing
    # What the HARNESS is doing right now (batch_sesssion_testing.md §5.4).
    #
    # The session `.jsonl` records what the AGENT did. It says nothing about
    # fixture resolution, seeding, or map preparation — and it does not exist
    # yet during the part of a case that most often goes wrong. A single case
    # deletes and recreates a character over telnet, archives a SQLite
    # database, spawns an MCP daemon, logs into the MUD, and runs an agent for
    # a dozen iterations; any one of those can be the slow one, and silence
    # makes them indistinguishable from a hang.
    #
    # So this is a different kind of artifact from everything else here: the
    # report is for reading afterwards, the run log is for watching NOW. Every
    # line is flushed and simultaneously echoed to stdout.
    #
    # Both halves of §5.2 write to one file. The parent opens it; each child is
    # handed its path and appends. `O_APPEND` plus one `write` per whole line
    # is what makes that safe without a lock — two processes can interleave
    # lines but never splice one.
    class RunLog
      # Elapsed since the run started, not wall-clock. The question this log
      # answers is "what is taking so long", and elapsed says *the agent, not
      # the seeder* with no arithmetic from the reader.
      COLUMN = 8

      attr_reader :path

      # started_at is passed through to a child so its elapsed times are
      # measured from the RUN's start, not the child's — otherwise every case
      # restarts the clock and the one number you want is the one you cannot see.
      def self.open(path:, echo: $stdout, started_at: nil, &block)
        log = new(path: path, echo: echo, started_at: started_at)
        return log unless block

        begin
          block.call(log)
        ensure
          log.close
        end
      end

      def initialize(path:, echo: $stdout, started_at: nil)
        @path       = path&.to_s
        @echo       = echo
        @started_at = started_at || Time.now.to_f
        if @path
          FileUtils.mkdir_p(File.dirname(@path))
          @io = File.open(@path, "a")
          @io.sync = true
        end
        # A child's stdout is a pipe, not a tty, so it is block-buffered by
        # default — its milestones would sit in that buffer and be lost when the
        # parent SIGKILLs it at the wall timeout. That is exactly the moment the
        # log has to survive, because the last milestone is what says what it
        # died doing.
        @echo.sync = true if @echo.respond_to?(:sync=)
      end

      # started_at as a float, for handing to a child process.
      def started_at = @started_at

      # One state change. `kind` is the verb column (`seed`, `agent`, `done`);
      # `index`/`total` scope the line to a case.
      def event(kind, message, index: nil, total: nil)
        write("#{elapsed}  #{scope(index, total)}#{kind.to_s.ljust(COLUMN)} #{message}")
      end

      # A line with no verb — run-level framing.
      def say(message)
        write("#{elapsed}  #{message}")
      end

      def close
        @io&.close
        @io = nil
      end

      private

      def write(line)
        # One `write` per whole line, newline included: two appenders may
        # interleave lines but must never produce a spliced one.
        @io&.write("#{line}\n")
        @echo&.write("#{line}\n")
      rescue IOError, Errno::EPIPE
        # A closed stdout (piped to `head`, say) costs the echo, never the run.
        @echo = nil
      end

      def elapsed
        seconds = Time.now.to_f - @started_at
        format("%02d:%04.1f", (seconds / 60).floor, seconds % 60)
      end

      def scope(index, total)
        return "" unless index

        total ? "[#{index}/#{total}] " : "[#{index}] "
      end
    end
  end
end
