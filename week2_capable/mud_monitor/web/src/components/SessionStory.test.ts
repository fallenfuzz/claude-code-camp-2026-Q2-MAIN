import { describe, expect, it } from "vitest";
import type { Entry, SessionSpan, SessionTrace } from "../api/types";
import { buildCostIndex, flattenSpans, forceOpenIds, seedExpanded, toolRollupFor } from "./SessionStory";

function span(over: Partial<SessionSpan> = {}): SessionSpan {
  return {
    id: "s", parent_id: null, child_ids: [], trace_id: null, span_id: null,
    name: "internal", semantic_kind: "internal", task: "player", initiator: null,
    trigger: null, turn: null, iteration: null, start_at: null, start_mono_ms: 0,
    end_at: null, duration_ms: 0, self_ms: 0, status: "ok", attributes: {},
    rollup: {}, direct_entry_seqs: [], timeline: [],
    ...over,
  };
}

function entry(over: Partial<Entry> = {}): Entry {
  return {
    seq: 1, type: "tool", task: "player", depth: 0, turn: 0, iteration: 1,
    at: null, dt_ms: null, duration_ms: null,
    ...over,
  } as Entry;
}

function trace(spans: SessionSpan[], roots = [ spans[0]?.id ].filter(Boolean)): SessionTrace {
  return { roots, spans: Object.fromEntries(spans.map((s) => [ s.id, s ])), orphan_entry_seqs: [] };
}

describe("flattenSpans", () => {
  it("walks span.timeline in reading order, not raw child_ids", () => {
    const root = span({
      id: "root", semantic_kind: "invoke_agent",
      timeline: [ { kind: "span", id: "b" }, { kind: "span", id: "a" } ],
      child_ids: [ "a", "b" ],
    });
    const a = span({ id: "a" });
    const b = span({ id: "b" });
    const t = trace([ root, a, b ]);

    const rows = flattenSpans(t, new Set([ "root" ]));
    expect(rows.map((r) => r.span.id)).toEqual([ "root", "b", "a" ]);
  });

  it("does not descend into a collapsed span", () => {
    const root = span({ id: "root", timeline: [ { kind: "span", id: "child" } ], child_ids: [ "child" ] });
    const child = span({ id: "child" });
    const t = trace([ root, child ]);

    expect(flattenSpans(t, new Set()).map((r) => r.span.id)).toEqual([ "root" ]);
  });

  it("never gives after_tool its own row — it always folds into the tool card above it", () => {
    const root = span({ id: "root", timeline: [ { kind: "span", id: "after" } ], child_ids: [ "after" ] });
    const after = span({ id: "after", semantic_kind: "after_tool" });
    const t = trace([ root, after ]);

    expect(flattenSpans(t, new Set([ "root" ])).map((r) => r.span.id)).toEqual([ "root" ]);
  });
});

describe("toolRollupFor", () => {
  it("merges the tool span's own rollup with its after_tool child's", () => {
    const tool = span({
      id: "tool", semantic_kind: "execute_tool", rollup: { mud_calls: 1, mud_ms: 23 },
      child_ids: [ "after" ],
    });
    const after = span({ id: "after", semantic_kind: "after_tool", rollup: { db_writes: 3, journal_lines: 2 } });
    const t = trace([ tool, after ]);

    const rollup = toolRollupFor(tool, t);
    expect(rollup.rollup).toEqual({ mud_calls: 1, mud_ms: 23, db_writes: 3, journal_lines: 2 });
    expect(rollup.afterToolOperationId).toBe("after");
  });

  it("reports null when the span has no rollup at all", () => {
    const tool = span({ id: "tool", semantic_kind: "execute_tool", rollup: {} });
    expect(toolRollupFor(tool, trace([ tool ])).rollup).toBeNull();
  });
});

describe("forceOpenIds / seedExpanded", () => {
  it("forces a failed call and every ancestor open", () => {
    const root = span({ id: "root", semantic_kind: "invoke_agent", child_ids: [ "tool" ] });
    const tool = span({ id: "tool", semantic_kind: "execute_tool", parent_id: "root", direct_entry_seqs: [ 1 ] });
    const t = trace([ root, tool ]);
    const entries = [ entry({ seq: 1, type: "tool", tool_ok: false, operation_id: "tool" }) ];

    const forced = forceOpenIds(t, entries);
    expect(forced.has("tool")).toBe(true);
    expect(forced.has("root")).toBe(true);
  });

  it("forces a poll that actually returned something, but not an empty one", () => {
    const hook = span({ id: "hook", semantic_kind: "hook" });
    const t = trace([ hook ]);

    const empty = forceOpenIds(t, [ entry({ operation_id: "hook", operation: "async_poll", tool_result: "" }) ]);
    expect(empty.has("hook")).toBe(false);

    const nonEmpty = forceOpenIds(t, [ entry({ operation_id: "hook", operation: "async_poll", tool_result: "a fido arrives" }) ]);
    expect(nonEmpty.has("hook")).toBe(true);
  });

  it("story preset collapses hook/state/after_tool/internal by default; timing expands everything", () => {
    const spans = [
      span({ id: "iter", semantic_kind: "iteration" }),
      span({ id: "hook", semantic_kind: "hook" }),
      span({ id: "state", semantic_kind: "state" }),
    ];
    const t = trace(spans, [ "iter" ]);

    const story = seedExpanded(t, [], "story");
    expect(story.has("iter")).toBe(true);
    expect(story.has("hook")).toBe(false);
    expect(story.has("state")).toBe(false);

    const timing = seedExpanded(t, [], "timing");
    expect(timing.has("hook")).toBe(true);
    expect(timing.has("state")).toBe(true);
  });
});

describe("buildCostIndex", () => {
  it("sums a span's own assistant cost plus every descendant's", () => {
    const root = span({ id: "root", child_ids: [ "chat" ] });
    const chat = span({ id: "chat", semantic_kind: "chat", direct_entry_seqs: [ 5 ] });
    const t = trace([ root, chat ]);
    const entriesBySeq = new Map([ [ 5, entry({ seq: 5, type: "assistant", cost_usd: 0.002 }) ] ]);

    const cost = buildCostIndex(t, entriesBySeq);
    expect(cost.get("chat")).toBe(0.002);
    expect(cost.get("root")).toBe(0.002);
  });
});
