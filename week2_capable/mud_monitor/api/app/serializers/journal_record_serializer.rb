# Renders a Journal::Parser::Record into the JSON shape the Progression view's
# live stream consumes. The common columns are explicit; the open set of
# event-specific fields (descr, keyword, qty, level, tool, …) is spread in from
# `fields` so a new op can carry a new key without a serializer change.
class JournalRecordSerializer
  def self.call(record)
    base = {
      seq: record.seq,
      at: record.at,
      mono_ms: record.mono_ms,
      session_id: record.session_id,
      kind: record.kind,
      stream: record.stream,
      key: record.key,
      from: record.from,
      to: record.to,
      op: record.op,
      values: record.values
    }.compact
    base.merge(record.fields || {})
  end
end
