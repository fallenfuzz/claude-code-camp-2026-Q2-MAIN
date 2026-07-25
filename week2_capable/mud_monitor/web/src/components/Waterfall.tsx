import { useMemo, useState } from "react";
import type { Entry, SessionSummary } from "../api/types";
import { fmtDelta, fmtDuration } from "../format";
import { categoryFor, isContainerSpan, operationLabel, type WaterfallCategory } from "../spans";

// instrumentation.md §11: a transcript is ordered by sequence, not duration,
// and 88% of a turn's wall time can sit in the gaps between lines. This is the
// second view over the SAME span data that answers "where did the time go" —
// magnitude and causal structure over time, not another narrative.

const CATEGORY_META: Record<WaterfallCategory, { glyph: string; label: string }> = {
  inference: { glyph: "🧠", label: "model inference" },
  mud: { glyph: "⚙", label: "MUD round trip" },
  memory: { glyph: "⛁", label: "memory / store" },
  local: { glyph: "◆", label: "local inference" },
};

export interface WaterfallSpan {
  id: string;
  operation: string;
  depth: number;
  startMs: number;
  durationMs: number | null;
  /** duration minus the sum of direct children's durations — so a container
   *  span's bar does not read as entirely its own work. */
  selfMs: number | null;
  ok: boolean;
  rollup: Record<string, number> | null;
  category: WaterfallCategory;
  /** turn/iteration/wrap_up/compaction: a real span, but no work of its own
   *  beyond its children — outline only, never one of the three hues. */
  container: boolean;
  /** No operation_end — mid-flight (a live session) or the process died. */
  open: boolean;
  /** The span's own opening entry — what a click scrolls the transcript to. */
  anchorSeq: number;
}

function atMs(e: Entry): number {
  if (!e.at) return 0;
  const t = new Date(e.at).getTime();
  return Number.isNaN(t) ? 0 : t;
}

// Pure function over the flat entries list — no dependency on
// buildTranscriptTree, because the waterfall's row order is chronological and
// its indent is span depth, neither of which the transcript tree encodes
// directly (it orders by containment within a rendering pass, not by start
// time across the whole session).
export function buildWaterfallSpans(entries: Entry[]): WaterfallSpan[] {
  const starts = entries.filter((e) => e.type === "operation_start");
  if (!starts.length) return [];

  const startsById = new Map<string, Entry>();
  for (const s of starts) if (s.operation_id) startsById.set(s.operation_id, s);

  const endsById = new Map<string, Entry>();
  for (const e of entries) {
    if (e.type === "operation_end" && e.operation_id) endsById.set(e.operation_id, e);
  }

  const t0 = Math.min(...starts.map(atMs));

  // -1 is the "no span" sentinel so a ROOT span (parent_operation_id: null)
  // comes out at depth 0 — depthOf(id) = depthOf(parent(id)) + 1, and a root's
  // parent is nothing, i.e. depth -1, making the root itself depth 0.
  const depthCache = new Map<string, number>();
  const depthOf = (id: string | null | undefined): number => {
    if (!id) return -1;
    const cached = depthCache.get(id);
    if (cached != null) return cached;
    const start = startsById.get(id);
    const d = start ? depthOf(start.parent_operation_id) + 1 : -1;
    depthCache.set(id, d);
    return d;
  };

  // Self time: duration minus the sum of DIRECT children's durations.
  const childDurationTotal = new Map<string, number>();
  for (const s of starts) {
    const parent = s.parent_operation_id;
    if (!parent || !s.operation_id) continue;
    const end = endsById.get(s.operation_id);
    if (end?.duration_ms == null) continue;
    childDurationTotal.set(parent, (childDurationTotal.get(parent) ?? 0) + end.duration_ms);
  }

  return starts
    .map((s) => {
      const id = s.operation_id ?? `seq-${s.seq}`;
      const end = s.operation_id ? endsById.get(s.operation_id) : undefined;
      const durationMs = end?.duration_ms ?? null;
      const childMs = s.operation_id ? (childDurationTotal.get(s.operation_id) ?? 0) : 0;
      return {
        id,
        operation: s.operation ?? "unknown",
        depth: s.operation_id ? Math.max(depthOf(s.operation_id), 0) : 0,
        startMs: atMs(s) - t0,
        durationMs,
        selfMs: durationMs != null ? Math.max(0, durationMs - childMs) : null,
        ok: end?.ok ?? true,
        rollup: end?.rollup ?? null,
        category: categoryFor(s.operation),
        container: isContainerSpan(s.operation),
        open: end == null,
        anchorSeq: s.seq,
      };
    })
    .sort((a, b) => a.startMs - b.startMs);
}

function waterfallTooltip(s: WaterfallSpan, coarse: boolean): string {
  const parts = [ operationLabel(s.operation) ];
  parts.push(s.durationMs != null ? fmtDelta(s.durationMs, coarse) : "running");
  if (s.selfMs != null && s.durationMs != null && s.selfMs !== s.durationMs) {
    parts.push(`self ${fmtDelta(s.selfMs, coarse)}`);
  }
  if (s.rollup) {
    for (const [ key, value ] of Object.entries(s.rollup)) parts.push(`${key}: ${value}`);
  }
  return parts.join(" · ");
}

export default function Waterfall({
  entries,
  session,
  coarse,
  onJumpToSeq,
}: {
  entries: Entry[];
  session: SessionSummary;
  coarse: boolean;
  onJumpToSeq: (seq: number) => void;
}) {
  const spans = useMemo(() => buildWaterfallSpans(entries), [ entries ]);
  const [ view, setView ] = useState<"chart" | "table">("chart");

  if (!spans.length) {
    return <p className="muted">No spans recorded in this session — nothing to show in the waterfall.</p>;
  }

  const totalMs = Math.max(...spans.map((s) => s.startMs + (s.durationMs ?? 0)), 1);

  return (
    <div className="waterfall">
      {/* The headline magnitudes are not a chart at all — three hero tiles
          answer "where did the time go" in one glance, and the timeline below
          answers "and in what shape". */}
      <div className="waterfall-hero">
        <div className="hero-stat">
          <span className="hero-stat-glyph">🧠</span>
          <span className="hero-stat-value">{fmtDuration(session.timing.model_ms)}</span>
          <span className="hero-stat-label">inference</span>
        </div>
        <div className="hero-stat">
          <span className="hero-stat-glyph">⚙</span>
          <span className="hero-stat-value">{fmtDuration(session.mud_ms)}</span>
          <span className="hero-stat-label">MUD</span>
        </div>
        <div className="hero-stat">
          <span className="hero-stat-glyph">⛁</span>
          <span className="hero-stat-value">{fmtDuration(session.db_ms)}</span>
          <span className="hero-stat-label">memory</span>
        </div>
      </div>

      <div className="waterfall-view-toggle">
        <button type="button" className={view === "chart" ? "active" : ""} onClick={() => setView("chart")}>
          Chart
        </button>
        <button type="button" className={view === "table" ? "active" : ""} onClick={() => setView("table")}>
          Table
        </button>
      </div>

      {view === "chart" ? (
        <WaterfallChart spans={spans} totalMs={totalMs} coarse={coarse} onJumpToSeq={onJumpToSeq} />
      ) : (
        <WaterfallTable spans={spans} coarse={coarse} onJumpToSeq={onJumpToSeq} />
      )}

      <WaterfallLegend />
    </div>
  );
}

// One row per span, x = elapsed ms since the earliest span in view, bar width
// ∝ duration, indent ∝ depth. No charting library — plain positioned divs,
// the same "hand-rolled, no dependency" discipline Sparkline.tsx already
// follows.
function WaterfallChart({
  spans,
  totalMs,
  coarse,
  onJumpToSeq,
}: {
  spans: WaterfallSpan[];
  totalMs: number;
  coarse: boolean;
  onJumpToSeq: (seq: number) => void;
}) {
  return (
    <div className="waterfall-chart" role="img" aria-label="span timeline">
      {spans.map((s) => {
        const leftPct = (s.startMs / totalMs) * 100;
        const widthPct = s.durationMs != null
          ? Math.max((s.durationMs / totalMs) * 100, 0.4)
          : Math.max(100 - leftPct, 0.4);
        const meta = CATEGORY_META[s.category];
        const classes = [ "waterfall-bar", `waterfall-bar-${s.category}` ];
        if (s.container) classes.push("waterfall-bar-container");
        if (s.open) classes.push("waterfall-bar-open");
        if (s.ok === false) classes.push("waterfall-bar-failed");

        return (
          <div key={s.id} className="waterfall-row">
            <span className="waterfall-row-label" style={{ paddingLeft: `${s.depth * 14}px` }}>
              {!s.container && <span aria-hidden="true">{meta.glyph}</span>} {operationLabel(s.operation)}
            </span>
            <div className="waterfall-track">
              <button
                type="button"
                className={classes.join(" ")}
                style={{ left: `${leftPct}%`, width: `${widthPct}%` }}
                onClick={() => onJumpToSeq(s.anchorSeq)}
                title={waterfallTooltip(s, coarse)}
              />
            </div>
            <span className="waterfall-row-duration">
              {s.durationMs != null ? fmtDelta(s.durationMs, coarse) : "running"}
            </span>
          </div>
        );
      })}
    </div>
  );
}

// The copyable, accessible, "what did this turn cost" form — required by the
// palette's light-mode contrast relief (§11) and useful in its own right:
// sortable by duration, every row directly labelled.
function WaterfallTable({
  spans,
  coarse,
  onJumpToSeq,
}: {
  spans: WaterfallSpan[];
  coarse: boolean;
  onJumpToSeq: (seq: number) => void;
}) {
  const sorted = useMemo(
    () => [ ...spans ].sort((a, b) => (b.durationMs ?? 0) - (a.durationMs ?? 0)),
    [ spans ],
  );

  return (
    <table className="waterfall-table">
      <thead>
        <tr>
          <th scope="col">span</th>
          <th scope="col">depth</th>
          <th scope="col">category</th>
          <th scope="col">duration</th>
          <th scope="col">self</th>
          <th scope="col">counters</th>
        </tr>
      </thead>
      <tbody>
        {sorted.map((s) => (
          <tr key={s.id} className={s.ok === false ? "waterfall-table-failed" : undefined}>
            <td>
              <button type="button" className="link-button" onClick={() => onJumpToSeq(s.anchorSeq)}>
                {operationLabel(s.operation)}
              </button>
            </td>
            <td className="num">{s.depth}</td>
            <td>{s.container ? "—" : CATEGORY_META[s.category].label}</td>
            <td className="num">{s.durationMs != null ? fmtDelta(s.durationMs, coarse) : "running"}</td>
            <td className="num">{s.selfMs != null ? fmtDelta(s.selfMs, coarse) : "—"}</td>
            <td className="waterfall-table-counters">
              {s.rollup ? Object.entries(s.rollup).map(([ key, value ]) => `${key}=${value}`).join(", ") : "—"}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

// Present always, and identity is never colour-alone: each category carries
// its glyph, discharging the light-mode contrast WARN the palette validation
// flags (§11).
function WaterfallLegend() {
  return (
    <div className="waterfall-legend">
      {(Object.keys(CATEGORY_META) as WaterfallCategory[]).map((cat) => (
        <span key={cat} className={`waterfall-legend-item waterfall-bar-${cat}`}>
          {CATEGORY_META[cat].glyph} {CATEGORY_META[cat].label}
        </span>
      ))}
      <span className="waterfall-legend-item waterfall-bar-container">structural (turn / iteration)</span>
    </div>
  );
}
