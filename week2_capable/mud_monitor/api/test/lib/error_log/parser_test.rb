require "test_helper"

class ErrorLogParserTest < ActiveSupport::TestCase
  test "parses records with byte-offset cursors and backtraces" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "error.log")
      first = { id: "err_1", exception_class: "ArgumentError", message: "bad",
                component: "mud_hooks", boundary: "guard", severity: "error",
                backtrace: ["one", "two"] }.to_json << "\n"
      second = { id: "err_2", exception_class: "RuntimeError", message: "worse",
                 component: "agent", boundary: "tool", severity: "error",
                 backtrace: ["three"] }.to_json << "\n"
      File.write(path, first + second)

      records = ErrorLog::Parser.load(path)
      assert_equal [first.bytesize, first.bytesize + second.bytesize], records.map(&:seq)
      assert_equal %w[one two], records.first["backtrace"]
      assert_equal "err_2", records.last["id"]
    end
  end

  test "ignores incomplete final line and exposes malformed complete lines" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "error.log")
      File.binwrite(path, "{bad}\n{\"id\":\"partial\"")

      records = ErrorLog::Parser.load(path)
      assert_equal 1, records.length
      assert_equal true, records.first["malformed"]
      assert_equal "MalformedRecord", records.first["exception_class"]
    end
  end
end
