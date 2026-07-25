import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router";
import { ApiRequestError, fetchJournalForOperation, fetchSession } from "../api/client";
import type {
  AutomaticOperation,
  Entry,
  JournalRecord,
  SessionDetail as SessionDetailData,
  SessionSummary,
  TimingSummary,
} from "../api/types";
import { useEventStream } from "../api/useEventStream";
import Ansi from "../components/Ansi";
import CostTable from "../components/CostTable";
import CtxChip from "../components/CtxChip";
import Duration from "../components/Duration";
import LiveBadge from "../components/LiveBadge";
import MessagesSidebar from "../components/MessagesSidebar";
import ProgressBar from "../components/ProgressBar";
import Sparkline from "../components/Sparkline";
import TaskChip, { taskHue } from "../components/TaskChip";
import { fmtCost, fmtDelta, fmtDuration, fmtTokens, formatArgs, formatTime, pct, pctRaw } from "../format";

const AT_BOTTOM_THRESHOLD_PX = 80;

function isWindowAtBottom() {
  const doc = document.documentElement;
  return doc.scrollHeight - doc.scrollTop - doc.clientHeight < AT_BOTTOM_THRESHOLD_PX;
}

// Port of week1_baseline/log_viz/views/session.erb.
export default function SessionDetail() {
  const { id } = useParams<{ id: string }>();
  const [data, setData] = useState<SessionDetailData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [entries, setEntries] = useState<Entry[]>([]);
  const [liveSummary, setLiveSummary] = useState<SessionSummary | null>(null);
  const [newestSeq, setNewestSeq] = useState<number | null>(null);
  // Which request's payload the sidebar is showing (1-based request ordinal),
  // or null when the drawer is closed. Set by the inline buttons in the transcript.
  const [focusedRequest, setFocusedRequest] = useState<number | null>(null);
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
    <>
      <Link to="/sessions" className="back">
        ← All sessions
      </Link>

      <h1>
        Session {session.id}
        {data.session.live && <LiveBadge status={streamStatus} />}
      </h1>
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

        {/* Dollars are not the only currency a session spends. Rows written,
            rows read and inference time were all invisible until spans reported
            them, and a session that wrote nothing looks identical to one that
            wrote constantly if the only number on the page is tokens. */}
        {session.has_operations && (
          <div className="statstrip-total">
            Work: {session.operations} operation{session.operations === 1 ? "" : "s"}
            {" · "}
            <span title="rows written and read by the store, summed over root spans">
              ⛁ {session.db_writes} written · {session.db_reads} read
            </span>
            {session.journal_lines > 0 && <> · {session.journal_lines} journal lines</>}
            {session.inference_ms > 0 && <> · ◆ {fmtDuration(session.inference_ms)} local inference</>}
            {session.unclosed_operations > 0 && (
              <span className="task-group-incomplete" title="the process ended mid-operation">
                {session.unclosed_operations} incomplete
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
        <TranscriptEntries
          entries={entries}
          snapshot={snapshot}
          timingSource={session.timing_source}
          newestSeq={newestSeq}
          onOpenRequest={setFocusedRequest}
        />
      </div>

      {focusedRequest != null && id && (
        <MessagesSidebar id={id} focusSeq={focusedRequest} onClose={() => setFocusedRequest(null)} />
      )}
    </>
  );
}

// A delegated sub-run, as rendered: the task_start that opened it, everything
// it produced, and the task_end that closed it (absent when the process died
// mid-delegation — see `open` below).
type GroupNode = { kind: "group"; start: Entry; end: Entry | null; children: TranscriptNode[] };
// One unit of work: the operation_start that opened it, everything it
// CONTAINED, and the operation_end that closed it (null when the process died
// mid-span). Nested from `parent_operation_id`, which is a recorded fact — the
// adjacency fold below is a guess, and was wrong in both directions.
type OpNode = { kind: "op"; start: Entry; end: Entry | null; children: TranscriptNode[] };
// The work framework code did on the model's behalf. It is not part of the
// model's narrative and does not belong inline with it. Its children are spans
// when the log has them, and a flat run of hook calls when it does not.
type AutoNode = { kind: "auto"; children: TranscriptNode[] };
type TranscriptNode = { kind: "entry"; entry: Entry } | GroupNode | AutoNode | OpNode;
// Anything that can hold children and be pushed onto the open stack.
type OpenNode = GroupNode | OpNode;

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

  // Automatic work sits under one muted heading rather than competing with the
  // model's actions. With spans, the things folded together are whole
  // operations; without them, a run of individual hook calls.
  const absorb = (node: TranscriptNode) => {
    const siblings = target();
    const last = siblings[siblings.length - 1];
    if (last?.kind === "auto") last.children.push(node);
    else siblings.push({ kind: "auto", children: [ node ] });
  };

  // A span inside another span nests there. A span that is not — whether at the
  // top level or at the top level OF A DELEGATION — joins the automatic-work
  // heading alongside its neighbours, because it is the outermost unit of
  // automatic work in its own context.
  const place = (node: TranscriptNode) => {
    if (insideOperation()) target().push(node);
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

// Collapse sub-runs by default once there are more than a couple: the player's
// narrative is the spine, and a sub-run is detail you open when a room looks
// wrong.
const COLLAPSE_THRESHOLD = 2;

function TranscriptEntries({
  entries,
  snapshot,
  timingSource,
  newestSeq,
  onOpenRequest,
}: {
  entries: Entry[];
  snapshot: SessionDetailData["snapshot"];
  timingSource: SessionDetailData["session"]["timing_source"];
  newestSeq: number | null;
  onOpenRequest: (requestSeq: number) => void;
}) {
  const nodes = buildTranscriptTree(entries);
  const markers = iterationMarkerSeqs(entries);
  const subRuns = entries.filter((e) => e.type === "task_start").length;

  return (
    <TranscriptNodes
      nodes={nodes}
      snapshot={snapshot}
      coarse={timingSource === "wallclock_coarse"}
      newestSeq={newestSeq}
      markers={markers}
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
          <OperationGroup key={`op-${node.start.seq}`} node={node} {...props} />
        ) : node.kind === "group" ? (
          <TaskGroup key={`group-${node.start.seq}`} node={node} {...props} />
        ) : node.entry.type === "local_inference" ? (
          // A summary of the span, not a step in its narrative.
          <LocalInferenceRow key={node.entry.seq} entry={node.entry} coarse={props.coarse} />
        ) : (
          <Fragment key={node.entry.seq}>
            {props.markers.has(node.entry.seq) && (
              <div className="iteration-marker">Iteration {node.entry.iteration}</div>
            )}
            <div className={node.entry.seq === props.newestSeq ? "entry-row entry-row-new" : "entry-row"}>
              <div className="entry-gutter-row">
                <Duration
                  at={node.entry.at}
                  dtMs={node.entry.dt_ms}
                  durationMs={node.entry.duration_ms}
                  coarse={props.coarse}
                />
                <TaskChip task={node.entry.task} />
              </div>
              <TranscriptEntry
                entry={node.entry}
                snapshot={props.snapshot}
                onOpenRequest={props.onOpenRequest}
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
          <span className="task-group-incomplete" title="no task_end — the run ended mid-delegation">
            incomplete
          </span>
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

// Human wording for the semantic reason a hook spent MUD round trips. Falling
// back to the raw slug is deliberate: an operation this build has never heard
// of must still be visible, not swallowed.
const OPERATION_LABELS: Record<string, string> = {
  player_bootstrap: "bootstrap player",
  position_refresh: "establish position",
  room_disambiguation: "disambiguate room",
  room_survey: "room survey",
  async_poll: "poll",
};

function operationLabel(operation: string | null | undefined) {
  if (!operation) return "automatic";
  return OPERATION_LABELS[operation] ?? operation.replace(/_/g, " ");
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

      {!expanded && <AutomaticSummary node={node} coarse={props.coarse} />}

      {expanded && (
        <div className="task-group-body">
          <TranscriptNodes nodes={node.children} {...props} />
        </div>
      )}
    </div>
  );
}

// The collapsed one-line-per-operation view. With spans, each child span is
// already one operation and contributes one row. Without them (a pre-span log),
// runs of adjacent calls sharing an `operation` string are folded — which is
// the approximation spans exist to replace, kept only for those files.
function AutomaticSummary({ node, coarse }: { node: AutoNode; coarse: boolean }) {
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
            {row.incomplete && <span className="task-group-incomplete">incomplete</span>}
            {ms > 0 && <span className="auto-summary-ms">{fmtDelta(ms, coarse)}</span>}
          </li>
        );
      })}
    </ol>
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
          <span className="task-group-incomplete" title="no operation_end — the run ended mid-operation">
            incomplete
          </span>
        )}
        {durationMs != null && <span className="task-group-meta">{fmtDelta(durationMs, props.coarse)}</span>}
      </button>

      {expanded && (
        <div className="task-group-body">
          {node.children.map((child) =>
            child.kind === "op" ? (
              <OperationGroup key={`op-${child.start.seq}`} node={child} {...props} />
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

// `⛁ wrote 11 · read 6 · 3ms (7 journal lines)`.
//
// The two numbers count different things and the gap between them is the
// interesting part, in either direction. Fewer lines than writes means the
// journal swallowed no-ops — `jupsert` is change-detecting, so re-writing an
// unchanged value appends nothing, and that is how you find a survey rewriting
// values that never change. MORE lines than writes is the ordinary case for
// `update_player!`, where one UPDATE of six columns is six keyed series.
function StoreRollup({
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

// Fetched on expand, never bundled into the session payload: the session view
// should not grow a second full log inside it. The rows are the same ones the
// Progression tab shows for this operation — one writer per fact, and the
// journal keeps the detail.
function JournalDetail({ operationId }: { operationId: string }) {
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

// `◆ look_candidates · 23 scored → 3 kept · 11ms · local, $0`, or the same row
// reading `unavailable` when the weights are not installed.
//
// That second case is the one that matters: a missing artifact degrades to a
// null model that warns once and then returns [] forever, so the session used to
// say nothing at all — and an empty `look_candidates` field read identically
// whether the model was absent or the room simply had nothing worth looking at.
function LocalInferenceRow({ entry, coarse }: { entry: Entry; coarse: boolean }) {
  const unavailable = entry.available === false;
  return (
    <div className={unavailable ? "op-inference op-inference-off" : "op-inference"}>
      <span className="op-rollup-icon">◆</span>
      <span className="op-inference-model">{entry.model}</span>
      {unavailable ? (
        <span className="op-inference-off-label" title={entry.reason ?? undefined}>
          unavailable{entry.reason ? ` — ${entry.reason}` : ""}
        </span>
      ) : (
        <span>
          {entry.pool ?? 0} scored → {entry.kept ?? 0} kept
        </span>
      )}
      {entry.duration_ms != null && <span>· {fmtDelta(entry.duration_ms, coarse)}</span>}
      {/* Stated, not omitted: the cost table had no row for this model at all,
          which reads as "no cost information" when the truth is "free". */}
      <span className="op-inference-cost">· {entry.unit ?? "local"}, {fmtCost(entry.cost_usd ?? 0)}</span>
    </div>
  );
}

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

// Every Entry inside a node, automatic work and nested spans included — a group
// header's cost and iteration figures must count the hook's calls too, or a
// delegation that spent most of its time surveying rooms reports as having done
// nothing.
function flatten(node: GroupNode | AutoNode | OpNode): Entry[] {
  // The `auto` heading is a rendering device with no event of its own; a group
  // and a span each open with a real one.
  const own = node.kind === "auto" ? [] : [ node.start ];
  return [
    ...own,
    ...node.children.flatMap((child) => (child.kind === "entry" ? [ child.entry ] : flatten(child))),
  ];
}

// The tool calls a node contains, excluding the span brackets themselves —
// what "4 calls, 2.4s" is counted over.
function toolsIn(node: GroupNode | AutoNode | OpNode): Entry[] {
  return flatten(node).filter((e) => e.type === "tool");
}

function TranscriptEntry({
  entry,
  snapshot,
  onOpenRequest,
}: {
  entry: Entry;
  snapshot: SessionDetailData["snapshot"];
  onOpenRequest: (requestSeq: number) => void;
}) {
  switch (entry.type) {
    case "user":
      return (
        <div className="msg msg-user">
          <div className="msg-role">
            <span>User</span>
          </div>
          <div className="msg-body">{entry.text}</div>
        </div>
      );

    case "compaction":
      return (
        <div className="divider divider-compaction">
          ↻ context compacted — {entry.dropped} message{entry.dropped === 1 ? "" : "s"} dropped
        </div>
      );

    case "clear":
      return (
        <div className="divider divider-compaction">
          ⌫ conversation cleared — {entry.dropped} message{entry.dropped === 1 ? "" : "s"} dropped
        </div>
      );

    case "request":
      // The point a model call was made. The button opens the sidebar on THIS
      // request's payload (system + tools + wire messages) — kept out of the
      // transcript body so the narrative stays readable.
      return (
        <div className="request-marker">
          <button
            type="button"
            className="request-btn"
            onClick={() => entry.request_seq != null && onOpenRequest(entry.request_seq)}
            title="View the exact payload sent to the model on this call"
          >
            🧠 view request
            {entry.message_count != null && (
              <span className="request-btn-count">{entry.message_count} msg{entry.message_count === 1 ? "" : "s"}</span>
            )}
          </button>
        </div>
      );

    case "turn_end": {
      const tripped = entry.reason != null && entry.reason !== "completed";
      const hasBar = (snapshot.max_turn_tokens ?? 0) > 0 && entry.tokens != null;
      return (
        <div className={tripped ? "turn-strip danger" : "turn-strip"}>
          <div className="turn-strip-text">
            {tripped ? "⚠" : "✓"} Turn {entry.turn} · {entry.iterations} iteration
            {entry.iterations === 1 ? "" : "s"}
            {entry.tokens != null && <> · {fmtTokens(entry.tokens)} tok</>}
            {tripped && <> · {entry.reason}</>}
          </div>
          {hasBar && (
            <>
              <div className="bar">
                <div
                  className={tripped ? "bar-fill danger" : "bar-fill"}
                  style={{ width: `${pct(entry.tokens, snapshot.max_turn_tokens)}%` }}
                />
              </div>
              <div className="turn-strip-pct">{pctRaw(entry.tokens, snapshot.max_turn_tokens)}%</div>
            </>
          )}
        </div>
      );
    }

    case "plan":
      return (
        <div className="msg msg-assistant msg-preamble">
          <div className="msg-role">
            <span>Plan</span>
            <span className="usage">before tool call</span>
          </div>
          <div className="msg-body">{entry.text}</div>
        </div>
      );

    case "assistant":
      if (entry.text?.startsWith("(tool use")) {
        return (
          <div className="tool-marker">
            <span>{entry.text}</span>
            <CtxChip
              usage={entry.usage}
              running={entry.running_turn_tokens}
              contextWindow={snapshot.context_window}
              maxTurnTokens={snapshot.max_turn_tokens}
              provider={entry.provider}
              model={entry.model}
              costUsd={entry.cost_usd}
            />
          </div>
        );
      }
      return (
        <div className="msg msg-assistant">
          <div className="msg-role">
            <span>Assistant</span>
            <span className="usage">{entry.stop_reason && <>stop: {entry.stop_reason}</>}</span>
          </div>
          <div className="msg-body">{entry.text}</div>
          {entry.usage && (
            <div className="msg-foot">
              <CtxChip
                usage={entry.usage}
                running={entry.running_turn_tokens}
                contextWindow={snapshot.context_window}
                maxTurnTokens={snapshot.max_turn_tokens}
                provider={entry.provider}
                model={entry.model}
                costUsd={entry.cost_usd}
              />
            </div>
          )}
        </div>
      );

    case "reasoning":
      return (
        <div className="msg msg-assistant msg-reasoning">
          <div className="msg-role">
            <span>Reasoning</span>
          </div>
          <div className="msg-body">
            {entry.redacted || !entry.text?.trim() ? (
              <span className="muted">(reasoning hidden)</span>
            ) : (
              entry.text
            )}
          </div>
        </div>
      );

    case "tool":
      return <ToolCard entry={entry} />;

    case "injected_context":
      return <InjectedContext entry={entry} />;

    case "context_transform":
      // Only reachable when the log lost the call this belongs to; the normal
      // path folds it into the tool card.
      return (
        <div className="injected-card">
          <div className="injected-head">↪ model received (call {entry.call_id ?? "?"})</div>
          <pre className="injected-body">{entry.content}</pre>
        </div>
      );

    case "unknown":
      return (
        <div className="msg msg-unknown">
          <div className="msg-role">
            <span>{String(entry.raw?.phase ?? "unknown")}</span>
          </div>
          <div className="msg-body">
            <pre>{JSON.stringify(entry.raw, null, 2)}</pre>
          </div>
        </div>
      );

    default:
      return null;
  }
}

// One tool call. When a hook replaced the result before it reached the model,
// the card shows what the MODEL received and offers the MUD's own words on
// demand — the two used to appear as an unexplained contradiction between the
// transcript (full room dump) and the request drawer (`moved west → …`).
//
// The raw text is never discarded: it is what debugs the parser and the
// transport, while the replacement is what debugs the agent's behaviour.
function ToolCard({ entry }: { entry: Entry }) {
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
    </div>
  );
}

// State a hook appended to the conversation on the model's behalf — the
// `[here]` block, in the MUD deployment. It sits immediately before the request
// that carried it, which is what makes an assistant thanking us "for the
// context" traceable without opening the request drawer.
//
// Collapsed to its first line by default: the block is re-rendered every
// iteration and is usually identical to the last one, and `changed` is how the
// server says which is which.
function InjectedContext({ entry }: { entry: Entry }) {
  const [open, setOpen] = useState(false);
  const lines = (entry.content ?? "").split("\n");
  const unchanged = entry.changed === false;

  return (
    <div className={unchanged ? "injected-card injected-unchanged" : "injected-card"}>
      <button type="button" className="injected-head" aria-expanded={open} onClick={() => setOpen(!open)}>
        <span className="task-group-caret">{open ? "▾" : "▸"}</span>
        <span className="injected-label">Context injected</span>
        {entry.source && <span className="task-group-meta">{entry.source}</span>}
        {unchanged && <span className="task-group-meta">unchanged</span>}
        <span className="task-group-spacer" />
        <span className="injected-peek">{lines[0]}</span>
      </button>
      {open && <pre className="injected-body">{entry.content}</pre>}
    </div>
  );
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
