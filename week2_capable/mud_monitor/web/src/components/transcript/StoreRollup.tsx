import { useState } from "react";
import { fmtDelta } from "../../format";
import JournalDetail from "./JournalDetail";

// `⛁ wrote 11 · read 6 · 3ms (7 journal lines)`.
//
// The two numbers count different things and the gap between them is the
// interesting part, in either direction. Fewer lines than writes means the
// journal swallowed no-ops — `jupsert` is change-detecting, so re-writing an
// unchanged value appends nothing, and that is how you find a survey rewriting
// values that never change. MORE lines than writes is the ordinary case for
// `update_player!`, where one UPDATE of six columns is six keyed series.
export default function StoreRollup({
  rollup,
  operationId,
  coarse,
}: {
  rollup: Record<string, number> | null;
  operationId?: string | null;
  coarse: boolean;
}) {
  const [showJournal, setShowJournal] = useState(false);
  if (!rollup) return null;

  const writes = rollup.db_writes ?? 0;
  const reads = rollup.db_reads ?? 0;
  const lines = rollup.journal_lines ?? 0;
  // A span in a session with no store attached reports no db keys at all —
  // "we did not read" and "we cannot say" are different answers.
  if (rollup.db_writes == null && rollup.db_reads == null) return null;

  return (
    <div className="op-rollup">
      <span className="op-rollup-icon">⛁</span>
      <span>wrote {writes}</span>
      <span>· read {reads}</span>
      {rollup.db_ms != null && <span>· {fmtDelta(rollup.db_ms, coarse)}</span>}
      {lines > 0 && operationId && (
        <button type="button" className="op-rollup-journal" onClick={() => setShowJournal(!showJournal)}>
          ({lines} journal line{lines === 1 ? "" : "s"})
        </button>
      )}
      {lines > 0 && !operationId && (
        <span className="op-rollup-journal-flat">
          ({lines} journal line{lines === 1 ? "" : "s"})
        </span>
      )}
      {showJournal && operationId && <JournalDetail operationId={operationId} />}
    </div>
  );
}
