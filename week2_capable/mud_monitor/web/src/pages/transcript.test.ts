import { describe, expect, it } from "vitest";
import type { Entry } from "../api/types";
import { isFrameworkSpan } from "../spans";
import { shortToolName, tallyTools } from "../components/transcript/ToolCard";
import { buildRollupIndex, buildTranscriptTree, toolSpanRollup } from "./SessionDetail";

// Entries arrive flat and ordered; nesting is a rendering concern decided here.
// These cover the grouping observ_improvements.md §3 asks for: automatic work
// out of the model's narrative, without hiding anything the reader needs.

let seq = 0;

function entry(over: Partial<Entry> = {}): Entry {
  return {
    seq: ++seq,
    type: "tool",
    task: "player",
    depth: 0,
    turn: 0,
    iteration: 1,
    at: null,
    dt_ms: null,
    duration_ms: null,
    ...over,
  } as Entry;
}

const hook = (over: Partial<Entry> = {}) => entry({ initiator: "hook", ...over });
const model = (over: Partial<Entry> = {}) => entry({ initiator: "model", ...over });

// An operation span, as the logger writes it: a start, a body, an end.
const opStart = (id: string, operation: string, parent?: string) =>
  entry({ type: "operation_start", operation, operation_id: id, parent_operation_id: parent ?? null });
const opEnd = (id: string, operation: string, rollup?: Record<string, number>) =>
  entry({ type: "operation_end", operation, operation_id: id, ok: true, rollup: rollup ?? null });

describe("buildTranscriptTree", () => {
  it("folds a run of hook calls into one automatic group", () => {
    const nodes = buildTranscriptTree([
      hook({ tool_name: "tbamud__check", operation: "player_bootstrap" }),
      hook({ tool_name: "tbamud__look", operation: "position_refresh" }),
      model({ tool_name: "tbamud__move" }),
    ]);

    expect(nodes.map((n) => n.kind)).toEqual([ "auto", "entry" ]);
    expect(nodes[0].kind === "auto" && nodes[0].children).toHaveLength(2);
  });

  // The model's actions are the spine. An automatic call on either side of one
  // must not swallow it into a single group.
  it("does not merge automatic runs across a model call", () => {
    const nodes = buildTranscriptTree([
      hook({ tool_name: "tbamud__poll", operation: "async_poll" }),
      model({ tool_name: "tbamud__move" }),
      hook({ tool_name: "tbamud__poll", operation: "async_poll" }),
    ]);

    expect(nodes.map((n) => n.kind)).toEqual([ "auto", "entry", "auto" ]);
  });

  it("leaves model calls and every other entry type in the narrative", () => {
    const nodes = buildTranscriptTree([
      entry({ type: "injected_context", initiator: undefined }),
      entry({ type: "request", initiator: undefined }),
      model({ tool_name: "tbamud__move" }),
      entry({ type: "assistant", initiator: undefined }),
    ]);

    expect(nodes.every((n) => n.kind === "entry")).toBe(true);
  });

  // A pre-provenance log has no initiator on anything. Every call must stay in
  // the narrative — the old presentation, unchanged, because the file cannot
  // say which calls were automatic.
  it("groups nothing when the log carries no provenance", () => {
    const nodes = buildTranscriptTree([
      entry({ tool_name: "look" }),
      entry({ tool_name: "move" }),
    ]);

    expect(nodes.map((n) => n.kind)).toEqual([ "entry", "entry" ]);
  });

  // Automatic work inside a delegation belongs to that delegation, not to the
  // player's spine.
  it("nests automatic groups inside the sub-run that produced them", () => {
    const nodes = buildTranscriptTree([
      entry({ type: "task_start", task_name: "room_inspector", initiator: undefined }),
      hook({ tool_name: "tbamud__look", depth: 1, operation: "room_survey" }),
      hook({ tool_name: "tbamud__check", depth: 1, operation: "room_survey" }),
      entry({ type: "task_end", task_name: "room_inspector", initiator: undefined }),
    ]);

    expect(nodes).toHaveLength(1);
    const group = nodes[0];
    expect(group.kind).toBe("group");
    if (group.kind !== "group") return;
    expect(group.children.map((c) => c.kind)).toEqual([ "auto" ]);
    expect(group.end).not.toBeNull();
  });
});

// work_attribution.md §1, §4. Adjacency is a proxy for containment and it is
// wrong in both directions; these are the cases it got wrong.
describe("buildTranscriptTree with operation spans", () => {
  it("nests a span inside the span that contained it", () => {
    const nodes = buildTranscriptTree([
      opStart("op_pos", "position_refresh"),
      hook({ tool_name: "tbamud__look", operation: "position_refresh", operation_id: "op_pos" }),
      opStart("op_survey", "room_survey", "op_pos"),
      hook({ tool_name: "tbamud__check", operation: "room_survey", operation_id: "op_survey" }),
      opEnd("op_survey", "room_survey"),
      opEnd("op_pos", "position_refresh"),
    ]);

    // Three levels: Automatic context work → establish position → room survey.
    expect(nodes.map((n) => n.kind)).toEqual([ "auto" ]);
    const auto = nodes[0];
    if (auto.kind !== "auto") return;
    const outer = auto.children[0];
    expect(outer.kind).toBe("op");
    if (outer.kind !== "op") return;
    expect(outer.start.operation).toBe("position_refresh");
    expect(outer.children.map((c) => c.kind)).toEqual([ "entry", "op" ]);
    const inner = outer.children[1];
    if (inner.kind !== "op") return;
    expect(inner.start.operation).toBe("room_survey");
    expect(inner.end).not.toBeNull();
  });

  // The regression the plan names outright: a model call landing between two
  // hook calls used to split one logical operation into two groups.
  it("does not split an operation when a model call lands in the middle of it", () => {
    const nodes = buildTranscriptTree([
      opStart("op_survey", "room_survey"),
      hook({ tool_name: "tbamud__look", operation_id: "op_survey" }),
      model({ tool_name: "tbamud__move" }),
      hook({ tool_name: "tbamud__check", operation_id: "op_survey" }),
      opEnd("op_survey", "room_survey"),
    ]);

    expect(nodes.map((n) => n.kind)).toEqual([ "auto" ]);
    const auto = nodes[0];
    if (auto.kind !== "auto") return;
    expect(auto.children).toHaveLength(1);
    const op = auto.children[0];
    if (op.kind !== "op") return;
    // All three entries stay inside the span that contained them, including
    // the model's — containment is what the log recorded.
    expect(op.children).toHaveLength(3);
  });

  // The process died mid-span. Rendering it as closed would imply a finish
  // that never happened.
  it("leaves a span with no end incomplete rather than closing it", () => {
    const nodes = buildTranscriptTree([
      opStart("op_survey", "room_survey"),
      hook({ tool_name: "tbamud__look", operation_id: "op_survey" }),
    ]);

    const auto = nodes[0];
    if (auto.kind !== "auto") return;
    const op = auto.children[0];
    expect(op.kind).toBe("op");
    if (op.kind !== "op") return;
    expect(op.end).toBeNull();
  });

  // A lost `operation_end` must not close the wrong span and reparent
  // everything after it. Matching on id unwinds to the right one and leaves the
  // orphan incomplete.
  it("matches an end to its own span by id, not by position", () => {
    const nodes = buildTranscriptTree([
      opStart("op_outer", "position_refresh"),
      opStart("op_inner", "room_survey", "op_outer"),
      // op_inner's end never arrived.
      opEnd("op_outer", "position_refresh"),
      model({ tool_name: "tbamud__move" }),
    ]);

    expect(nodes.map((n) => n.kind)).toEqual([ "auto", "entry" ]);
    const auto = nodes[0];
    if (auto.kind !== "auto") return;
    const outer = auto.children[0];
    if (outer.kind !== "op") return;
    expect(outer.end).not.toBeNull();
    const inner = outer.children[0];
    if (inner.kind !== "op") return;
    expect(inner.end).toBeNull();
  });

  // Spans open inside a delegation belong to it, exactly as loose hook calls do.
  it("nests spans inside the sub-run that produced them", () => {
    const nodes = buildTranscriptTree([
      entry({ type: "task_start", task_name: "room_inspector" }),
      opStart("op_survey", "room_survey"),
      hook({ tool_name: "tbamud__look", depth: 1, operation_id: "op_survey" }),
      opEnd("op_survey", "room_survey"),
      entry({ type: "task_end", task_name: "room_inspector" }),
    ]);

    expect(nodes).toHaveLength(1);
    const group = nodes[0];
    if (group.kind !== "group") return;
    expect(group.children.map((c) => c.kind)).toEqual([ "auto" ]);
    const auto = group.children[0];
    if (auto.kind !== "auto") return;
    expect(auto.children.map((c) => c.kind)).toEqual([ "op" ]);
  });

  // A file written before spans existed has no operation_start anywhere, and
  // must render exactly as it does today.
  it("falls back to the adjacency fold when the log has no spans", () => {
    const nodes = buildTranscriptTree([
      hook({ tool_name: "tbamud__check", operation: "player_bootstrap" }),
      hook({ tool_name: "tbamud__look", operation: "position_refresh" }),
      model({ tool_name: "tbamud__move" }),
    ]);

    expect(nodes.map((n) => n.kind)).toEqual([ "auto", "entry" ]);
    const auto = nodes[0];
    if (auto.kind !== "auto") return;
    expect(auto.children.every((c) => c.kind === "entry")).toBe(true);
  });

  // The inference row is a summary of the span, so it lives inside it.
  it("keeps a local_inference event inside the span that ran it", () => {
    const nodes = buildTranscriptTree([
      opStart("op_survey", "room_survey"),
      entry({ type: "local_inference", model: "look_candidates", operation_id: "op_survey", pool: 23, kept: 3 }),
      opEnd("op_survey", "room_survey", { db_writes: 11, db_reads: 6, journal_lines: 7 }),
    ]);

    const auto = nodes[0];
    if (auto.kind !== "auto") return;
    const op = auto.children[0];
    if (op.kind !== "op") return;
    expect(op.children.map((c) => c.kind)).toEqual([ "entry" ]);
    expect(op.end?.rollup).toEqual({ db_writes: 11, db_reads: 6, journal_lines: 7 });
  });
});

// instrumentation.md §9-10: turn/iteration/llm.generate/tool.<name>/after_tool
// now wrap EVERYTHING. If they gated grouping the same way a hook span does,
// no hook span would ever be absorbed into "Automatic context work" again —
// something framework-shaped is always open. And a model's own tool.<name>
// span must never fall into that same heading, or the model's actions vanish
// into a collapsed group labelled "Automatic context work" (§10 hazard).
describe("buildTranscriptTree with framework spans (turn/iteration/tool.<name>)", () => {
  it("classifies the new framework spans, including the dynamically-named tool.<name>", () => {
    for (const op of [ "turn", "iteration", "llm.generate", "after_tool", "compaction", "wrap_up", "tool.move", "tool.attack" ]) {
      expect(isFrameworkSpan(op)).toBe(true);
    }
    for (const op of [ "player_bootstrap", "position_refresh", "room_disambiguation", "room_survey", "async_poll", null, undefined ]) {
      expect(isFrameworkSpan(op)).toBe(false);
    }
  });

  it("still absorbs a hook span into automatic work with a framework span (iteration) open around it", () => {
    const nodes = buildTranscriptTree([
      opStart("op_iter", "iteration"),
      opStart("op_pos", "position_refresh", "op_iter"),
      hook({ tool_name: "tbamud__look", operation: "position_refresh", operation_id: "op_pos" }),
      opEnd("op_pos", "position_refresh"),
      model({ tool_name: "tbamud__move", operation_id: "op_tool" }),
      opEnd("op_iter", "iteration"),
    ]);

    // `iteration` is not itself grouped — buildTranscriptTree still records it
    // as an "op" node (rendering decides transparency), but position_refresh
    // inside it is exactly as grouped as it always was.
    expect(nodes.map((n) => n.kind)).toEqual([ "op" ]);
    const iter = nodes[0];
    if (iter.kind !== "op") return;
    expect(iter.start.operation).toBe("iteration");
    expect(iter.children.map((c) => c.kind)).toEqual([ "auto", "entry" ]);
    const auto = iter.children[0];
    if (auto.kind !== "auto") return;
    const pos = auto.children[0];
    expect(pos.kind).toBe("op");
  });

  // The hazard §10 names outright: a `tool.move` span at `initiator: "model"`
  // must stay on the spine, nested directly in `iteration`, never absorbed.
  it("keeps a model-chosen tool.<name> span out of automatic work", () => {
    const nodes = buildTranscriptTree([
      opStart("op_iter", "iteration"),
      opStart("op_tool", "tool.move", "op_iter"),
      model({ tool_name: "tbamud__move", operation_id: "op_tool" }),
      opEnd("op_tool", "tool.move", { mud_calls: 1, mud_ms: 23 }),
      opEnd("op_iter", "iteration"),
    ]);

    const iter = nodes[0];
    if (iter.kind !== "op") return;
    expect(iter.children.map((c) => c.kind)).toEqual([ "op" ]);
    const tool = iter.children[0];
    if (tool.kind !== "op") return;
    expect(tool.start.operation).toBe("tool.move");
    expect(tool.end?.rollup).toEqual({ mud_calls: 1, mud_ms: 23 });
  });
});

describe("rollup attachment (instrumentation.md §9-11)", () => {
  it("prefers the llm.generate span's measured duration over dt_ms, keyed to the assistant entry that followed it", () => {
    const llmEnd = opEnd("op_llm", "llm.generate", { input_tokens: 100 });
    const assistant = entry({ type: "assistant", text: "done", dt_ms: 3000, duration_ms: 3000 });
    const idx = buildRollupIndex([ opStart("op_llm", "llm.generate"), llmEnd, assistant ]);

    expect(idx.llmLatencyByAssistantSeq.get(assistant.seq)).toBe(llmEnd);
  });

  it("merges the tool.<name> span's rollup with its after_tool child's, keyed by call site rather than duplicated as a second box", () => {
    const entries = [
      opStart("op_tool", "tool.move"),
      model({ tool_name: "tbamud__move", operation_id: "op_tool" }),
      opStart("op_after", "after_tool", "op_tool"),
      opEnd("op_after", "after_tool", { db_writes: 3, journal_lines: 2 }),
      opEnd("op_tool", "tool.move", { mud_calls: 1, mud_ms: 23 }),
    ];
    const idx = buildRollupIndex(entries);
    const toolEntry = entries[1];

    const rollup = toolSpanRollup(toolEntry, idx);
    expect(rollup?.rollup).toEqual({ mud_calls: 1, mud_ms: 23, db_writes: 3, journal_lines: 2 });
    expect(rollup?.afterToolOperationId).toBe("op_after");
  });

  it("returns null for a hook-initiated call, which carries a hook span's operation_id, not a tool.<name> span's", () => {
    const entries = [
      opStart("op_pos", "position_refresh"),
      hook({ tool_name: "tbamud__look", operation_id: "op_pos" }),
      opEnd("op_pos", "position_refresh", { mud_calls: 1 }),
    ];
    const idx = buildRollupIndex(entries);

    expect(toolSpanRollup(entries[1], idx)).toBeNull();
  });
});

describe("automatic-work summary labels", () => {
  it("strips the server prefix and keeps the argument that identifies the call", () => {
    expect(shortToolName(entry({ tool_name: "tbamud__check", tool_args: { kind: "score" } })))
      .toBe("check(score)");
    expect(shortToolName(entry({ tool_name: "tbamud__look", tool_args: {} }))).toBe("look");
  });

  // Eight empty polls carry one fact between them and get one line.
  it("collapses repeated identical calls into a count", () => {
    const polls = Array.from({ length: 8 }, () => hook({ tool_name: "tbamud__poll", tool_args: {} }));
    expect(tallyTools(polls)).toBe("poll × 8");
  });

  it("keeps distinct calls distinct", () => {
    expect(
      tallyTools([
        hook({ tool_name: "tbamud__look", tool_args: {} }),
        hook({ tool_name: "tbamud__check", tool_args: { kind: "exits" } }),
        hook({ tool_name: "tbamud__check", tool_args: { kind: "exits" } }),
      ]),
    ).toBe("look, check(exits) × 2");
  });
});
