require "test_helper"

module Journal
  class SeriesTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/journal")

    def folded
      @folded ||= Series.fold(Parser.load(FIXTURES.join("20260724.jsonl")).records)
    end

    test "a stat series is seeded by the snapshot then extended by each change" do
      # snapshot gives level=1; the change at seq 4 gives level=2
      levels = folded[:stats]["level"]
      assert_equal [ 1, 2 ], levels.map { |p| p[:value] }
      assert_equal [ 1, 4 ], levels.map { |p| p[:seq] }
    end

    test "exp and gold fold into their own series" do
      assert_equal [ 1, 500 ], folded[:stats]["exp"].map { |p| p[:value] }
      assert_equal [ 0, 250 ], folded[:stats]["gold"].map { |p| p[:value] }
    end

    test "skills fold per name from their change lines" do
      assert_equal [ 15 ], folded[:skills]["backstab"].map { |p| p[:value] }
    end

    test "milestones are collected in order with their fields" do
      ops = folded[:milestones].map { |m| m[:op] }
      assert_equal %w[level_up death], ops
      assert_equal 2, folded[:milestones].last[:level]
    end

    test "the item ledger preserves acquire/drop order and keywords" do
      items = folded[:items]
      assert_equal %w[acquire drop], items.map { |i| i[:op] }
      assert_equal "sword", items.first[:keyword]
      assert_equal "a long sword", items.first[:descr]
    end

    test "an empty log folds to empty series, never an error" do
      folded = Series.fold([])
      assert_empty folded[:stats]
      assert_empty folded[:milestones]
      assert_empty folded[:items]
    end
  end
end
