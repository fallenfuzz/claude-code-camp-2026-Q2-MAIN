require "json"

module ErrorLog
  Record = Data.define(:seq, :fields) do
    def [](key) = fields[key.to_s]
    def as_json(*) = fields.merge("seq" => seq)
  end

  class Parser
    MAX_LINE_BYTES = 256 * 1024
    MAX_BACKTRACE_FRAMES = 500

    def self.load(path)
      records = []
      offset = 0
      File.open(path, "rb") do |io|
        io.each_line do |line|
          offset += line.bytesize
          next unless line.end_with?("\n")

          fields = parse_line(line, offset)
          records << Record.new(seq: offset, fields: fields)
        end
      end
      records
    end

    def self.parse_line(line, offset)
      if line.bytesize > MAX_LINE_BYTES
        return malformed(offset, "line exceeds #{MAX_LINE_BYTES} bytes")
      end

      parsed = JSON.parse(line)
      raise JSON::ParserError, "record is not an object" unless parsed.is_a?(Hash)

      parsed["backtrace"] = Array(parsed["backtrace"]).first(MAX_BACKTRACE_FRAMES)
      parsed
    rescue JSON::ParserError => e
      malformed(offset, e.message)
    end

    def self.malformed(offset, message)
      {
        "id" => "malformed_#{offset}",
        "severity" => "warning",
        "component" => "error_log",
        "boundary" => "parser",
        "exception_class" => "MalformedRecord",
        "message" => message,
        "backtrace" => [],
        "malformed" => true
      }
    end
  end
end
