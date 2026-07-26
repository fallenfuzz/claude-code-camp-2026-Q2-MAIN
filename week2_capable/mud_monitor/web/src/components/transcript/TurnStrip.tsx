import type { Entry } from "../../api/types";
import { fmtDelta, fmtTokens, pct, pctRaw } from "../../format";

// The `turn_end` marker: outcome, iteration/token totals, and — when the
// session carries span data — the `turn` span's own measured wall time,
// which is distinct from `entry.duration_ms` (the parser's
// turn_started→turn_end gap, which does not include a final wrap_up call
// that ran past a limit).
export default function TurnStrip({
  entry,
  maxTurnTokens,
  turnDurationMs,
  coarse,
}: {
  entry: Entry;
  maxTurnTokens: number | null | undefined;
  turnDurationMs: number | null | undefined;
  coarse: boolean;
}) {
  const tripped = entry.reason != null && entry.reason !== "completed";
  const hasBar = (maxTurnTokens ?? 0) > 0 && entry.tokens != null;

  return (
    <div className={tripped ? "turn-strip danger" : "turn-strip"}>
      <div className="turn-strip-text">
        {tripped ? "⚠" : "✓"} Turn {entry.turn} · {entry.iterations} iteration
        {entry.iterations === 1 ? "" : "s"}
        {entry.tokens != null && <> · {fmtTokens(entry.tokens)} tok</>}
        {turnDurationMs != null && <> · {fmtDelta(turnDurationMs, coarse)}</>}
        {tripped && <> · {entry.reason}</>}
      </div>
      {hasBar && (
        <>
          <div className="bar">
            <div
              className={tripped ? "bar-fill danger" : "bar-fill"}
              style={{ width: `${pct(entry.tokens, maxTurnTokens)}%` }}
            />
          </div>
          <div className="turn-strip-pct">{pctRaw(entry.tokens, maxTurnTokens)}%</div>
        </>
      )}
    </div>
  );
}
