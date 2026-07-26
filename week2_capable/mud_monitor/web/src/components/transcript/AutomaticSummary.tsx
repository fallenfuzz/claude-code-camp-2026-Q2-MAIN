import type { Entry } from "../../api/types";
import { fmtDelta } from "../../format";
import { operationLabel } from "../../spans";
import { tallyTools } from "./ToolCard";
import type { AutoNode } from "./types";
import { toolsIn } from "./types";

function isEmptyResult(entry: Entry) {
  return !entry.tool_result?.trim();
}

// The collapsed one-line-per-operation view. With spans, each child span is
// already one operation and contributes one row. Without them (a pre-span log),
// runs of adjacent calls sharing an `operation` string are folded — which is
// the approximation spans exist to replace, kept only for those files.
export default function AutomaticSummary({ node, coarse, live }: { node: AutoNode; coarse: boolean; live: boolean }) {
  const rows: { key: string; label: string; entries: Entry[]; incomplete: boolean }[] = [];

  for (const child of node.children) {
    if (child.kind === "op") {
      rows.push({
        key: child.start.operation_id ?? String(child.start.seq),
        label: operationLabel(child.start.operation),
        entries: toolsIn(child),
        incomplete: child.end == null,
      });
    } else if (child.kind === "entry") {
      const key = child.entry.operation ?? "unattributed";
      const last = rows[rows.length - 1];
      if (last?.key === key) last.entries.push(child.entry);
      else rows.push({ key, label: operationLabel(key), entries: [ child.entry ], incomplete: false });
    }
  }

  return (
    <ol className="auto-summary">
      {rows.map((row, i) => {
        const ms = row.entries.reduce((sum, e) => sum + (e.duration_ms ?? 0), 0);
        const empty = row.entries.filter(isEmptyResult).length;
        return (
          <li key={`${row.key}-${i}`}>
            <span className="auto-summary-op">{row.label}</span>
            <span className="auto-summary-tools">
              {tallyTools(row.entries)}
              {/* An empty poll is the expected case, not a fault — say how
                  many rather than giving each one a row. */}
              {empty === row.entries.length && row.entries.length > 1 && ", all empty"}
              {empty === row.entries.length && row.entries.length === 1 && ", empty"}
            </span>
            {row.incomplete && (live ? <span className="task-group-meta">running</span> : <span className="task-group-incomplete">incomplete</span>)}
            {ms > 0 && <span className="auto-summary-ms">{fmtDelta(ms, coarse)}</span>}
          </li>
        );
      })}
    </ol>
  );
}
