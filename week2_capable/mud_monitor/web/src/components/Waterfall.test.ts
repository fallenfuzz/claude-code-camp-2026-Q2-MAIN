import { describe, expect, it } from "vitest";
import type { Entry } from "../api/types";
import { buildWaterfallSpans } from "./Waterfall";

let seq = 0;

function entry(over: Partial<Entry> = {}): Entry {
  return {
    seq: ++seq,
    type: "operation_start",
    task: "player",
    depth: 0,
    turn: 0,
    iteration: 1,
    at: "2026-07-25T09:00:00.000-04:00",
    dt_ms: null,
    duration_ms: null,
    ...over,
  } as Entry;
}

const opStart = (id: string, operation: string, parent?: string, at?: string) =>
  entry({ type: "operation_start", operation, operation_id: id, parent_operation_id: parent ?? null, at });

const opEnd = (id: string, operation: string, durationMs: number, rollup?: Record<string, number>, at?: string) =>
  entry({ type: "operation_end", operation, operation_id: id, ok: true, duration_ms: durationMs, rollup: rollup ?? null, at });

describe("buildWaterfallSpans", () => {
  it("computes depth from parent_operation_id, not from array position", () => {
    const spans = buildWaterfallSpans([
      opStart("op_turn", "turn"),
      opStart("op_iter", "iteration", "op_turn"),
      opStart("op_llm", "llm.generate", "op_iter"),
      opEnd("op_llm", "llm.generate", 250),
      opEnd("op_iter", "iteration", 300),
      opEnd("op_turn", "turn", 310),
    ]);

    const byOp = Object.fromEntries(spans.map((s) => [ s.operation, s ]));
    expect(byOp["turn"].depth).toBe(0);
    expect(byOp["iteration"].depth).toBe(1);
    expect(byOp["llm.generate"].depth).toBe(2);
  });

  it("computes self time as duration minus the sum of direct children's durations", () => {
    const spans = buildWaterfallSpans([
      opStart("op_iter", "iteration"),
      opStart("op_llm", "llm.generate", "op_iter"),
      opEnd("op_llm", "llm.generate", 250),
      opEnd("op_iter", "iteration", 300),
    ]);

    const iter = spans.find((s) => s.operation === "iteration");
    expect(iter?.durationMs).toBe(300);
    expect(iter?.selfMs).toBe(50);
  });

  it("classifies llm.generate as inference, tool.<name> and hook spans as mud, and marks turn/iteration as structural containers", () => {
    const spans = buildWaterfallSpans([
      opStart("op_turn", "turn"),
      opStart("op_llm", "llm.generate", "op_turn"),
      opEnd("op_llm", "llm.generate", 100),
      opStart("op_tool", "tool.move", "op_turn"),
      opEnd("op_tool", "tool.move", 40, { mud_calls: 1 }),
      opStart("op_pos", "position_refresh", "op_turn"),
      opEnd("op_pos", "position_refresh", 20, { mud_calls: 1 }),
      opEnd("op_turn", "turn", 200),
    ]);

    const byOp = Object.fromEntries(spans.map((s) => [ s.operation, s ]));
    expect(byOp["llm.generate"].category).toBe("inference");
    expect(byOp["tool.move"].category).toBe("mud");
    expect(byOp["position_refresh"].category).toBe("mud");
    expect(byOp["turn"].container).toBe(true);
    expect(byOp["llm.generate"].container).toBe(false);
  });

  it("marks a span with no operation_end as open rather than closed at 0ms", () => {
    const spans = buildWaterfallSpans([ opStart("op_iter", "iteration") ]);

    expect(spans[0].open).toBe(true);
    expect(spans[0].durationMs).toBeNull();
  });

  it("anchors each span to its own opening entry's seq, for click-to-scroll", () => {
    const start = opStart("op_llm", "llm.generate");
    const spans = buildWaterfallSpans([ start, opEnd("op_llm", "llm.generate", 100) ]);

    expect(spans[0].anchorSeq).toBe(start.seq);
  });

  it("returns an empty list for a log with no spans, rather than throwing", () => {
    expect(buildWaterfallSpans([ entry({ type: "assistant", text: "hi" }) ])).toEqual([]);
  });
});
