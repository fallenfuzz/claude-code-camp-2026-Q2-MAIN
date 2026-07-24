require_relative "helper"
require "json"
require "stringio"

# change_capture.md P0: the writer that captures only the changes. An unchanged
# upsert writes nothing; a changed one writes from/to; a restart with a seeded
# cache logs only true deltas.
class TestJournal < Minitest::Test
  def test_upsert_writes_a_change_line_with_from_and_to
    lines = capture do |j|
      assert j.upsert(stream: "stat", key: "level", value: 5)
    end

    change = lines.find { |l| l["kind"] == "change" }
    refute_nil change
    assert_equal "stat", change["stream"]
    assert_equal "level", change["key"]
    assert_nil change["from"]         # nothing seen before this process
    assert_equal 5, change["to"]
  end

  def test_an_unchanged_upsert_writes_nothing
    lines = capture do |j|
      assert j.upsert(stream: "stat", key: "level", value: 5)
      refute j.upsert(stream: "stat", key: "level", value: 5)   # no-op, swallowed
      assert j.upsert(stream: "stat", key: "level", value: 6)   # real transition
    end

    changes = lines.select { |l| l["kind"] == "change" && l["key"] == "level" }
    assert_equal [ [ nil, 5 ], [ 5, 6 ] ], changes.map { |c| [ c["from"], c["to"] ] }
  end

  def test_a_nil_reading_is_not_a_transition
    lines = capture do |j|
      refute j.upsert(stream: "stat", key: "gold", value: nil)
    end
    assert_empty lines.select { |l| l["kind"] == "change" }
  end

  def test_change_detection_is_scoped_per_stream_and_key
    lines = capture do |j|
      j.upsert(stream: "stat", key: "level", value: 5)
      j.upsert(stream: "skill", key: "level", value: 5)   # same key, different stream ⇒ its own transition
    end
    assert_equal 2, lines.count { |l| l["kind"] == "change" }
  end

  def test_event_always_appends
    lines = capture do |j|
      assert j.event(stream: "item", op: "acquire", descr: "a long sword", keyword: "sword", qty: 1)
      assert j.event(stream: "item", op: "acquire", descr: "a long sword", keyword: "sword", qty: 1)
    end
    events = lines.select { |l| l["kind"] == "event" }
    assert_equal 2, events.size
    assert_equal "acquire", events.first["op"]
    assert_equal "a long sword", events.first["descr"]
  end

  def test_seed_suppresses_the_first_reading_that_matches_the_baseline
    lines = capture do |j|
      j.seed(stream: "stat", values: { "level" => 5, "gold" => 100 })
      refute j.upsert(stream: "stat", key: "level", value: 5)   # already known ⇒ not a cross-session delta
      assert j.upsert(stream: "stat", key: "level", value: 6)   # a true delta
    end
    changes = lines.select { |l| l["kind"] == "change" }
    assert_equal 1, changes.size
    assert_equal [ 5, 6 ], [ changes.first["from"], changes.first["to"] ]
  end

  def test_snapshot_writes_an_anchor_line_and_seeds_the_cache
    lines = capture do |j|
      j.snapshot(stream: "stat", values: { "level" => 5, "gold" => 100 })
      refute j.upsert(stream: "stat", key: "level", value: 5)   # seeded by the snapshot
    end
    snap = lines.find { |l| l["kind"] == "snapshot" }
    refute_nil snap
    assert_equal({ "level" => 5, "gold" => 100 }, snap["values"])
    assert_empty lines.select { |l| l["kind"] == "change" }
  end

  def test_every_line_carries_seq_session_id_and_millisecond_at
    lines = capture do |j|
      j.upsert(stream: "stat", key: "level", value: 1)
      j.upsert(stream: "stat", key: "level", value: 2)
    end
    assert_equal [ 1, 2 ], lines.map { |l| l["seq"] }          # monotonic, 1-based
    assert_equal [ "test" ], lines.map { |l| l["session_id"] }.uniq
    lines.each { |l| assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/, l["at"]) }
    lines.each { |l| assert_kind_of Integer, l["mono_ms"] }
  end

  def test_seq_resumes_from_the_files_line_count_across_a_restart
    Dir.mktmpdir do |dir|
      date = Time.now.strftime("%Y%m%d")
      path = File.join(dir, "#{date}.jsonl")

      j1 = Boukensha::Journal.new(session_id: "s1", dir: dir)
      j1.upsert(stream: "stat", key: "level", value: 1)
      j1.upsert(stream: "stat", key: "level", value: 2)
      j1.close

      # A fresh process mid-day must not reissue seq 1/2.
      j2 = Boukensha::Journal.new(session_id: "s2", dir: dir)
      j2.upsert(stream: "stat", key: "level", value: 3)
      j2.close

      seqs = File.readlines(path).map { |l| JSON.parse(l)["seq"] }
      assert_equal [ 1, 2, 3 ], seqs
    end
  end

  def test_a_write_failure_degrades_instead_of_raising
    warnings = StringIO.new
    Dir.mktmpdir do |dir|
      j = Boukensha::Journal.new(session_id: "test", dir: dir, warn_to: warnings)
      # Pin the rotation state so the write path keeps our dead handle instead
      # of rotating in a fresh, working one.
      j.instance_variable_set(:@date, Time.now.strftime("%Y%m%d"))
      j.instance_variable_set(:@seq, 0)
      j.instance_variable_set(:@io, BrokenIO.new)   # simulate a dead file handle
      refute j.upsert(stream: "stat", key: "level", value: 1)   # swallowed, no raise
      j.close rescue nil
    end
    assert_match(/\[journal\]/, warnings.string)
  end

  private

  class BrokenIO
    def puts(*)  = raise IOError, "disk gone"
    def flush    = nil
    def close    = nil
  end

  def capture
    Dir.mktmpdir do |dir|
      j = Boukensha::Journal.new(session_id: "test", dir: dir)
      begin
        yield j
      ensure
        j.close
      end
      date = Time.now.strftime("%Y%m%d")
      path = File.join(dir, "#{date}.jsonl")
      return File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
    end
  end
end
