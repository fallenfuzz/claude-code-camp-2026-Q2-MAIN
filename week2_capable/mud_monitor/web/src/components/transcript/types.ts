import type { Entry } from "../../api/types";

// The legacy transcript tree (SessionDetail.tsx's `buildTranscriptTree`,
// still the only path for a session with no operation spans). Extracted here
// — rather than left private to the page — because `AutomaticSummary` needs
// to describe an `AutoNode`'s children regardless of which module builds one.

// A delegated sub-run, as rendered: the task_start that opened it, everything
// it produced, and the task_end that closed it (absent when the process died
// mid-delegation).
export type GroupNode = { kind: "group"; start: Entry; end: Entry | null; children: TranscriptNode[] };
// One unit of work: the operation_start that opened it, everything it
// CONTAINED, and the operation_end that closed it (null when the process died
// mid-span). Nested from `parent_operation_id`, a recorded fact.
export type OpNode = { kind: "op"; start: Entry; end: Entry | null; children: TranscriptNode[] };
// The work framework code did on the model's behalf. Its children are spans
// when the log has them, and a flat run of hook calls when it does not.
export type AutoNode = { kind: "auto"; children: TranscriptNode[] };
export type TranscriptNode = { kind: "entry"; entry: Entry } | GroupNode | AutoNode | OpNode;
// Anything that can hold children and be pushed onto the open stack.
export type OpenNode = GroupNode | OpNode;

// The shape a `tool` entry's span rollup is reduced to before it reaches
// `ToolCard` — computed differently by the legacy flat-entries scan
// (`toolSpanRollup` in SessionDetail.tsx) and by the story tree (read
// straight off `trace.spans`), but consumed identically either way.
export interface ToolRollupInfo {
  durationMs: number | null;
  rollup: Record<string, number> | null;
  afterToolOperationId: string | null;
}

// Every Entry inside a node, automatic work and nested spans included — a
// group header's cost and iteration figures must count the hook's calls too.
export function flattenNode(node: GroupNode | AutoNode | OpNode): Entry[] {
  const own = node.kind === "auto" ? [] : [ node.start ];
  return [
    ...own,
    ...node.children.flatMap((child) => (child.kind === "entry" ? [ child.entry ] : flattenNode(child))),
  ];
}

// The tool calls a node contains, excluding the span brackets themselves.
export function toolsIn(node: GroupNode | AutoNode | OpNode): Entry[] {
  return flattenNode(node).filter((e) => e.type === "tool");
}
