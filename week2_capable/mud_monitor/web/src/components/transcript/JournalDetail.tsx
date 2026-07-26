import { useEffect, useState } from "react";
import { fetchJournalForOperation } from "../../api/client";
import type { JournalRecord } from "../../api/types";

// Fetched on expand, never bundled into the session payload: the session view
// should not grow a second full log inside it. The rows are the same ones the
// Progression tab shows for this operation — one writer per fact, and the
// journal keeps the detail.
export default function JournalDetail({ operationId }: { operationId: string }) {
  const [rows, setRows] = useState<JournalRecord[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    fetchJournalForOperation(operationId)
      .then((page) => live && setRows(page.entries))
      .catch((e: Error) => live && setError(e.message));
    return () => {
      live = false;
    };
  }, [operationId]);

  if (error) return <div className="op-journal op-journal-error">journal unavailable — {error}</div>;
  if (rows == null) return <div className="op-journal">loading…</div>;
  if (rows.length === 0) return <div className="op-journal">no change lines for this operation today</div>;

  return (
    <ol className="op-journal">
      {rows.map((r) => (
        <li key={r.seq}>
          <span className="op-journal-stream">{r.stream}</span>
          {r.kind === "change" ? (
            <span>
              {r.key}: {String(r.from ?? "—")} → {String(r.to)}
            </span>
          ) : (
            <span>{r.op}</span>
          )}
        </li>
      ))}
    </ol>
  );
}
