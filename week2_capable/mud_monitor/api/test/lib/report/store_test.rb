require "test_helper"
require "tmpdir"

module Report
  class StoreTest < ActiveSupport::TestCase
    setup do
      @dir = Pathname.new(Dir.mktmpdir("reports"))
      write("find_bakery", "20260728T143000Z-a1b2c3d4", cases: 20)
      write("banking", "20260728T090000Z-00000000", cases: 5)
    end

    teardown { FileUtils.remove_entry(@dir) }

    # Run ids are `%Y%m%dT%H%M%SZ`-prefixed, so lexical sort == chronological,
    # exactly as SessionLog::Store already relies on.
    test "lists newest first across nested run directories" do
      ids = store.paths.map { |path| path.basename(".json").to_s }

      assert_equal %w[20260728T143000Z-a1b2c3d4 20260728T090000Z-00000000], ids
    end

    # The runner's scratch dir sits under reports/ so a crashed batch leaves its
    # inputs next to the run they belonged to. It is not a report.
    test "the runner's work directory is not listed as reports" do
      work = @dir.join(".work", "20260728T143000Z-a1b2c3d4")
      FileUtils.mkdir_p(work)
      File.write(work.join("case-1.json"), '{"ok":true}')

      assert_equal 2, store.paths.length
    end

    test "an absent directory lists nothing rather than raising" do
      assert_empty Store.new(dir: @dir.join("nope")).paths
    end

    test "resolves an id to its path regardless of which run directory it sits in" do
      path = store.path_for("20260728T090000Z-00000000")

      assert_equal "banking", path.dirname.basename.to_s
    end

    # An id arrives from a URL, and this is the first thing anyone tries.
    test "a traversing id is not found rather than escaping the directory" do
      assert_raises(Store::NotFound) { store.path_for("../../etc/passwd") }
      assert_raises(Store::NotFound) { store.path_for("/etc/passwd") }
    end

    test "an unknown id raises NotFound" do
      assert_raises(Store::NotFound) { store.path_for("nope") }
    end

    # A run still writing its report must not take the whole index down.
    test "a half-written report loads as nil rather than raising" do
      path = @dir.join("find_bakery", "20260728T160000Z-cccccccc.json")
      File.write(path, '{"run_id": "trunc')

      assert_nil store.load(path)
    end

    test "loads a complete report" do
      doc = store.load(store.path_for("20260728T143000Z-a1b2c3d4"))

      assert_equal "find_bakery", doc["name"]
      assert_equal 20, doc.dig("summary", "cases")
    end

    private

    def store = Store.new(dir: @dir)

    def write(name, run_id, cases:)
      dir = @dir.join(name)
      FileUtils.mkdir_p(dir)
      File.write(dir.join("#{run_id}.json"), JSON.generate(
        schema: 1, run_id: run_id, kind: "scenario", name: name,
        started_at: "2026-07-28T14:30:00.000Z", ended_at: "2026-07-28T14:52:11.000Z",
        environment: { profile: "Derrano", provider: "anthropic", model: "claude-haiku-4-5",
                       settings_digest: "sha256:9f21" },
        summary: { cases: cases, passed: cases - 1, failed: 1, errored: 0,
                   pass_rate: (cases - 1).fdiv(cases), cost_usd: { agent: 0.31, judge: 0.08, total: 0.39 },
                   median: {}, p90: {}, failure_modes: {} },
        cases: [{ index: 1, scenario: name, session_id: "20260728T143241Z-fef86633",
                  status: "pass", facts: { model_tool_calls: 6 } }]
      ))
    end
  end
end
