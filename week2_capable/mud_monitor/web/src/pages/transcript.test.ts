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

describe("buildTranscriptTree", () => {
  it("folds a run of hook calls into one automatic group", () => {
    const nodes = buildTranscriptTree([
      hook({ tool_name: "tbamud__check", operation: "player_bootstrap" }),
      hook({ tool_name: "tbamud__look", operation: "position_refresh" }),
      model({ tool_name: "tbamud__move" }),
    ]);

    expect(nodes.map((n) => n.kind)).toEqual([ "auto", "entry" ]);
    expect(nodes[0].kind === "auto" && nodes[0].entries).toHaveLength(2);
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
