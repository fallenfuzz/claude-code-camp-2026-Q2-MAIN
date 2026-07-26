import { fmtCost, fmtDelta } from "../../format";

// The iteration span's summary, replacing the bare "Iteration N" marker: what
// it cost in every currency the log can say — duration (measured, not
// dt_ms-inferred), MUD round trips, and the model spend within it. Absent
// span data (a log written before this plan) degrades to exactly the old
// bare marker.
export default function IterationMarker({
  iteration,
  durationMs,
  mudCalls,
  costUsd,
  coarse,
}: {
  iteration: number;
  durationMs: number | null | undefined;
  mudCalls: number | null | undefined;
  costUsd: number | undefined;
  coarse: boolean;
}) {
  return (
    <div className="iteration-marker">
      Iteration {iteration}
      {durationMs != null && <span className="task-group-meta"> · {fmtDelta(durationMs, coarse)}</span>}
      {mudCalls ? (
        <span className="task-group-meta">
          {" "}
          · {mudCalls} MUD call{mudCalls === 1 ? "" : "s"}
        </span>
      ) : null}
      {costUsd ? <span className="task-group-meta"> · {fmtCost(costUsd)}</span> : null}
    </div>
  );
}
