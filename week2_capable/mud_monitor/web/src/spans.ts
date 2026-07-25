// Shared between SessionDetail (the transcript) and Waterfall (the timeline
// view) — both need to name and classify a span the same way, and a copy in
// each would drift the moment one of them added an operation the other didn't
// know about.

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

export function operationLabel(operation: string | null | undefined): string {
  if (!operation) return "automatic";
  if (operation.startsWith("tool.")) return operation.slice("tool.".length);
  return OPERATION_LABELS[operation] ?? operation.replace(/_/g, " ");
}

// instrumentation.md §9: spans this plan wraps around EVERYTHING (turn,
// iteration, one per model call, one per model-chosen tool call, its
// after_tool reaction) are the model's own narrative, not automatic work — the
// rule was always "a span becomes a UI group only when it is work the reader
// would otherwise mistake for something else", which is true of the hook spans
// (position_refresh, room_survey, …) and false of these. They draw no box on
// the transcript; the waterfall renders every span regardless, framework ones
// included, since a timeline's job is showing the true shape of the work.
const FRAMEWORK_SPANS = new Set([ "turn", "iteration", "llm.generate", "after_tool", "compaction", "wrap_up" ]);

export function isFrameworkSpan(operation: string | null | undefined): boolean {
  if (!operation) return false;
  if (FRAMEWORK_SPANS.has(operation)) return true;
  // tool.move, tool.attack, … — one per model-chosen tool call, named
  // dynamically after the tool. A fixed-name Set can't enumerate these.
  return operation.startsWith("tool.");
}

// Pure structural containers: real spans with a real duration, but no work of
// their own beyond what their children already account for. The waterfall
// gives these an outline-only bar (§11's "Grid and axis recessive") rather
// than a fourth categorical hue — they are not a KIND of work, they are the
// absence of a more specific one.
const CONTAINER_SPANS = new Set([ "turn", "iteration", "wrap_up", "compaction" ]);

export function isContainerSpan(operation: string | null | undefined): boolean {
  return !!operation && CONTAINER_SPANS.has(operation);
}

export type WaterfallCategory = "inference" | "mud" | "memory" | "local";

const HOOK_SPANS = new Set([ "player_bootstrap", "position_refresh", "room_disambiguation", "room_survey", "async_poll" ]);

// The three categorical hues plus local inference's neutral-plus-texture
// treatment (§11). A span this build has never heard of still needs a bucket
// — it defaults to "memory" (the least visually loud of the three colours)
// rather than being silently dropped from the chart.
export function categoryFor(operation: string | null | undefined): WaterfallCategory {
  if (!operation) return "memory";
  if (operation === "llm.generate") return "inference";
  if (operation.startsWith("tool.") || HOOK_SPANS.has(operation)) return "mud";
  return "memory";
}
