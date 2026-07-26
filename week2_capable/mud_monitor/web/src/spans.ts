// Shared span-naming helpers for the linear transcript (SessionDetail). Spans
// went through two eras on disk: the original literal names (`turn`,
// `llm.generate`, `tool.<name>`) and the OTel GenAI semconv rename
// (`invoke_agent <agent>`, `chat <model>`, `execute_tool <tool>`). Both are
// live in stored logs, so every predicate here matches both.

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
  // need a label wherever a rollup names them directly.
  turn: "turn",
  iteration: "iteration",
  "llm.generate": "model call",
  after_tool: "record outcome",
  wrap_up: "wind down",
  compaction: "compact context",
  state_render: "render state",
};

export function operationLabel(operation: string | null | undefined): string {
  if (!operation) return "automatic";
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
// the transcript.
export function isFrameworkSpan(operation: string | null | undefined): boolean {
  if (!operation) return false;
  if (operation === "iteration" || operation === "after_tool" || operation === "compaction" ||
      operation === "wrap_up" || operation === "state_render") {
    return true;
  }
  if (operation.startsWith("invoke_agent ") || operation.startsWith("chat ") ||
      operation.startsWith("execute_tool ")) {
    return true;
  }
  // Legacy era (pre-4cce5e5): fixed literal names plus the dynamic tool.<name>.
  return operation === "turn" || operation === "llm.generate" || operation.startsWith("tool.");
}

export function isTurnSpan(operation: string | null | undefined): boolean {
  if (!operation) return false;
  return operation === "turn" || operation.startsWith("invoke_agent ");
}

export function isModelSpan(operation: string | null | undefined): boolean {
  if (!operation) return false;
  return operation === "llm.generate" || operation.startsWith("chat ");
}

export function isToolSpan(operation: string | null | undefined): boolean {
  if (!operation) return false;
  return operation.startsWith("tool.") || operation.startsWith("execute_tool ");
}
