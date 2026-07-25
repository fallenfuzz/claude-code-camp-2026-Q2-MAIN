import type { CostBreakdownRow } from "../api/types";
import { fmtCostCell, fmtDuration, fmtTokens } from "../format";

// Port of log_viz session.erb's cost-by-task-and-model table.
export default function CostTable({ rows }: { rows: CostBreakdownRow[] }) {
  if (rows.length === 0) return null;

  return (
    <div className="breakdown">
      <div className="breakdown-title">Cost by task / provider / model</div>
      <table className="breakdown-table">
        <thead>
          <tr>
            <th>Task</th>
            <th>Provider</th>
            <th>Model</th>
            <th className="nowrap">Calls</th>
            <th className="nowrap">Tokens</th>
            <th className="nowrap">Cost</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={`${row.task}-${row.provider}-${row.model}`}>
              <td>{row.task}</td>
              <td>{row.provider}</td>
              <td>{row.model}</td>
              <td className="nowrap">{row.calls}</td>
              <td className="nowrap">
                {/* A local model has no tokens to report — its price is paid in
                    latency, so that is what stands in this column rather than a
                    misleading "0 / 0". */}
                {row.duration_ms != null ? (
                  <span title="local inference — latency, not tokens">{fmtDuration(row.duration_ms)}</span>
                ) : (
                  <>
                    {fmtTokens(row.input)} / {fmtTokens(row.output)}
                  </>
                )}
                {/* Calls where the artifact was not installed. The row is still
                    here — silence would read as "the model found nothing". */}
                {row.unavailable != null && row.unavailable > 0 && (
                  <span className="tool-badge" title="the model artifact was not installed">
                    {row.unavailable} unavailable
                  </span>
                )}
              </td>
              <td className="nowrap">{fmtCostCell(row.cost, row.cost_known)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
