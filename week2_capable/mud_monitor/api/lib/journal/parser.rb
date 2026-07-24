require "json"

module Journal
  # Parses a boukensha `.boukensha/journal/<YYYYMMDD>.jsonl` file — the agent's
  # append-only progression log — into an ordered list of records. Like
  # ManagerLog::Parser (and for the same reason), `seq` is READ from the file
  # rather than assigned positionally: journal files are daily-rotated and the
  # agent may restart mid-day, so `seq` is already stable in each record and the
  # `after` cursor stays monotonic across process restarts.
  #
  # Records come in three kinds, discriminated by `kind`:
  #   - "change"   — a keyed-value transition: has `stream`, `key`, `from`, `to`.
  #   - "event"    — a discrete op: has `stream`, `op`, plus op-specific fields.
  #   - "snapshot" — a session_open anchor: has `stream` and a `values` hash.
  # The op/snapshot payload beyond the common columns is kept verbatim in
  # `fields`, because events carry an open set of keys (descr, keyword, qty,
  # level, tool, …) this reader deliberately does not enumerate.
  class Parser
    COMMON = %w[seq at mono_ms session_id kind stream key from to op values].freeze

    Record = Struct.new(:seq, :at, :mono_ms, :session_id, :kind, :stream,
                        :key, :from, :to, :op, :values, :fields, keyword_init: true)

    attr_reader :records

    def self.load(path)
      new(path).tap(&:parse!)
    end

    def initialize(path)
      @path    = path
      @records = []
    end

    def parse!
      File.foreach(@path) do |line|
        line = line.strip
        next if line.empty?

        event = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next # truncated final line of a file still being written
        end

        @records << Record.new(
          seq: event["seq"], at: event["at"], mono_ms: event["mono_ms"],
          session_id: event["session_id"], kind: event["kind"], stream: event["stream"],
          key: event["key"], from: event["from"], to: event["to"],
          op: event["op"], values: event["values"],
          fields: event.reject { |k, _| COMMON.include?(k) }
        )
      end
    end
  end
end
