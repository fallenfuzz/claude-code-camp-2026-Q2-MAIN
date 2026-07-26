import type { Entry } from "../../api/types";
import { fmtCost, fmtDelta } from "../../format";

// `◆ look_candidates · 23 scored → 3 kept · 11ms · local, $0`, or the same row
// reading `unavailable` when the weights are not installed.
//
// That second case is the one that matters: a missing artifact degrades to a
// null model that warns once and then returns [] forever, so the session used to
// say nothing at all — and an empty `look_candidates` field read identically
// whether the model was absent or the room simply had nothing worth looking at.
export default function LocalInferenceRow({ entry, coarse }: { entry: Entry; coarse: boolean }) {
  const unavailable = entry.available === false;
  return (
    <div className={unavailable ? "op-inference op-inference-off" : "op-inference"}>
      <span className="op-rollup-icon">◆</span>
      <span className="op-inference-model">{entry.model}</span>
      {unavailable ? (
        <span className="op-inference-off-label" title={entry.reason ?? undefined}>
          unavailable{entry.reason ? ` — ${entry.reason}` : ""}
        </span>
      ) : (
        <span>
          {entry.pool ?? 0} scored → {entry.kept ?? 0} kept
        </span>
      )}
      {entry.duration_ms != null && <span>· {fmtDelta(entry.duration_ms, coarse)}</span>}
      {/* Stated, not omitted: the cost table had no row for this model at all,
          which reads as "no cost information" when the truth is "free". */}
      <span className="op-inference-cost">· {entry.unit ?? "local"}, {fmtCost(entry.cost_usd ?? 0)}</span>
    </div>
  );
}
