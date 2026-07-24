require "test_helper"

module Journal
  class ParserTest < ActiveSupport::TestCase
    FIXTURES = Rails.root.join("test/fixtures/journal")

    test "parses every record, preserving the seq stored in the file" do
      parser = Parser.load(FIXTURES.join("20260724.jsonl"))

      assert_equal (1..9).to_a, parser.records.map(&:seq)
    end

    test "reads a change record's from/to transition" do
      parser = Parser.load(FIXTURES.join("20260724.jsonl"))
      exp    = parser.records.find { |r| r.seq == 2 }

      assert_equal "change", exp.kind
      assert_equal "stat", exp.stream
      assert_equal "exp", exp.key
      assert_equal 1, exp.from
      assert_equal 500, exp.to
    end

    test "keeps an event's open-set fields verbatim outside the common columns" do
      parser = Parser.load(FIXTURES.join("20260724.jsonl"))
      item   = parser.records.find { |r| r.seq == 3 }

      assert_equal "event", item.kind
      assert_equal "acquire", item.op
      assert_equal "sword", item.fields["keyword"]
      assert_equal "a long sword", item.fields["descr"]
      assert_equal "get_item", item.fields["tool"]
    end

    test "reads a snapshot's values payload" do
      parser = Parser.load(FIXTURES.join("20260724.jsonl"))
      snap   = parser.records.find { |r| r.seq == 1 }

      assert_equal "snapshot", snap.kind
      assert_equal({ "level" => 1, "gold" => 0, "exp" => 1 }, snap.values)
    end

    test "skips a truncated final line still being written" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "20260724.jsonl")
        File.write(path, <<~JSONL)
          {"kind":"change","stream":"stat","key":"level","to":2,"seq":1}
          {"kind":"change","stream":"stat","key":"gold","to
        JSONL
        parser = Parser.load(path)
        assert_equal [ 1 ], parser.records.map(&:seq)
      end
    end
  end
end
