import { describe, expect, it } from "vitest";
import type { Entry } from "../api/types";
import { buildTranscriptTree, shortToolName, tallyTools } from "./SessionDetail";

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
