import { fmtCost, fmtDelta, fmtTokens, pct } from "../format";

// In-transcript chip: live context size as a mini-bar scaled to the context
// window, plus the turn spend accumulating toward its cap.
// Port of log_viz's `ctx_chip` helper.
export default function CtxChip({
  usage,
  running,
  contextWindow,
  maxTurnTokens,
  model,
  provider,
  costUsd,
  modelMs,
  coarse = false,
}: {
  usage: Record<string, unknown> | null | undefined;
  running: number | null | undefined;
  contextWindow: number | null | undefined;
  maxTurnTokens: number | null | undefined;
  model?: string | null;
  provider?: string | null;
  costUsd?: number | null;
  /**
   * The `llm.generate` span's MEASURED duration — `@client.call` alone,
   * neither side's JSON serialization. Absent on a log written before the
   * span existed; the chip simply omits it rather than falling back to the
   * old (systematically inflated) `dt_ms` gap.
   */
  modelMs?: number | null;
  coarse?: boolean;
}) {
  if (!usage) return null;

  const input = Number(usage.input_tokens ?? 0);
  const out = Number(usage.output_tokens ?? 0);
  const cache = Number(usage.cache_read_input_tokens ?? 0);
  const hasTurnBudget = (maxTurnTokens ?? 0) > 0;
  const danger = hasTurnBudget && (running ?? 0) > (maxTurnTokens ?? 0);

  return (
    <span className="ctx-chip">
      {hasTurnBudget && (
        <>
          <span className={danger ? "ctx-turn danger" : "ctx-turn"}>
            turn {fmtTokens(running)}/{fmtTokens(maxTurnTokens)}
          </span>
          <span className="ctx-bar">
            <span
              className={danger ? "ctx-bar-fill danger" : "ctx-bar-fill"}
              style={{ width: `${pct(running, maxTurnTokens)}%` }}
            />
          </span>
        </>
      )}
      <span className="ctx-amt">ctx {fmtTokens(input)}</span>
      {(contextWindow ?? 0) > 0 && (
        <span className="ctx-mini">
          <span className="ctx-mini-fill" style={{ width: `${pct(input, contextWindow)}%` }} />
        </span>
      )}
      <span className="ctx-out">+{fmtTokens(out)} out</span>
      {cache > 0 && <span className="ctx-cache">cached {fmtTokens(cache)}</span>}
      {costUsd != null && <span className="ctx-cost">{fmtCost(costUsd)}</span>}
      {modelMs != null && (
        <span className="ctx-model-ms" title="measured llm.generate span duration">
          {fmtDelta(modelMs, coarse)}
        </span>
      )}
      {(provider || model) && (
        <span className="ctx-model">{[provider, model].filter(Boolean).join(" / ")}</span>
      )}
    </span>
  );
}
