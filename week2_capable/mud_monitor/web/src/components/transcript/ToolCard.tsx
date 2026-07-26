import { useState } from "react";
import type { Entry } from "../../api/types";
import { fmtDelta, formatArgs } from "../../format";
import Ansi from "../Ansi";
import JournalDetail from "./JournalDetail";
import type { ToolRollupInfo } from "./types";

// `tbamud__check(kind: score)` → `check(score)`. The prefix and the argument
// noise are constant across a session and earn no space in a summary line.
export function shortToolName(entry: Entry) {
  const name = (entry.tool_name ?? "?").replace(/^.*__/, "");
  const arg = entry.tool_args?.kind ?? entry.tool_args?.target ?? entry.tool_args?.direction;
  return arg == null ? name : `${name}(${String(arg)})`;
}

// `poll × 8`, not `poll, poll, poll, poll, poll, poll, poll, poll`. Eight
// identical calls carry one fact between them and should occupy one line.
export function tallyTools(entries: Entry[]): string {
  const counts = new Map<string, number>();
  for (const entry of entries) {
    const label = shortToolName(entry);
    counts.set(label, (counts.get(label) ?? 0) + 1);
  }
  return [ ...counts ].map(([ label, n ]) => (n > 1 ? `${label} × ${n}` : label)).join(", ");
}

// One tool call. When a hook replaced the result before it reached the model,
// the card shows what the MODEL received and offers the MUD's own words on
// demand — the two used to appear as an unexplained contradiction between the
// transcript (full room dump) and the request drawer (`moved west → …`).
//
// The raw text is never discarded: it is what debugs the parser and the
// transport, while the replacement is what debugs the agent's behaviour.
export function ToolCard({
  entry,
  rollup,
  coarse = false,
}: {
  entry: Entry;
  rollup?: ToolRollupInfo | null;
  coarse?: boolean;
}) {
  const replaced = entry.model_result != null;
  const [showRaw, setShowRaw] = useState(false);

  return (
    <div className={entry.tool_ok === false ? "tool-call tool-error" : "tool-call"}>
      <div className="tool-name">
        <span>
          ⚙ {entry.tool_name}({formatArgs(entry.tool_args)})
        </span>
        {entry.tool_ok === false && <span className="tool-badge">error</span>}
      </div>

      {replaced ? (
        <>
          <pre className="tool-result tool-result-model">{entry.model_result}</pre>
          <button type="button" className="raw-toggle" aria-expanded={showRaw} onClick={() => setShowRaw(!showRaw)}>
            {showRaw ? "▾" : "▸"} raw MUD response
            {entry.raw_chars != null && <span className="task-group-meta"> {entry.raw_chars} chars</span>}
          </button>
          {showRaw && (
            <pre className="tool-result">
              <Ansi html={entry.result_html ?? ""} />
            </pre>
          )}
        </>
      ) : (
        <pre className="tool-result">
          <Ansi html={entry.result_html ?? ""} />
        </pre>
      )}

      {rollup && <ToolSpanRollup rollup={rollup} coarse={coarse} />}
    </div>
  );
}

// The `tool.<name>` span's own summary, folded in with its `after_tool`
// child's (never a separate box). ⚙ is the MUD round trip the dispatch itself
// paid for; ⛁ is what `after_tool`'s store/journal writes spent reacting to
// the result — two different currencies, both real.
export function ToolSpanRollup({
  rollup,
  coarse,
}: {
  rollup: ToolRollupInfo;
  coarse: boolean;
}) {
  const [showJournal, setShowJournal] = useState(false);
  const r = rollup.rollup;
  if (!r) return null;

  const hasMud = r.mud_calls != null;
  const hasDb = r.db_writes != null || r.db_reads != null;
  const lines = r.journal_lines ?? 0;
  if (!hasMud && !hasDb) return null;

  return (
    <div className="op-rollup">
      {hasMud && (
        <span>
          <span className="op-rollup-icon">⚙</span> {r.mud_calls} MUD call{r.mud_calls === 1 ? "" : "s"}
          {r.mud_ms != null && <> · {fmtDelta(r.mud_ms, coarse)}</>}
        </span>
      )}
      {hasDb && (
        <span>
          <span className="op-rollup-icon">⛁</span> wrote {r.db_writes ?? 0} · read {r.db_reads ?? 0}
        </span>
      )}
      {lines > 0 && rollup.afterToolOperationId && (
        <button type="button" className="op-rollup-journal" onClick={() => setShowJournal(!showJournal)}>
          ({lines} journal line{lines === 1 ? "" : "s"})
        </button>
      )}
      {showJournal && rollup.afterToolOperationId && <JournalDetail operationId={rollup.afterToolOperationId} />}
    </div>
  );
}
