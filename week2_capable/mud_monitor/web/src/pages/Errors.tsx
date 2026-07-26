import { useCallback, useEffect, useMemo, useState } from "react";
import { Link } from "react-router";
import { ApiRequestError, fetchErrors } from "../api/client";
import type { ErrorRecord } from "../api/types";
import { useEventStream } from "../api/useEventStream";
import LiveBadge from "../components/LiveBadge";
import { fmtAbsolute } from "../format";

function diagnostic(record: ErrorRecord): string {
  const correlation = [
    record.id,
    record.session_id && `session=${record.session_id}`,
    record.operation_id && `operation=${record.operation_id}`,
    record.trace_id && `trace=${record.trace_id}`,
  ].filter(Boolean).join(" ");
  return `${record.exception_class}: ${record.message}\n${correlation}\n${record.backtrace.join("\n")}`;
}

export default function Errors() {
  const [component, setComponent] = useState("");
  const [exceptionClass, setExceptionClass] = useState("");
  const [sessionId, setSessionId] = useState("");
  const [query, setQuery] = useState("");
  const [records, setRecords] = useState<ErrorRecord[] | null>(null);
  const [cursor, setCursor] = useState(0);
  const [available, setAvailable] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setRecords(null);
    setError(null);
    fetchErrors({ component, exceptionClass, sessionId, q: query })
      .then((page) => {
        setRecords(page.entries);
        setCursor(page.next_cursor);
        setAvailable(page.available);
      })
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, [component, exceptionClass, sessionId, query]);

  const onEntry = useCallback((entry: ErrorRecord) => {
    setRecords((previous) => {
      const rows = previous ?? [];
      return rows.some((row) => row.id === entry.id) ? rows : [entry, ...rows];
    });
  }, []);

  const buildUrl = useMemo(() => (after: number) => {
    const params = new URLSearchParams({ after: String(after) });
    if (component) params.set("component", component);
    if (exceptionClass) params.set("exception_class", exceptionClass);
    if (sessionId) params.set("session_id", sessionId);
    if (query) params.set("q", query);
    return `/api/v1/errors/stream?${params.toString()}`;
  }, [component, exceptionClass, sessionId, query]);

  const streamKey = `errors:${component}:${exceptionClass}:${sessionId}:${query}`;
  const streamStatus = useEventStream<ErrorRecord>({
    streamKey,
    buildUrl,
    enabled: true,
    initialAfterSeq: cursor,
    onEntry,
  });

  return (
    <>
      <h1>Errors <LiveBadge status={streamStatus} /></h1>
      <p className="meta">Durable exceptions captured by Boukensha, including complete Ruby backtraces.</p>

      <div className="error-filters">
        <label>Component<input value={component} onChange={(e) => setComponent(e.target.value)} placeholder="all" /></label>
        <label>Exception<input value={exceptionClass} onChange={(e) => setExceptionClass(e.target.value)} placeholder="all" /></label>
        <label>Session<input value={sessionId} onChange={(e) => setSessionId(e.target.value)} placeholder="all" /></label>
        <label>Search<input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="message or frame" /></label>
      </div>

      {error && <p className="error">Failed to load error log: {error}</p>}
      {!error && records === null && <p>Loading…</p>}
      {records?.length === 0 && (
        <p className="empty">
          {available ? "No errors match these filters." : "No errors captured for this profile."}
        </p>
      )}

      <div className="error-list">
        {records?.map((record) => (
          <details className={`error-card${record.malformed ? " error-card-malformed" : ""}`} key={`${record.id}:${record.seq}`}>
            <summary>
              <span className="error-time">{fmtAbsolute(record.at)}</span>
              <strong>{record.exception_class}</strong>
              <span className="error-message">{record.message}</span>
              <span className="error-component">{record.component} · {record.boundary}</span>
            </summary>
            <div className="error-detail">
              <div className="error-correlation">
                <code>{record.id}</code>
                {record.session_id && (
                  <Link to={`/sessions/${encodeURIComponent(record.session_id)}${record.operation_id ? `?op=${encodeURIComponent(record.operation_id)}` : ""}`}>
                    session
                  </Link>
                )}
                {record.trace_id && <code>trace {record.trace_id}</code>}
                <button type="button" onClick={() => navigator.clipboard.writeText(diagnostic(record))}>Copy diagnostic</button>
              </div>
              {record.backtrace.length > 0
                ? <pre className="error-backtrace">{record.backtrace.join("\n")}</pre>
                : <p className="meta">No backtrace was available.</p>}
            </div>
          </details>
        ))}
      </div>
    </>
  );
}
