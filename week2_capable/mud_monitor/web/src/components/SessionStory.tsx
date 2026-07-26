import { useEffect, useMemo, useState } from "react";
import type { Entry, SessionSpan, SessionTrace } from "../api/types";
import { fmtCost, fmtDelta, fmtDuration } from "../format";
import { operationLabel } from "../spans";
import TaskChip from "./TaskChip";
import LocalInferenceRow from "./transcript/LocalInferenceRow";
import { shortToolName, tallyTools, ToolCard } from "./transcript/ToolCard";
import EntryCard from "./transcript/EntryCard";
import type { ToolRollupInfo } from "./transcript/types";

type Preset = "story" | "timing" | "everything";

type Props = {
  trace: SessionTrace;
  entries: Entry[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  onOpenRequest: (seq: number) => void;
  contextWindow: number | null | undefined;
  maxTurnTokens: number | null | undefined;
  coarse: boolean;
  live: boolean;
};

const KIND_ICON: Record<SessionSpan["semantic_kind"], string> = {
  invoke_agent: "◆", iteration: "↻", chat: "●", execute_tool: "⚙",
  hook: "◇", state: "▧", after_tool: "↳", compaction: "⇥",
  wrap_up: "■", internal: "·", session: "▤",
};

// Not every span deserves the same weight. `semantic_kind` decides how it
// starts: expanded and part of the model's narrative, or collapsed and
// folded away as automatic work — session_story_tree.md's row-policy table.
function defaultExpandedFor(kind: SessionSpan["semantic_kind"]): boolean {
  return kind !== "hook" && kind !== "state" && kind !== "after_tool" && kind !== "internal";
}

function isNotableEntry(entry: Entry): boolean {
  return entry.tool_ok === false || (entry.operation === "async_poll" && !!entry.tool_result?.trim());
}

// A failed call and a poll that actually returned something force themselves
// and every ancestor open — being nested must never make a problem harder to
// notice than being flat did.
export function forceOpenIds(trace: SessionTrace, entries: Entry[]): Set<string> {
  const force = new Set<string>();
  entries.filter((e) => e.type === "tool" && isNotableEntry(e)).forEach((e) => {
    let id = e.operation_id ?? null;
    while (id && trace.spans[id]) {
      force.add(id);
      id = trace.spans[id].parent_id;
    }
  });
  return force;
}

export function seedExpanded(trace: SessionTrace, entries: Entry[], preset: Preset): Set<string> {
  const ids = new Set<string>();
  Object.values(trace.spans).forEach((span) => {
    // Timing/Everything: expand every span so the full shape of the session
    // is visible on one shared axis — the "I want to see the shape" view the
    // waterfall used to be the only way to get.
    if (preset !== "story" || defaultExpandedFor(span.semantic_kind)) ids.add(span.id);
  });
  forceOpenIds(trace, entries).forEach((id) => ids.add(id));
  return ids;
}

export function toolRollupFor(span: SessionSpan, trace: SessionTrace): ToolRollupInfo {
  const rollup: Record<string, number> = { ...(span.rollup ?? {}) };
  let afterToolOperationId: string | null = null;
  for (const childId of span.child_ids) {
    const child = trace.spans[childId];
    if (child?.semantic_kind !== "after_tool") continue;
    afterToolOperationId = child.id;
    for (const [ key, value ] of Object.entries(child.rollup ?? {})) {
      rollup[key] = (rollup[key] ?? 0) + value;
    }
  }
  return { durationMs: span.duration_ms, rollup: Object.keys(rollup).length ? rollup : null, afterToolOperationId };
}

function findEntry(span: SessionSpan, entriesBySeq: Map<number, Entry>, type: Entry["type"]): Entry | undefined {
  for (const seq of span.direct_entry_seqs) {
    const e = entriesBySeq.get(seq);
    if (e?.type === type) return e;
  }
  return undefined;
}

function collectToolEntries(span: SessionSpan, trace: SessionTrace, entriesBySeq: Map<number, Entry>): Entry[] {
  const own = span.direct_entry_seqs
    .map((seq) => entriesBySeq.get(seq))
    .filter((e): e is Entry => e?.type === "tool");
  const nested = span.child_ids.flatMap((id) => {
    const child = trace.spans[id];
    return child ? collectToolEntries(child, trace, entriesBySeq) : [];
  });
  return [ ...own, ...nested ];
}

export function buildCostIndex(trace: SessionTrace, entriesBySeq: Map<number, Entry>): Map<string, number> {
  const cache = new Map<string, number>();
  const compute = (id: string): number => {
    const cached = cache.get(id);
    if (cached != null) return cached;
    const span = trace.spans[id];
    if (!span) return 0;
    let total = span.direct_entry_seqs.reduce((sum, seq) => sum + (entriesBySeq.get(seq)?.cost_usd ?? 0), 0);
    total += span.child_ids.reduce((sum, cid) => sum + compute(cid), 0);
    cache.set(id, total);
    return total;
  };
  Object.keys(trace.spans).forEach(compute);
  return cache;
}

function titleCase(value: string): string {
  return value ? value.charAt(0).toUpperCase() + value.slice(1).replaceAll("_", " ") : value;
}

function chatModel(span: SessionSpan): string {
  const attr = span.attributes?.["gen_ai.request.model"];
  if (typeof attr === "string" && attr) return attr;
  return span.name.replace(/^chat\s*/, "") || "model";
}

// The nav list keyboard ↑/↓ moves between: every visible span header, in the
// same reading order the document renders them (span.timeline, not raw
// child_ids) — minus `after_tool`, which never draws its own row.
export function flattenSpans(trace: SessionTrace, expanded: Set<string>): { span: SessionSpan; depth: number }[] {
  const result: { span: SessionSpan; depth: number }[] = [];
  const visit = (id: string, depth: number) => {
    const span = trace.spans[id];
    if (!span) return;
    result.push({ span, depth });
    if (!expanded.has(id)) return;
    span.timeline.forEach((item) => {
      if (item.kind !== "span") return;
      const child = trace.spans[item.id];
      if (child?.semantic_kind === "after_tool") return;
      visit(item.id, depth + 1);
    });
  };
  trace.roots.forEach((id) => visit(id, 0));
  return result;
}

export default function SessionStory({
  trace, entries, selectedId, onSelect, onOpenRequest, contextWindow, maxTurnTokens, coarse, live,
}: Props) {
  const [preset, setPreset] = useState<Preset>("story");
  const [expanded, setExpanded] = useState<Set<string>>(() => seedExpanded(trace, entries, "story"));

  const entriesBySeq = useMemo(() => new Map(entries.map((e) => [ e.seq, e ])), [ entries ]);
  const costIndex = useMemo(() => buildCostIndex(trace, entriesBySeq), [ trace, entriesBySeq ]);
  const turnDurationByTurn = useMemo(() => {
    const map = new Map<number, number | null>();
    Object.values(trace.spans)
      .filter((s) => s.semantic_kind === "invoke_agent" && s.turn != null)
      .forEach((s) => map.set(s.turn as number, s.duration_ms));
    return map;
  }, [ trace ]);

  const starts = Object.values(trace.spans).map((s) => s.start_mono_ms).filter((n): n is number => n != null);
  const origin = starts.length ? Math.min(...starts) : 0;
  const end = Math.max(
    origin + 1,
    ...Object.values(trace.spans).map((s) => (s.start_mono_ms ?? origin) + (s.duration_ms ?? 0)),
  );
  const total = end - origin;

  const toggle = (id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };

  const applyPreset = (next: Preset) => {
    setPreset(next);
    setExpanded(seedExpanded(trace, entries, next));
  };

  const collapseToTurns = () => setExpanded(new Set());

  // Expand every ancestor of the selected/linked span and scroll it into
  // view — selection is highlight-and-scroll now, not "what a detail pane
  // shows" (session_story_tree.md Phase 4).
  useEffect(() => {
    if (!selectedId) return;
    setExpanded((prev) => {
      const next = new Set(prev);
      let id: string | null = trace.spans[selectedId]?.parent_id ?? null;
      while (id) {
        next.add(id);
        id = trace.spans[id]?.parent_id ?? null;
      }
      return next;
    });
    const el = document.getElementById(`span-${selectedId}`);
    el?.scrollIntoView({ block: "center", behavior: "smooth" });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ selectedId ]);

  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (!selectedId) return;
      const rows = flattenSpans(trace, expanded);
      const index = rows.findIndex((row) => row.span.id === selectedId);
      const current = rows[index]?.span;
      if (event.key === "ArrowDown" && rows[index + 1]) onSelect(rows[index + 1].span.id);
      if (event.key === "ArrowUp" && rows[index - 1]) onSelect(rows[index - 1].span.id);
      if (event.key === "Enter" && current) toggle(current.id);
      if (event.key === "ArrowLeft" && current) {
        if (expanded.has(current.id)) toggle(current.id);
        else if (current.parent_id) onSelect(current.parent_id);
      }
      if (event.key === "ArrowRight" && current) {
        const firstChildItem = current.timeline.find((item) => item.kind === "span");
        if (firstChildItem && !expanded.has(current.id)) toggle(current.id);
        else if (firstChildItem?.kind === "span") onSelect(firstChildItem.id);
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [ expanded, onSelect, selectedId, trace ]);

  const ctx: RenderCtx = {
    trace, entriesBySeq, expanded, toggle, onSelect, onOpenRequest,
    contextWindow, maxTurnTokens, coarse, live, origin, total, costIndex, turnDurationByTurn, selectedId,
  };

  return (
    <section className="session-story">
      <div className="story-toolbar" role="tablist" aria-label="Story presets">
        <button type="button" className={preset === "story" ? "active" : ""} onClick={() => applyPreset("story")}>Story</button>
        <button type="button" className={preset === "timing" ? "active" : ""} onClick={() => applyPreset("timing")}>Timing</button>
        <button type="button" className={preset === "everything" ? "active" : ""} onClick={() => applyPreset("everything")}>Everything</button>
        <span className="task-group-spacer" />
        <button type="button" onClick={collapseToTurns}>collapse all to turns</button>
      </div>
      <div className="story-tree" role="tree" aria-label="Session story">
        {trace.roots.map((id) => (
          <SpanSection key={id} span={trace.spans[id]} depth={0} ctx={ctx} />
        ))}
      </div>
    </section>
  );
}

interface RenderCtx {
  trace: SessionTrace;
  entriesBySeq: Map<number, Entry>;
  expanded: Set<string>;
  toggle: (id: string) => void;
  onSelect: (id: string) => void;
  onOpenRequest: (seq: number) => void;
  contextWindow: number | null | undefined;
  maxTurnTokens: number | null | undefined;
  coarse: boolean;
  live: boolean;
  origin: number;
  total: number;
  costIndex: Map<string, number>;
  turnDurationByTurn: Map<number, number | null>;
  selectedId: string | null;
}

function SpanHeaderTitle({ span, ctx }: { span: SessionSpan; ctx: RenderCtx }) {
  switch (span.semantic_kind) {
    case "invoke_agent":
      return <>{span.turn != null ? `Turn ${span.turn} · ` : ""}{titleCase(span.task ?? "agent")} task</>;
    case "iteration":
      return <>Iteration {span.iteration ?? "?"}</>;
    case "chat":
      return <>Model call · {chatModel(span)}</>;
    case "execute_tool": {
      const toolEntry = findEntry(span, ctx.entriesBySeq, "tool");
      return <>{toolEntry ? shortToolName(toolEntry) : operationLabel(span.name)}</>;
    }
    case "hook":
      return <>Automatic context work · {operationLabel(span.name)}</>;
    case "state":
      return <>state render</>;
    case "after_tool":
      return <>record outcome</>;
    case "compaction":
      return <>compact context</>;
    case "wrap_up":
      return <>wind down</>;
    case "session":
      return <>Session</>;
    default:
      return <>internal · {span.name.replace(/_/g, " ")}</>;
  }
}

function SpanBadges({ span, ctx }: { span: SessionSpan; ctx: RenderCtx }) {
  const cost = ctx.costIndex.get(span.id) ?? 0;
  switch (span.semantic_kind) {
    case "invoke_agent": {
      const iterCount = span.child_ids.filter((id) => ctx.trace.spans[id]?.semantic_kind === "iteration").length;
      return (
        <>
          {span.task && <TaskChip task={span.task} />}
          {iterCount > 0 && <span className="task-group-meta">{iterCount} iter</span>}
          {cost > 0 && <span className="task-group-meta">{fmtCost(cost)}</span>}
        </>
      );
    }
    case "iteration": {
      const mudCalls = span.rollup?.mud_calls;
      return (
        <>
          {mudCalls ? <span className="task-group-meta">{mudCalls} MUD call{mudCalls === 1 ? "" : "s"}</span> : null}
          {cost > 0 && <span className="task-group-meta">{fmtCost(cost)}</span>}
        </>
      );
    }
    case "chat": {
      const assistant = findEntry(span, ctx.entriesBySeq, "assistant");
      return (
        <>
          {assistant?.input_tokens != null && (
            <span className="task-group-meta">{assistant.input_tokens} in · {assistant.output_tokens ?? 0} out</span>
          )}
          {assistant?.cost_usd != null && <span className="task-group-meta">{fmtCost(assistant.cost_usd)}</span>}
        </>
      );
    }
    case "execute_tool": {
      const rollup = toolRollupFor(span, ctx.trace).rollup;
      return rollup?.mud_calls != null
        ? <span className="task-group-meta">{rollup.mud_calls} MUD call{rollup.mud_calls === 1 ? "" : "s"}</span>
        : null;
    }
    case "hook": {
      const calls = collectToolEntries(span, ctx.trace, ctx.entriesBySeq);
      const failed = calls.filter((e) => e.tool_ok === false).length;
      return (
        <>
          {calls.length > 0 && <span className="auto-summary-tools">{tallyTools(calls)}</span>}
          {failed > 0 && <span className="tool-badge">{failed} failed</span>}
        </>
      );
    }
    default:
      return null;
  }
}

function TechnicalDetails({ span, ctx }: { span: SessionSpan; ctx: RenderCtx }) {
  const events = span.direct_entry_seqs
    .map((seq) => ctx.entriesBySeq.get(seq))
    .filter((e): e is Entry => e != null);

  return (
    <details className="span-technical-details">
      <summary>Technical details</summary>
      <dl className="span-overview">
        <dt>Task</dt><dd>{span.task ?? "—"}</dd>
        <dt>Initiator</dt><dd>{span.initiator ?? "—"}</dd>
        <dt>Trigger</dt><dd>{span.trigger ?? "—"}</dd>
        <dt>Operation ID</dt><dd><code>{span.id}</code></dd>
        <dt>Trace / span</dt><dd><code>{span.trace_id ?? "—"} / {span.span_id ?? "—"}</code></dd>
        <dt>Self time</dt><dd>{fmtDelta(span.self_ms, ctx.coarse)}</dd>
      </dl>
      {events.length > 0 && (
        <>
          <h4>Events</h4>
          {events.map((entry) => (
            <details className="span-event" key={entry.seq}>
              <summary>#{entry.seq} · {entry.type}</summary>
              <pre>{JSON.stringify(entry, null, 2)}</pre>
            </details>
          ))}
        </>
      )}
      <details>
        <summary>Raw span metadata</summary>
        <pre>{JSON.stringify({ attributes: span.attributes, rollup: span.rollup }, null, 2)}</pre>
      </details>
    </details>
  );
}

function SpanSection({ span, depth, ctx }: { span: SessionSpan; depth: number; ctx: RenderCtx }) {
  const expanded = ctx.expanded.has(span.id);
  const left = ((span.start_mono_ms ?? ctx.origin) - ctx.origin) / ctx.total * 100;
  const width = ((span.duration_ms ?? 0) / ctx.total) * 100;
  const hasChildren = span.timeline.some((item) => item.kind === "span") || span.semantic_kind === "hook";

  return (
    <div id={`span-${span.id}`} className={span.id === ctx.selectedId ? "story-section story-selected" : "story-section"}>
      <div className="trace-row" role="treeitem" aria-level={depth + 1} aria-expanded={hasChildren ? expanded : undefined}>
        <button
          className="trace-label"
          style={{ paddingLeft: `${depth * 16 + 8}px` }}
          onClick={() => ctx.onSelect(span.id)}
        >
          <span className={`span-status status-${span.status}`}>{KIND_ICON[span.semantic_kind]}</span>
          {hasChildren && (
            <span onClick={(e) => { e.stopPropagation(); ctx.toggle(span.id); }}>
              {expanded ? "▾" : "▸"}
            </span>
          )}
          <span className="story-title"><SpanHeaderTitle span={span} ctx={ctx} /></span>
          <SpanBadges span={span} ctx={ctx} />
          {span.status === "incomplete" && (
            <span className="task-group-incomplete" title="no operation_end — the run ended mid-operation">incomplete</span>
          )}
          {span.status === "running" && <span className="task-group-meta" title="still running">running</span>}
        </button>
        <button className="trace-track" onClick={() => ctx.onSelect(span.id)}
                aria-label={`${operationLabel(span.name, span.semantic_kind)}, ${span.status}, ${fmtDuration(span.duration_ms)}`}>
          <span className={`trace-bar kind-${span.semantic_kind}`} style={{ left: `${left}%`, width: `${width}%` }} />
          {width < .35 && <span className="trace-marker" style={{ left: `${left}%` }} />}
        </button>
        <span className="trace-duration">{fmtDuration(span.duration_ms)}</span>
      </div>

      {expanded && (
        <div className="story-body">
          <SpanBody span={span} depth={depth} ctx={ctx} />
          <TechnicalDetails span={span} ctx={ctx} />
        </div>
      )}
    </div>
  );
}

function SpanBody({ span, depth, ctx }: { span: SessionSpan; depth: number; ctx: RenderCtx }) {
  if (span.semantic_kind === "execute_tool") {
    const toolEntry = findEntry(span, ctx.entriesBySeq, "tool");
    if (toolEntry) {
      // Extra children beyond the tool call itself and its `after_tool`
      // reaction (a delegated task, say) still render generically below.
      const extra = span.timeline.filter((item) => {
        if (item.kind === "entry") return item.seq !== toolEntry.seq;
        return ctx.trace.spans[item.id]?.semantic_kind !== "after_tool";
      });
      return (
        <>
          <ToolCard entry={toolEntry} rollup={toolRollupFor(span, ctx.trace)} coarse={ctx.coarse} />
          {extra.map((item) => <TimelineItemView key={itemKey(item)} item={item} parent={span} depth={depth} ctx={ctx} />)}
        </>
      );
    }
  }

  if (span.semantic_kind === "state") {
    const rollup = span.rollup ?? {};
    if (rollup.db_writes == null && rollup.db_reads == null) return null;
    return (
      <div className="op-rollup">
        <span className="op-rollup-icon">⛁</span>
        <span>wrote {rollup.db_writes ?? 0}</span>
        <span>· read {rollup.db_reads ?? 0}</span>
      </div>
    );
  }

  return (
    <>
      {span.timeline.map((item) => <TimelineItemView key={itemKey(item)} item={item} parent={span} depth={depth} ctx={ctx} />)}
    </>
  );
}

function itemKey(item: { kind: string; seq?: number; id?: string }) {
  return item.kind === "entry" ? `entry-${item.seq}` : `span-${item.id}`;
}

function TimelineItemView({
  item, parent, depth, ctx,
}: {
  item: { kind: "entry"; seq: number } | { kind: "span"; id: string };
  parent: SessionSpan;
  depth: number;
  ctx: RenderCtx;
}) {
  if (item.kind === "entry") {
    const entry = ctx.entriesBySeq.get(item.seq);
    if (!entry) return null;
    if (entry.type === "local_inference") return <LocalInferenceRow entry={entry} coarse={ctx.coarse} />;

    const modelMs = parent.semantic_kind === "chat"
      ? (typeof parent.attributes?.["boukensha.wire_ms"] === "number"
          ? (parent.attributes["boukensha.wire_ms"] as number)
          : parent.duration_ms)
      : null;
    const turnDurationMs = entry.type === "turn_end" ? ctx.turnDurationByTurn.get(entry.turn) ?? null : null;

    return (
      <EntryCard
        entry={entry}
        contextWindow={ctx.contextWindow}
        maxTurnTokens={ctx.maxTurnTokens}
        onOpenRequest={ctx.onOpenRequest}
        coarse={ctx.coarse}
        modelMs={modelMs}
        turnDurationMs={turnDurationMs}
      />
    );
  }

  const child = ctx.trace.spans[item.id];
  if (!child) return null;
  if (child.semantic_kind === "after_tool") return null; // merged into the tool card above it

  // "execute_tool, initiator: hook" folds into the parent hook's summary row
  // rather than drawing its own caret/expand controls — being automatic work
  // one level deep must not look like a second unit of work.
  if ((parent.semantic_kind === "hook" || parent.semantic_kind === "internal") &&
      child.semantic_kind === "execute_tool" && child.initiator === "hook") {
    const toolEntry = findEntry(child, ctx.entriesBySeq, "tool");
    if (toolEntry) {
      return (
        <>
          <div className="auto-entry-op">
            <span className="op-rollup-icon">⚙</span> {shortToolName(toolEntry)}
            {child.duration_ms != null && <span className="task-group-meta"> · {fmtDelta(child.duration_ms, ctx.coarse)}</span>}
          </div>
          <ToolCard entry={toolEntry} coarse={ctx.coarse} />
        </>
      );
    }
  }

  return <SpanSection span={child} depth={depth + 1} ctx={ctx} />;
}
