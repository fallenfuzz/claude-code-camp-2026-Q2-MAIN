require "test_helper"

module Journal
  class FollowerTest < ActiveSupport::TestCase
    test "records_after returns only records past the cursor" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "20260724.jsonl")
        File.write(path, <<~JSONL)
          {"kind":"change","stream":"stat","key":"level","to":1,"seq":1}
          {"kind":"change","stream":"stat","key":"level","to":2,"seq":2}
        JSONL
        follower = Follower.new(path)
        assert_equal [ 2 ], follower.records_after(1).map(&:seq)
      end
    end

    test "picks up records appended after the first read, keeping the cursor monotonic" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "20260724.jsonl")
        File.write(path, %({"kind":"change","stream":"stat","key":"level","to":1,"seq":1}\n))
        follower = Follower.new(path)
        assert_equal [ 1 ], follower.records_after(0).map(&:seq)

        # A daemon restart mid-day resumes seq from the line count, so a new
        # record never reuses seq 1. The follower must serve it after cursor 1.
        sleep 0.01
        File.write(path, %({"kind":"change","stream":"stat","key":"level","to":2,"seq":2}\n), mode: "a")
        assert_equal [ 2 ], follower.records_after(1).map(&:seq)
      end
    end
  end

  class StoreTest < ActiveSupport::TestCase
    test "path_for admits only an 8-digit date and rejects traversal" do
      Dir.mktmpdir do |dir|
        store = Store.new(dir: dir)
        assert_nil store.path_for("../../etc/passwd")
        assert_nil store.path_for("2026072")     # too short
        assert_nil store.path_for("20260724")    # well-formed but no file yet
        File.write(File.join(dir, "20260724.jsonl"), "")
        refute_nil store.path_for("20260724")
      end
    end

    test "path_for! raises NotFound when there is nothing to tail" do
      Dir.mktmpdir do |dir|
        assert_raises(Store::NotFound) { Store.new(dir: dir).path_for!("20260724") }
      end
    end
  end
end
