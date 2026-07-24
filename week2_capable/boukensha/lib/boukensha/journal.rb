require "json"
require "fileutils"
require "securerandom"
require "time"

module Boukensha
  # An append-only change log — the time-series sibling of the snapshot that
  # lives in knowledge.sqlite3. Where the store answers "what is true now"
  # (polled), the journal answers "what happened, in what order" (streamed),
  # and it does so in this project's native idiom for that: a daily-rotated
  # jsonl file in `.boukensha/`, exactly like `telnet/`, `manager/` and
  # `sessions/`, read by a Parser/Follower/Store trio over SSE with a `seq`
  # cursor (see change_capture.md).
  #
  # The heart is `upsert`: callers hand it the CURRENT reading every time they
  # read it and never track previous state themselves; the journal is the single
  # owner of "did this change?" and appends a line ONLY on a transition. That is
  # Change Data Capture in the honest sense — emit on change, swallow the no-ops
  # — and it is what keeps the log graphable instead of drowned in hp jitter.
  #
  # `event` is the discrete-event escape hatch for things that are ops, not
  # keyed-value transitions (an item acquired, a level milestone, a death).
  #
  # This class is world-agnostic infrastructure: it knows nothing about players,
  # rooms, or MUDs. The player streams are merely its first client.
  class Journal
    DEFAULT_JOURNAL_DIR = "journal".freeze

    attr_reader :session_id, :dir

    def initialize(session_id: nil, dir: nil, warn_to: $stderr, clock: Time)
      @session_id = session_id || generate_session_id
      @dir        = (dir || default_dir).to_s
      @warn_to    = warn_to
      @clock      = clock
      @mu         = Mutex.new
      @last       = {}   # [stream, key] => last value appended for that pair
      @seq        = nil
      @date       = nil

      FileUtils.mkdir_p(@dir)
    end

    # The upsert. Compares `value` to the last value seen for [stream, key] this
    # process; appends a change line ONLY if it differs. Returns whether it
    # wrote. A nil value is "no reading this time", never a transition — so a
    # poll that returns nothing can flow straight through without clearing state.
    #
    #   upsert(stream: "stat", key: "level", value: 5)
    #     → {"kind":"change","stream":"stat","key":"level","from":4,"to":5, ...}
    #       (nothing written if it was already 5, or if value is nil)
    def upsert(stream:, key:, value:, **meta)
      return false if value.nil?

      pair = [ stream.to_s, key.to_s ]
      prev = @last[pair]
      return false if prev == value

      !!guard do
        write(meta.merge(kind: "change", stream: stream.to_s, key: key.to_s, from: prev, to: value))
        @last[pair] = value
        true
      end
    end

    # A discrete event — an op that is not a keyed-value transition. Always
    # appended (there is no de-duplication: two "acquire a torch" ops are two
    # real events). Returns whether it wrote.
    #
    #   event(stream: "item", op: "acquire", descr: "a long sword", keyword: "sword", qty: 1)
    def event(stream:, op:, **fields)
      !!guard do
        write(fields.merge(kind: "event", stream: stream.to_s, op: op.to_s))
        true
      end
    end

    # Seed the change-detection cache WITHOUT writing anything. Called on open
    # with the store's current belief so that the first reading of every key
    # after a restart does not masquerade as a change — only true cross-session
    # deltas log. `values` is { key => value }; nils are ignored.
    def seed(stream:, values:)
      values.each do |key, value|
        next if value.nil?

        @last[[ stream.to_s, key.to_s ]] = value
      end
      nil
    end

    # Seed the cache AND write one snapshot line carrying the full starting
    # state, so every graph has a clean anchor point per session. This is `seed`
    # plus a durable record of the baseline the deltas are measured against.
    def snapshot(stream:, values:, **meta)
      values = values.compact
      seed(stream: stream, values: values)
      return false if values.empty?

      !!guard do
        write(meta.merge(kind: "snapshot", stream: stream.to_s, values: stringify_keys(values)))
        true
      end
    end

    def close
      @mu.synchronize { @io&.close }
    end

    private

    def default_dir
      File.join(Boukensha.config.profile_dir, DEFAULT_JOURNAL_DIR)
    end

    # Stamp seq/session_id/at/mono_ms and append one jsonl line under the mutex.
    # The reserved keys win over anything a caller passed, so no call site can
    # clobber the cursor or the timestamps.
    def write(event)
      @mu.synchronize do
        now = @clock.now
        rotate_if_needed(now)
        @seq += 1
        record = event.merge(
          seq:        @seq,
          session_id: @session_id,
          at:         now.iso8601(3),
          mono_ms:    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
        )
        @io.puts JSON.generate(record)
        @io.flush
      end
    end

    # Daily rotation, byte-for-byte the ManagerLog rule: the agent may restart
    # mid-day, so `seq` resumes at the line count already on disk (not zero) and
    # a new process never reissues a `seq` another line already used. Cursors
    # stay monotonic within a day regardless of how many processes wrote to it.
    def rotate_if_needed(time)
      date = time.strftime("%Y%m%d")
      return if @date == date

      @io&.close
      @date = date
      path  = File.join(@dir, "#{date}.jsonl")
      @seq  = File.exist?(path) ? File.foreach(path).count : 0
      @io   = File.open(path, "a")
    end

    def generate_session_id
      "#{@clock.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end

    # Telemetry never breaks the game. A broken journal — a full disk, a bad
    # permission, a raise from anywhere below — degrades to "no progression
    # captured" and never kills the turn that was trying to record it.
    def guard
      yield
    rescue StandardError => e
      @warn_to&.puts "[journal] #{e.class}: #{e.message}"
      nil
    end
  end
end
