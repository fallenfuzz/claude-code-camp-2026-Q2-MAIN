import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router";
import { ApiRequestError, fetchSession } from "../api/client";
import type {
  AutomaticOperation,
  Entry,
  SessionDetail as SessionDetailData,
  SessionSummary,
  TimingSummary,
} from "../api/types";
import { useEventStream } from "../api/useEventStream";
import CostTable from "../components/CostTable";
import Duration from "../components/Duration";
import LiveBadge from "../components/LiveBadge";
import MessagesSidebar from "../components/MessagesSidebar";
import ProgressBar from "../components/ProgressBar";
import Sparkline from "../components/Sparkline";
import TaskChip, { taskHue } from "../components/TaskChip";
import AutomaticSummary from "../components/transcript/AutomaticSummary";
import EntryCard from "../components/transcript/EntryCard";
import IterationMarker from "../components/transcript/IterationMarker";
import LocalInferenceRow from "../components/transcript/LocalInferenceRow";
import StoreRollup from "../components/transcript/StoreRollup";
import { shortToolName, tallyTools, ToolCard } from "../components/transcript/ToolCard";
import { flattenNode as flatten, toolsIn } from "../components/transcript/types";
import type { AutoNode, GroupNode, OpenNode, OpNode, ToolRollupInfo, TranscriptNode } from "../components/transcript/types";
import { fmtCost, fmtDelta, fmtDuration, fmtTokens, formatTime, pct, pctRaw } from "../format";
import { isFrameworkSpan, isModelSpan, isToolSpan, isTurnSpan, operationLabel } from "../spans";

const AT_BOTTOM_THRESHOLD_PX = 80;

function isWindowAtBottom() {
  const doc = document.documentElement;
  return doc.scrollHeight - doc.scrollTop - doc.clientHeight < AT_BOTTOM_THRESHOLD_PX;
}

// Port of week1_baseline/log_viz/views/session.erb.
export default function SessionDetail() {
  const { id } = useParams<{ id: string }>();
  const [searchParams, setSearchParams] = useSearchParams();
  const [data, setData] = useState<SessionDetailData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [liveSummary, setLiveSummary] = useState<SessionSummary | null>(null);
  const [newestSeq, setNewestSeq] = useState<number | null>(null);
  // Which request's payload the sidebar is showing (1-based request ordinal),
  // or null when the drawer is closed. Set by the inline buttons in the transcript.
  const [focusedRequest, setFocusedRequest] = useState<number | null>(null);
  // Set by the `?op=` resolution effect below; consumed by the scroll effect
  // once the anchor entry exists in the DOM.
  const [scrollToSeq, setScrollToSeq] = useState<number | null>(null);
  const stickToBottomRef = useRef(true);

  useEffect(() => {
    if (!id) return;
    setData(null);
    setError(null);
    setEntries([]);
    setLiveSummary(null);
    setNewestSeq(null);
    setFocusedRequest(null);
    fetchSession(id)
      .then((detail) => {
        setData(detail);
        setEntries(detail.entries);
      })
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, [id]);

  const handleEntry = useCallback((entry: Entry) => {
    stickToBottomRef.current = isWindowAtBottom();
    setEntries((prev) => (prev.some((e) => e.seq === entry.seq) ? prev : [ ...prev, entry ]));
    setNewestSeq(entry.seq);
  }, []);

  const streamStatus = useEventStream<Entry>({
    streamKey: id,
    buildUrl: (afterSeq) => `/api/v1/sessions/${encodeURIComponent(id ?? "")}/stream?after=${afterSeq}`,
    enabled: Boolean(data?.session.live),
    initialAfterSeq: data?.entries.at(-1)?.seq ?? 0,
    onEntry: handleEntry,
    onSummary: setLiveSummary,
  });

  useEffect(() => {
    if (stickToBottomRef.current) {
      window.scrollTo({ top: document.documentElement.scrollHeight });
    }
  }, [entries]);

  // The Manager page's `correlation: exact` link (instrumentation.md §12)
  // lands here with `?op=<operation_id>` — cross-log navigation from a raw
  // telnet byte count to the operation that caused it. Consumed once entries
  // arrive (the query param names a span, not a seq, since the Manager page
  // never sees the transcript's own numbering) and then cleared, so a reload
  // of the same URL doesn't keep re-scrolling.
  useEffect(() => {
    const op = searchParams.get("op");
    if (!op || entries.length === 0) return;

    const start = entries.find((e) => e.type === "operation_start" && e.operation_id === op);
    if (start) setScrollToSeq(start.seq);
    const next = new URLSearchParams(searchParams);
    next.delete("op");
    setSearchParams(next, { replace: true });
  }, [entries, searchParams, setSearchParams]);

  // `operation_start`/`operation_end` (and `task_start`/`task_end`) never
  // render their own row — they become tree structure, not content — so a
  // span's anchor seq may have no matching element; fall back to the nearest
  // rendered entry at or after it.
  useEffect(() => {
    if (scrollToSeq == null) return;
    let el = document.getElementById(`entry-${scrollToSeq}`);
    if (!el) {
      const candidate = Array.from(document.querySelectorAll("[id^='entry-']"))
        .map((node) => ({ node, seq: Number(node.id.slice("entry-".length)) }))
        .filter((c) => !Number.isNaN(c.seq) && c.seq >= scrollToSeq)
        .sort((a, b) => a.seq - b.seq)[0];
      el = (candidate?.node as HTMLElement | undefined) ?? null;
    }
    el?.scrollIntoView({ block: "center" });
    setScrollToSeq(null);
  }, [scrollToSeq, entries]);

  if (error) {
    return (
      <>
        <Link to="/sessions" className="back">
          ← All sessions
        </Link>
        <p className="error">Failed to load session: {error}</p>
      </>
    );
  }

  if (!data) return <p>Loading…</p>;

  const session = liveSummary ?? data.session;
  const { snapshot, turns, usage_series: usageSeries, cost_breakdown: costBreakdown } = data;
  const largestTurn = turns.length ? turns.reduce((a, b) => (b.tokens > a.tokens ? b : a)) : null;
  const busiestTurn = turns.length
    ? turns.reduce((a, b) => ((b.iterations ?? 0) > (a.iterations ?? 0) ? b : a))
    : null;
  const anyLimitTripped = turns.some((t) => t.reason != null && t.reason !== "completed");
  const largestTripped = turns.some((t) => t.reason === "max_tokens");

  return (
    <div className="session-detail-page">
      <div className="session-page-head">
        <Link to="/sessions" className="session-back" aria-label="All sessions">← Sessions</Link>
        <h1>
          <span className="session-heading-label">Session</span> {session.id}
          {data.session.live && <LiveBadge status={streamStatus} />}
        </h1>
      </div>

      <p className="meta">
        Started {formatTime(session.started_at)}
        {" · "}
        {/* Live sessions are still accumulating, so the figure is "so far",
            not a final total — say so rather than letting it read as finished. */}
        <span
          className="session-duration"
          title={
            session.timing.busy_ms == null
              ? undefined
              : `${fmtDuration(session.timing.busy_ms)} busy · ${fmtDuration(session.timing.total_idle_ms)} idle`
          }
        >
          {data.session.live ? "running " : ""}
          {fmtDuration(session.duration_ms)}
          {data.session.live ? " so far" : ""}
        </span>
        {session.tasks.length > 0 && (
          <span className="task-roster">
            {session.tasks.map((t) => (
              <TaskChip key={t} task={t} />
            ))}
            {session.sub_runs > 0 && (
              <span className="sub-run-count" title="delegated sub-runs">
                ⑂ {session.sub_runs}
              </span>
            )}
          </span>
        )}
      </p>

      {/* "What is it doing right now" — answerable without reading the transcript. */}
      {data.session.live && entries.length > 0 && entries[entries.length - 1].task && (
        <p className="meta running-task">
          running <TaskChip task={entries[entries.length - 1].task} />
        </p>
      )}

      {session.end_reason &&
        (session.stopped ? (
          <div className="banner banner-warn">⚠ stopped: {session.end_reason}</div>
        ) : (
          <div className="banner banner-ok">✓ completed</div>
        ))}

      <div className="statstrip">
        <div className="statstrip-head">
          <span className="statstrip-model">{session.models.join(", ") || "—"}</span>
          <span className="statstrip-cost">
            cost ≈ {session.cost_usd == null ? "—" : `$${session.cost_usd.toFixed(4)}`}
          </span>
        </div>

        {snapshot.context_window != null && snapshot.context_window > 0 && (
          <ProgressBar
            used={session.peak_input_tokens}
            max={snapshot.context_window}
            label={`Peak context · ${fmtTokens(session.peak_input_tokens)} / ${fmtTokens(snapshot.context_window)} (${pct(session.peak_input_tokens, snapshot.context_window)}%)`}
          />
        )}

        {snapshot.max_turn_tokens != null && snapshot.max_turn_tokens > 0 && largestTurn && (
          <ProgressBar
            used={largestTurn.tokens}
            max={snapshot.max_turn_tokens}
            danger={largestTripped}
            label={`Largest turn · ${fmtTokens(largestTurn.tokens)} / ${fmtTokens(snapshot.max_turn_tokens)} (${pctRaw(largestTurn.tokens, snapshot.max_turn_tokens)}%${largestTripped ? " ⚠ max_tokens" : ""})`}
          />
        )}

        {snapshot.max_iterations != null && busiestTurn && (
          <ProgressBar
            used={busiestTurn.iterations}
            max={snapshot.max_iterations}
            danger={anyLimitTripped && busiestTurn.reason === "max_iterations"}
            label={`Iterations · ${busiestTurn.iterations} / ${snapshot.max_iterations} (turn ${busiestTurn.n})`}
          />
        )}

        <div className="statstrip-total">
          Session total: {fmtTokens(session.input_tokens)} tok in · {fmtTokens(session.output_tokens)} tok out ·
          across {session.turns} turn{session.turns === 1 ? "" : "s"} · {fmtDuration(session.duration_ms)} total
        </div>

        {/* One tool count let a hook's score, look and eight empty polls make
            the model look far more tool-hungry than it was. A log with no
            provenance cannot make the split, and says so by omission. */}
        <div className="statstrip-total">
          Tools: {session.tool_calls} total
          {session.has_provenance && (
            <>
              {" · "}
              {session.model_tool_calls} model
              {" · "}
              <span title="score / look / poll / room survey — work the hooks did on the model's behalf">
                {session.automatic_tool_calls} automatic
                {session.automatic_tool_ms != null && <> ({fmtDuration(session.automatic_tool_ms)})</>}
              </span>
            </>
          )}
        </div>

        {/* Dollars are not the only currency a session spends. "N operations"
            was always a proxy for "did we instrument anything" — has_operations
            already answers that — and it got LESS meaningful the moment spans
            wrapped every iteration and tool call (§0: 49 → ~150 on the sampled
            session). The three magnitudes below are the actual question: where
            did the wall-clock time go. */}
        {session.has_operations && (
          <div className="statstrip-total hero-tiles">
            <span className="hero-tile" title="sum of measured llm.generate span durations">
              🧠 {fmtDuration(session.timing.model_ms)} inference
            </span>
            <span className="hero-tile" title="MUD round trips, summed over root spans">
              ⚙ {fmtDuration(session.mud_ms)} MUD
            </span>
            <span className="hero-tile" title="db_ms summed over root spans">
              ⛁ {fmtDuration(session.db_ms)} memory
            </span>
            {" · "}
            <span title="rows written and read by the store, summed over root spans">
              {session.db_writes} written · {session.db_reads} read
            </span>
            {session.journal_lines > 0 && <> · {session.journal_lines} journal lines</>}
            {session.inference_ms > 0 && <> · ◆ {fmtDuration(session.inference_ms)} local inference</>}
            {session.unclosed_operations > 0 && (
              <span className={session.live ? "task-group-meta" : "task-group-incomplete"}
                    title={session.live ? "still running" : "the process ended mid-operation"}>
                {session.unclosed_operations} {session.live ? "running" : "incomplete"}
              </span>
            )}
          </div>
        )}
      </div>

      {session.has_provenance && session.automatic_operations.length > 0 && (
        <AutomaticWorkTable rows={session.automatic_operations} timing={session.timing} />
      )}

      <CostTable rows={costBreakdown} />

      {usageSeries.length > 1 && (
        <div className="spark-wrap">
          <div className="spark-label">input tokens / iteration · peak {fmtTokens(session.peak_input_tokens)}</div>
          <Sparkline points={usageSeries} max={session.peak_input_tokens} />
        </div>
      )}

      <div className="transcript">
        <TranscriptEntries entries={entries} snapshot={snapshot} timingSource={session.timing_source}
          newestSeq={newestSeq} live={session.live} onOpenRequest={setFocusedRequest} />
      </div>

      {focusedRequest != null && id && (
        <MessagesSidebar id={id} focusSeq={focusedRequest} onClose={() => setFocusedRequest(null)} />
      )}
    </div>
  );
}

function isAutomatic(entry: Entry): boolean {
  return (entry.type === "tool" && entry.initiator === "hook") || entry.type === "local_inference";
}

// Entries arrive flat and ordered — cursors, SSE replay and dropped-strip
// interleaving all depend on that (§A.4). Nesting is a rendering concern, so
// the tree is built here, at render time.
//
// Two mechanisms, and the difference matters. `task_start`/`task_end` and
// `operation_start`/`operation_end` are RECORDED containment: a span says what
// it contains and names its parent, so `room survey` lands inside `establish
// position` because that is where it ran. The adjacency fold underneath is the
// legacy path for files written before spans existed; it approximates
// containment with proximity, which splits one operation in two the moment a
// model call lands in the middle of it. New logs never reach it.
export function buildTranscriptTree(entries: Entry[]): TranscriptNode[] {
  const root: TranscriptNode[] = [];
  const open: OpenNode[] = [];
  const target = () => (open.length ? open[open.length - 1].children : root);
  const insideOperation = () => open.some((n) => n.kind === "op");
  // Whether a HOOK span (position_refresh, room_survey, …) is on the open
  // stack — as opposed to a FRAMEWORK span (turn, iteration, tool.<name>, …),
  // which now wraps everything once instrumentation is on and must not gate
  // this: if it did, no hook span would ever be absorbed into "Automatic
  // context work" again, because something framework-shaped is always open.
  const insideHookOperation = () =>
    open.some((n) => n.kind === "op" && !isFrameworkSpan(n.start.operation));

  // Automatic work sits under one muted heading rather than competing with the
  // model's actions. With spans, the things folded together are whole
  // operations; without them, a run of individual hook calls.
  const absorb = (node: TranscriptNode) => {
    const siblings = target();
    const last = siblings[siblings.length - 1];
    if (last?.kind === "auto") last.children.push(node);
    else siblings.push({ kind: "auto", children: [ node ] });
  };

  // A FRAMEWORK span is transparent spine content by construction — it always
  // goes wherever the current context's spine content goes, never absorbed. A
  // HOOK span inside another hook span nests there (unchanged); a hook span at
  // the top level of its context (no other HOOK span open — a framework span
  // does not count) joins the automatic-work heading, because it is the
  // outermost unit of automatic work there.
  const place = (node: OpNode) => {
    if (isFrameworkSpan(node.start.operation)) {
      target().push(node);
      return;
    }
    if (insideHookOperation()) target().push(node);
    else absorb(node);
  };

  for (const entry of entries) {
    if (entry.type === "task_start") {
      const group: GroupNode = { kind: "group", start: entry, end: null, children: [] };
      target().push(group);
      open.push(group);
    } else if (entry.type === "task_end") {
      const group = closeOpen(open, "group");
      // A task_end with nothing open is a malformed log, not a reason to drop
      // the record on the floor — render it where it sits.
      if (group) group.end = entry;
      else target().push({ kind: "entry", entry });
    } else if (entry.type === "operation_start") {
      const node: OpNode = { kind: "op", start: entry, end: null, children: [] };
      place(node);
      open.push(node);
    } else if (entry.type === "operation_end") {
      // Matched by ID, not by position. A span whose `operation_end` was lost
      // to a truncated write would otherwise close the WRONG span and reparent
      // everything after it; unwinding to the matching id leaves the orphans
      // rendered as incomplete, which is what they are.
      const node = closeOpen(open, "op", entry.operation_id);
      if (node) node.end = entry;
      else target().push({ kind: "entry", entry });
    } else if (insideOperation()) {
      // Inside a span, the span IS the grouping. Its calls are its children.
      target().push({ kind: "entry", entry });
    } else if (isAutomatic(entry)) {
      absorb({ kind: "entry", entry });
    } else {
      target().push({ kind: "entry", entry });
    }
  }

  // Anything still open at EOF closes here with a null `end`; the missing
  // bracket is what the header reports as "incomplete" rather than implying a
  // clean finish.
  return root;
}

// Unwind the open stack to the node this closing event belongs to, abandoning
// anything above it (those spans never got their own close and stay incomplete).
// Returns null when there is no match at all.
function closeOpen<K extends OpenNode["kind"]>(
  open: OpenNode[],
  kind: K,
  operationId?: string | null,
): Extract<OpenNode, { kind: K }> | null {
  for (let i = open.length - 1; i >= 0; i--) {
    const node = open[i];
    if (node.kind !== kind) continue;
    if (kind === "op" && operationId && node.kind === "op" && node.start.operation_id !== operationId) continue;
    open.length = i;
    return node as Extract<OpenNode, { kind: K }>;
  }
  return null;
}

// Iteration counters restart inside a sub-run, so the marker is decided on the
// flat list (where "the previous entry" is unambiguous) and looked up during
// the recursive render.
function iterationMarkerSeqs(entries: Entry[]): Set<number> {
  const seqs = new Set<number>();
  let lastIteration: number | null = null;
  let lastDepth: number | null = null;

  for (const entry of entries) {
    if (entry.type === "turn_end") continue;
    // Automatic calls are rendered inside their group, which never draws a
    // marker — anchoring one to them would simply lose it. The marker belongs
    // on the first entry of the iteration the reader can actually see. Span
    // brackets are the same case: they are a collapsible heading, not a line.
    if (isAutomatic(entry) || entry.type === "operation_start" || entry.type === "operation_end") continue;
    if (entry.iteration !== lastIteration || entry.depth !== lastDepth) {
      if (entry.type !== "task_start" && entry.type !== "task_end") seqs.add(entry.seq);
      lastIteration = entry.iteration;
      lastDepth = entry.depth;
    }
  }
  return seqs;
}

// A transparent span (§9) draws no box, so its own summary — duration, MUD
// calls, tokens — has to reach whatever EXISTING chrome the reader already
// looks at instead. Built once per render, off the flat entries list rather
// than the tree, because every one of these is a lookup keyed by an id or a
// number, not a containment question.
interface RollupIndex {
  /** operation_end entries keyed by operation_id. */
  endsById: Map<string, Entry>;
  /** operation_start entries keyed by operation_id — gives the span's name
   *  and parent, which the end event alone does not carry. */
  startsById: Map<string, Entry>;
  /** The `iteration` span's operation_end, keyed by iteration number. */
  iterationSpans: Map<number, Entry>;
  /** The `turn` span's operation_end, keyed by turn number. */
  turnSpans: Map<number, Entry>;
  /**
   * The `llm.generate` span's operation_end, keyed by the seq of the
   * `assistant` entry it measured. Sequential pairing (the next assistant
   * entry after the span closes) rather than by iteration number: wrap_up's
   * own `llm.generate` carries the LAST real iteration's number (no new
   * `iteration` marker fires during wind-down), which would collide.
   */
  llmLatencyByAssistantSeq: Map<number, Entry>;
  /** Summed `assistant` cost_usd per iteration — the iteration marker's cost
   *  figure, since cost is set by `frame.set` and so is not itself a counter
   *  that rolls up through the iteration span automatically. */
  iterationCostUsd: Map<number, number>;
}

export function buildRollupIndex(entries: Entry[]): RollupIndex {
  const endsById = new Map<string, Entry>();
  const startsById = new Map<string, Entry>();
  const iterationSpans = new Map<number, Entry>();
  const turnSpans = new Map<number, Entry>();
  const llmLatencyByAssistantSeq = new Map<number, Entry>();
  const iterationCostUsd = new Map<number, number>();
  let pendingLlm: Entry | null = null;

  for (const e of entries) {
    if (e.type === "operation_start" && e.operation_id) {
      startsById.set(e.operation_id, e);
    } else if (e.type === "operation_end" && e.operation_id) {
      endsById.set(e.operation_id, e);
      if (e.operation === "iteration") iterationSpans.set(e.iteration, e);
      if (isTurnSpan(e.operation)) turnSpans.set(e.turn, e);
      if (isModelSpan(e.operation)) pendingLlm = e;
    } else if (e.type === "assistant") {
      if (pendingLlm) {
        llmLatencyByAssistantSeq.set(e.seq, pendingLlm);
        pendingLlm = null;
      }
      if (e.cost_usd != null) {
        iterationCostUsd.set(e.iteration, (iterationCostUsd.get(e.iteration) ?? 0) + e.cost_usd);
      }
    }
  }

  return { endsById, startsById, iterationSpans, turnSpans, llmLatencyByAssistantSeq, iterationCostUsd };
}

// The tool.<name> span's own rollup, merged with its after_tool child's (the
// framework's downstream store/journal writes) — one footer on the ToolCard,
// never two, because after_tool draws no box of its own (§10).
export function toolSpanRollup(
  entry: Entry,
  idx: RollupIndex,
): ToolRollupInfo | null {
  if (!entry.operation_id) return null;
  const span = idx.startsById.get(entry.operation_id);
  if (!isToolSpan(span?.operation)) return null;

  const end = idx.endsById.get(entry.operation_id);
  const rollup: Record<string, number> = { ...(end?.rollup ?? {}) };
  let afterToolOperationId: string | null = null;

  for (const start of idx.startsById.values()) {
    if (start.parent_operation_id !== entry.operation_id || start.operation !== "after_tool") continue;
    afterToolOperationId = start.operation_id ?? null;
    const childEnd = start.operation_id ? idx.endsById.get(start.operation_id) : undefined;
    for (const [ key, value ] of Object.entries(childEnd?.rollup ?? {})) {
      rollup[key] = (rollup[key] ?? 0) + value;
    }
  }

  return {
    durationMs: end?.duration_ms ?? null,
    rollup: Object.keys(rollup).length ? rollup : null,
    afterToolOperationId,
  };
}

// Collapse sub-runs by default once there are more than a couple: the player's
// narrative is the spine, and a sub-run is detail you open when a room looks
// wrong.
const COLLAPSE_THRESHOLD = 2;

function TranscriptEntries({
  entries,
  snapshot,
  timingSource,
  newestSeq,
  live,
  onOpenRequest,
}: {
  entries: Entry[];
  snapshot: SessionDetailData["snapshot"];
  timingSource: SessionDetailData["session"]["timing_source"];
  newestSeq: number | null;
  live: boolean;
  onOpenRequest: (requestSeq: number) => void;
}) {
  const nodes = buildTranscriptTree(entries);
  const markers = iterationMarkerSeqs(entries);
  const rollups = buildRollupIndex(entries);
  const subRuns = entries.filter((e) => e.type === "task_start").length;

  return (
    <TranscriptNodes
      nodes={nodes}
      snapshot={snapshot}
      coarse={timingSource === "wallclock_coarse"}
      newestSeq={newestSeq}
      markers={markers}
      rollups={rollups}
      live={live}
      defaultOpen={subRuns <= COLLAPSE_THRESHOLD}
      onOpenRequest={onOpenRequest}
    />
  );
}

interface NodeProps {
  snapshot: SessionDetailData["snapshot"];
  coarse: boolean;
  newestSeq: number | null;
  markers: Set<number>;
  rollups: RollupIndex;
  /** A span/task with no closing event reads as "incomplete" — the process
   *  died mid-flight — except during a live session, where an open span is
   *  simply still running. Gating on this is the difference between the page
   *  saying the process crashed and saying it is working (instrumentation.md
   *  §13). */
  live: boolean;
  defaultOpen: boolean;
  onOpenRequest: (requestSeq: number) => void;
}

// The first event under an automatic heading, whichever kind of child holds it.
function autoKey(node: AutoNode): number {
  const first = node.children[0];
  if (!first) return 0;
  return first.kind === "entry" ? first.entry.seq : flatten(first)[0]?.seq ?? 0;
}

function TranscriptNodes({ nodes, ...props }: NodeProps & { nodes: TranscriptNode[] }) {
  return (
    <>
      {nodes.map((node) =>
        node.kind === "auto" ? (
          <AutomaticGroup key={`auto-${autoKey(node)}`} node={node} {...props} />
        ) : node.kind === "op" ? (
          isFrameworkSpan(node.start.operation) ? (
            // Transparent: draws no box of its own. Its children render at
            // exactly the indent its parent's other children do — the span's
            // OWN summary surfaces on existing chrome instead (the iteration
            // marker, the CtxChip, the ToolCard footer, the turn strip).
            <TranscriptNodes key={`opspine-${node.start.seq}`} nodes={node.children} {...props} />
          ) : (
            <OperationGroup key={`op-${node.start.seq}`} node={node} {...props} />
          )
        ) : node.kind === "group" ? (
          <TaskGroup key={`group-${node.start.seq}`} node={node} {...props} />
        ) : node.entry.type === "local_inference" ? (
          // A summary of the span, not a step in its narrative.
          <LocalInferenceRow key={node.entry.seq} entry={node.entry} coarse={props.coarse} />
        ) : (
          <Fragment key={node.entry.seq}>
            {props.markers.has(node.entry.seq) && (
              <IterationMarker
                iteration={node.entry.iteration}
                durationMs={props.rollups.iterationSpans.get(node.entry.iteration)?.duration_ms ?? null}
                mudCalls={props.rollups.iterationSpans.get(node.entry.iteration)?.rollup?.mud_calls}
                costUsd={props.rollups.iterationCostUsd.get(node.entry.iteration)}
                coarse={props.coarse}
              />
            )}
            <div
              id={`entry-${node.entry.seq}`}
              className={node.entry.seq === props.newestSeq ? "entry-row entry-row-new" : "entry-row"}
            >
              <div className="entry-gutter-row">
                <Duration
                  at={node.entry.at}
                  dtMs={node.entry.dt_ms}
                  durationMs={node.entry.duration_ms}
                  coarse={props.coarse}
                />
                <TaskChip task={node.entry.task} />
              </div>
              <EntryCard
                entry={node.entry}
                contextWindow={props.snapshot.context_window}
                maxTurnTokens={props.snapshot.max_turn_tokens}
                onOpenRequest={props.onOpenRequest}
                toolRollup={node.entry.type === "tool" ? toolSpanRollup(node.entry, props.rollups) : undefined}
                modelMs={props.rollups.llmLatencyByAssistantSeq.get(node.entry.seq)?.duration_ms ?? null}
                turnDurationMs={props.rollups.turnSpans.get(node.entry.turn)?.duration_ms ?? null}
                coarse={props.coarse}
              />
            </div>
          </Fragment>
        ),
      )}
    </>
  );
}

// A delegated sub-run: collapsible, indented, with a left rule down the group
// so a long sub-run's membership stays visible after its header scrolls off.
function TaskGroup({ node, ...props }: NodeProps & { node: GroupNode }) {
  const name = node.start.task_name ?? node.start.task ?? "sub-run";
  const [open, setOpen] = useState(props.defaultOpen);

  // Live mode follows into sub-runs: an entry streaming into this group opens
  // it, so a running delegation is never hidden behind a collapsed header.
  const containsNewest =
    props.newestSeq != null && flatten(node).some((e) => e.seq === props.newestSeq);
  const expanded = open || containsNewest;

  const inner = flatten(node);
  const cost = inner.reduce((sum, e) => sum + (e.cost_usd ?? 0), 0);
  const iterations = inner.reduce((max, e) => Math.max(max, e.iteration ?? 0), 0);
  const incomplete = node.end == null;

  return (
    <div className="task-group" style={{ borderLeftColor: `hsl(${taskHue(name)} 45% 55% / 0.55)` }}>
      <button
        type="button"
        className="task-group-head"
        aria-expanded={expanded}
        onClick={() => setOpen(!expanded)}
      >
        <span className="task-group-caret">{expanded ? "▾" : "▸"}</span>
        <TaskChip task={name} />
        {node.start.model && <span className="task-group-meta">{node.start.model}</span>}
        {node.start.max_iterations != null && (
          <span className="task-group-meta">{node.start.max_iterations} iterations max</span>
        )}
        <span className="task-group-spacer" />
        {node.end?.duration_ms != null && (
          <span className="task-group-meta">{fmtDelta(node.end.duration_ms, props.coarse)}</span>
        )}
        {iterations > 0 && <span className="task-group-meta">{iterations} iter</span>}
        {cost > 0 && <span className="task-group-meta">{fmtCost(cost)}</span>}
        {incomplete && (
          props.live ? (
            <span className="task-group-meta" title="still running">running</span>
          ) : (
            <span className="task-group-incomplete" title="no task_end — the run ended mid-delegation">
              incomplete
            </span>
          )
        )}
      </button>

      {expanded && (
        <div className="task-group-body">
          <TranscriptNodes nodes={node.children} {...props} />
        </div>
      )}
    </div>
  );
}

function isEmptyResult(entry: Entry) {
  return !entry.tool_result?.trim();
}

// Work the framework did on the model's behalf: the cold-start `score` and
// `look`, the first-visit room survey, the poll before each dispatch. None of
// it was chosen by the model, and rendering it as ordinary tool cards is what
// made a 1.9s blocking MUD read look like model latency next to Iteration 0.
//
// Collapsed by default and summarised by operation. Two things are never
// hidden: a call that failed, and a poll that actually returned something —
// those are the ones worth reading, and the group opens itself for them.
// A call that failed, or a poll that actually returned something. Being nested
// must never make something harder to notice than being flat did, so these
// force every ancestor open.
function isNotable(entry: Entry): boolean {
  return entry.tool_ok === false || (entry.operation === "async_poll" && !isEmptyResult(entry));
}

function AutomaticGroup({ node, ...props }: NodeProps & { node: AutoNode }) {
  const entries = flatten(node);
  const calls = toolsIn(node);
  const notable = entries.filter(isNotable);
  const [open, setOpen] = useState(false);
  const containsNewest = props.newestSeq != null && entries.some((e) => e.seq === props.newestSeq);
  const expanded = open || containsNewest || notable.length > 0;

  const totalMs = calls.reduce((sum, e) => sum + (e.duration_ms ?? 0), 0);
  const failed = calls.filter((e) => e.tool_ok === false).length;
  const spans = node.children.filter((c) => c.kind === "op").length;

  return (
    <div className={failed ? "auto-group auto-group-failed" : "auto-group"}>
      <button type="button" className="auto-group-head" aria-expanded={expanded} onClick={() => setOpen(!expanded)}>
        <span className="task-group-caret">{expanded ? "▾" : "▸"}</span>
        <span className="auto-group-title">Automatic context work</span>
        <span className="auto-group-count">
          {spans > 0
            ? `${spans} operation${spans === 1 ? "" : "s"}`
            : `${calls.length} call${calls.length === 1 ? "" : "s"}`}
        </span>
        <span className="task-group-spacer" />
        {failed > 0 && <span className="tool-badge">{failed} failed</span>}
        {totalMs > 0 && <span className="task-group-meta">{fmtDelta(totalMs, props.coarse)}</span>}
      </button>

      {!expanded && <AutomaticSummary node={node} coarse={props.coarse} live={props.live} />}

      {expanded && (
        <div className="task-group-body">
          <TranscriptNodes nodes={node.children} {...props} />
        </div>
      )}
    </div>
  );
}

// One operation span: what it was for, what it contained, and what it spent.
//
// The nesting here is read, not inferred — `room survey` renders inside
// `establish position` because `parent_operation_id` says it ran there. The
// previous build folded runs of ADJACENT hook calls, which put the survey's
// calls next to the position refresh's as siblings and split one operation in
// two whenever a model call landed in the middle.
function OperationGroup({ node, ...props }: NodeProps & { node: OpNode }) {
  const [open, setOpen] = useState(false);
  const entries = flatten(node);
  const calls = toolsIn(node);
  const notable = entries.filter(isNotable);
  const containsNewest = props.newestSeq != null && entries.some((e) => e.seq === props.newestSeq);
  const expanded = open || containsNewest || notable.length > 0;

  const incomplete = node.end == null;
  const failed = node.end?.ok === false || calls.some((e) => e.tool_ok === false);
  const rollup = node.end?.rollup ?? null;
  // The span's own measured duration, which includes time it spent on things
  // that are not tool calls (store reads, inference, its own arithmetic).
  const durationMs = node.end?.duration_ms ?? null;

  return (
    <div className={failed ? "op-group op-group-failed" : "op-group"}>
      <button type="button" className="op-group-head" aria-expanded={expanded} onClick={() => setOpen(!expanded)}>
        <span className="task-group-caret">{expanded ? "▾" : "▸"}</span>
        <span className="op-group-title">{operationLabel(node.start.operation)}</span>
        {calls.length > 0 && <span className="auto-summary-tools">{tallyTools(calls)}</span>}
        <span className="task-group-spacer" />
        {incomplete && (
          props.live ? (
            <span className="task-group-meta" title="still running">running</span>
          ) : (
            <span className="task-group-incomplete" title="no operation_end — the run ended mid-operation">
              incomplete
            </span>
          )
        )}
        {durationMs != null && <span className="task-group-meta">{fmtDelta(durationMs, props.coarse)}</span>}
      </button>

      {expanded && (
        <div className="task-group-body">
          {node.children.map((child) =>
            child.kind === "op" ? (
              isFrameworkSpan(child.start.operation) ? (
                <TranscriptNodes key={`opspine-${child.start.seq}`} nodes={child.children} {...props} />
              ) : (
                <OperationGroup key={`op-${child.start.seq}`} node={child} {...props} />
              )
            ) : child.kind === "entry" && child.entry.type === "local_inference" ? (
              <LocalInferenceRow key={child.entry.seq} entry={child.entry} coarse={props.coarse} />
            ) : child.kind === "entry" && child.entry.type === "tool" ? (
              <AutomaticCall key={child.entry.seq} entry={child.entry} coarse={props.coarse} />
            ) : (
              // Anything else that landed inside the span — a model action the
              // log interleaved here. It keeps its normal presentation; being
              // nested must not make it harder to read.
              <TranscriptNodes key={nodeKey(child)} nodes={[ child ]} {...props} />
            ),
          )}
          {/* Summaries OF the span, not entries in its narrative — so they
              collapse with it and sit below what they describe. */}
          <StoreRollup rollup={rollup} operationId={node.start.operation_id} coarse={props.coarse} />
        </div>
      )}
    </div>
  );
}

// One MUD round trip inside a span. Deliberately just the command and what it
// cost: the span header already says WHY, and repeating that label on each of
// four sibling calls is the redundancy spans were built to remove.
function AutomaticCall({ entry, coarse }: { entry: Entry; coarse: boolean }) {
  return (
    <>
      <div className="auto-entry-op">
        <span className="op-rollup-icon">⚙</span> {shortToolName(entry)}
        {entry.duration_ms != null && (
          <span className="task-group-meta"> · {fmtDelta(entry.duration_ms, coarse)}</span>
        )}
      </div>
      <ToolCard entry={entry} />
    </>
  );
}

function nodeKey(node: TranscriptNode): string {
  if (node.kind === "entry") return `entry-${node.entry.seq}`;
  if (node.kind === "auto") return `auto-${autoKey(node)}`;
  return `${node.kind}-${node.start.seq}`;
}

// Where the automatic time actually went, by operation. This is the table that
// answers §6's question directly: in the linked session the ~1.9 seconds is
// `bootstrap player · check(score)`, not model latency adjacent to Iteration 0.
function AutomaticWorkTable({ rows, timing }: { rows: AutomaticOperation[]; timing: TimingSummary }) {
  return (
    <table className="auto-table">
      <caption>
        Automatic context work — MUD round trips the model never asked for
        {timing.automatic_tool_ms != null && (
          <>
            {" · "}
            {fmtDuration(timing.automatic_tool_ms)} automatic
            {" vs "}
            {fmtDuration(timing.model_ms)} inference
            {timing.model_tool_ms != null && <> · {fmtDuration(timing.model_tool_ms)} model tools</>}
          </>
        )}
      </caption>
      <thead>
        <tr>
          <th scope="col">operation</th>
          <th scope="col">seam</th>
          <th scope="col">calls</th>
          <th scope="col">time</th>
          <th scope="col">empty</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.operation} className={row.failed > 0 ? "auto-table-failed" : undefined}>
            <td>{operationLabel(row.operation)}</td>
            <td className="task-group-meta">{row.trigger ?? "—"}</td>
            <td className="num">{row.calls}</td>
            <td className="num">{fmtDuration(row.duration_ms)}</td>
            {/* An empty poll is the expected case; a failure never is, and is
                never rolled into the same number. */}
            <td className="num">
              {row.empty || "—"}
              {row.failed > 0 && <span className="tool-badge"> {row.failed} failed</span>}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
