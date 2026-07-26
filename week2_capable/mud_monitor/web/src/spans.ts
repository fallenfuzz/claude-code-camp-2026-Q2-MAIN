// Shared span-naming helpers. `operationLabel` is used by both the story tree
// (SessionStory) and the legacy linear transcript (SessionDetail, kept for
// sessions written before spans existed); `isFrameworkSpan` is legacy-only —
// the story tree replaced the transparent-span rule with an explicit
// per-kind row policy, so every span there gets a row regardless.

// Human wording for the semantic reason a span exists. Falling back to the raw
// slug is deliberate: an operation this build has never heard of must still be
// visible, not swallowed.
const OPERATION_LABELS: Record<string, string> = {
  player_bootstrap: "bootstrap player",
  position_refresh: "establish position",
  room_disambiguation: "disambiguate room",
  room_survey: "room survey",
  async_poll: "poll",
  // The framework spans (instrumentation.md §9) render transparently on the
  // transcript — none of these draw an OperationGroup box — but they still
  // need a label wherever a rollup or the waterfall/table view names them
  // directly.
  turn: "turn",
  iteration: "iteration",
  "llm.generate": "model call",
  after_tool: "record outcome",
  wrap_up: "wind down",
  compaction: "compact context",
};

export function operationLabel(operation: string | null | undefined, semanticKind?: string): string {
  if (!operation) return "automatic";
  if (semanticKind === "internal") return `internal · ${operation.replace(/_/g, " ")}`;
  if (operation.startsWith("invoke_agent ")) return operation.replace("_", " ");
  if (operation.startsWith("chat ")) return operation;
  if (operation.startsWith("execute_tool ")) return operation.slice("execute_tool ".length);
  if (operation.startsWith("tool.")) return operation.slice("tool.".length);
  return OPERATION_LABELS[operation] ?? operation.replace(/_/g, " ");
}

// instrumentation.md §9: spans this plan wraps around EVERYTHING (turn,
// iteration, one per model call, one per model-chosen tool call, its
// after_tool reaction) are the model's own narrative, not automatic work — the
// rule was always "a span becomes a UI group only when it is work the reader
// would otherwise mistake for something else", which is true of the hook spans
// (position_refresh, room_survey, …) and false of these. They draw no box on
// the legacy transcript.
const FRAMEWORK_SPANS = new Set([ "turn", "iteration", "llm.generate", "after_tool", "compaction", "wrap_up" ]);

export function isFrameworkSpan(operation: string | null | undefined): boolean {
  if (!operation) return false;
  if (FRAMEWORK_SPANS.has(operation)) return true;
  // tool.move, tool.attack, … — one per model-chosen tool call, named
  // dynamically after the tool. A fixed-name Set can't enumerate these.
  return operation.startsWith("tool.");
}
