import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { ApiRequestError, fetchReport } from "../api/client";
import type { ReportCase, ReportDetailDocument } from "../api/types";
import { fmtCost, fmtDelta, formatTime } from "../format";

// One run: the environment it measured, the distribution it produced, and every
// case linking back to the session it describes.
export default function ReportDetail() {
  const { id } = useParams();
  const [report, setReport] = useState<ReportDetailDocument | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<number | null>(null);

  useEffect(() => {
    if (!id) return;
    fetchReport(id)
      .then((body) => setReport(body.report))
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, [id]);

  if (error) return <p className="error">Failed to load report: {error}</p>;
  if (!report) return <p>Loading…</p>;

  const { summary, environment } = report;

  return (
    <>
      <h1>
        <Link to="/reports">Reports</Link> / {report.name}
      </h1>

      <div className="report-header">
        <dl className="report-env">
          <dt>Kind</dt>
          <dd>{report.kind}</dd>
          <dt>Started</dt>
          <dd>{formatTime(report.started_at)}</dd>
          <dt>Profile</dt>
          <dd>{String(environment.profile ?? "—")}</dd>
          <dt>Model</dt>
          <dd>
            {String(environment.provider ?? "—")} / {String(environment.model ?? "—")}
          </dd>
          <dt>Judge</dt>
          <dd>{judgeLabel(environment)}</dd>
          <dt>Version</dt>
          <dd>
            {String(environment.boukensha_version ?? "—")}
            {environment.git_sha ? ` @ ${environment.git_sha}` : ""}
          </dd>
          {/* The field that decides whether comparing this run to another is
              meaningful at all. Shown in full rather than truncated, because a
              digest you cannot compare character-for-character is decoration. */}
          <dt>Settings digest</dt>
          <dd className="mono digest">{String(environment.settings_digest ?? "—")}</dd>
        </dl>

        <div className="report-summary">
          <div className="stat">
            <span className="stat-value">{summary.pass_rate == null ? "—" : `${Math.round(summary.pass_rate * 100)}%`}</span>
            <span className="stat-label">
              {summary.passed} passed · {summary.failed} failed · {summary.errored} errored
            </span>
          </div>
          <div className="stat">
            <span className="stat-value">{fmtCost(summary.cost_usd.total)}</span>
            <span className="stat-label">
              agent {fmtCost(summary.cost_usd.agent)} · judge {fmtCost(summary.cost_usd.judge)}
            </span>
          </div>
          <div className="stat">
            {/* Variance IS the measurement. A single number would hide the one
                thing --batch 20 was run to see. */}
            <span className="stat-value">
              {summary.median.model_tool_calls ?? "—"} / {summary.p90.model_tool_calls ?? "—"}
            </span>
            <span className="stat-label">tool calls, median / p90</span>
          </div>
          <div className="stat">
            <span className="stat-value">{fmtDelta(summary.median.duration_ms)}</span>
            <span className="stat-label">median duration</span>
          </div>
        </div>
      </div>

      <CallsSparkline cases={report.cases} />

      {Object.keys(summary.failure_modes).length > 0 && (
        <>
          <h2>Failure modes</h2>
          <table className="failure-modes">
            <tbody>
              {Object.entries(summary.failure_modes)
                .sort((a, b) => b[1] - a[1])
                .map(([mode, count]) => (
                  <tr key={mode}>
                    <td className="mono">{mode}</td>
                    <td className="nowrap">{count}×</td>
                  </tr>
                ))}
            </tbody>
          </table>
        </>
      )}

      <h2>Cases</h2>
      <table className="report-cases">
        <thead>
          <tr>
            <th>#</th>
            <th>Status</th>
            <th>Session</th>
            <th className="nowrap">Tool calls</th>
            <th className="nowrap">Duration</th>
            <th className="nowrap">Cost</th>
            <th>Failed expectations</th>
          </tr>
        </thead>
        <tbody>
          {report.cases.map((row) => (
            <CaseRows
              key={row.index}
              row={row}
              expanded={expanded === row.index}
              onToggle={() => setExpanded(expanded === row.index ? null : row.index)}
            />
          ))}
        </tbody>
      </table>
    </>
  );
}

function CaseRows({ row, expanded, onToggle }: { row: ReportCase; expanded: boolean; onToggle: () => void }) {
  const failed = (row.expectations ?? []).filter((e) => !e.ok);

  return (
    <>
      <tr className={`case-${row.status}`} onClick={onToggle}>
        <td>{row.index}</td>
        <td className="nowrap">
          <span className={`status-chip status-${row.status}`}>{row.status}</span>
        </td>
        <td>
          {/* The join key. The report links to sessions; it does not duplicate
              them, so the full transcript is always one click away. */}
          {/* `?profile=` is load-bearing, not decoration. Every log in this app
              is scoped to the selected profile, and a run's cases may name a
              DIFFERENT one than the reader currently has chosen (a plan can
              assign `player_profile` per case). Without it this link 404s
              whenever they differ — the session exists, the monitor is just
              looking in another profile's directory. */}
          {row.session_id ? (
            <Link to={`/sessions/${row.session_id}?profile=${encodeURIComponent(row.profile)}`}>
              {row.session_name ?? row.session_id}
            </Link>
          ) : (
            <span className="empty">no session log</span>
          )}
        </td>
        <td className="nowrap">{String(row.facts?.model_tool_calls ?? "—")}</td>
        <td className="nowrap">{fmtDelta(row.facts?.duration_ms as number | null)}</td>
        <td className="nowrap">{fmtCost(row.facts?.cost_usd as number | null)}</td>
        <td className="mono small">
          {row.error ? `${row.error_kind ?? "error"}: ${row.error}` : failed.map((e) => e.rule).join(", ") || "—"}
        </td>
      </tr>

      {expanded && (
        <tr className="case-detail">
          <td colSpan={7}>
            {row.expectations && row.expectations.length > 0 && (
              <>
                <h3>Expectations</h3>
                <ul className="expectations">
                  {row.expectations.map((e, i) => (
                    <li key={i} className={e.ok ? "ok" : "not-ok"}>
                      <span className="mono">
                        {e.kind}: {e.rule}
                      </span>
                      {e.detail && <span className="detail"> — {e.detail}</span>}
                    </li>
                  ))}
                </ul>
              </>
            )}

            {row.judge && (
              <>
                <h3>
                  Judge — {row.judge.verdict}
                  {row.judge.confidence != null && ` (${row.judge.confidence})`}
                  {/* A judge call is itself a session, openable when you
                      distrust a verdict. */}
                  {row.judge.session_id && (
                    <>
                      {" "}
                      <Link to={`/sessions/${row.judge.session_id}?profile=${encodeURIComponent(row.profile)}`}>
                        transcript
                      </Link>
                    </>
                  )}
                </h3>
                <p>{row.judge.reasoning ?? row.judge.error}</p>
              </>
            )}

            <h3>Started from</h3>
            <p className="small">
              state <code>{row.base_initial_state ?? "—"}</code> · map{" "}
              <code>{String(row.map_memory?.mode ?? "—")}</code>
              {row.map_memory?.rooms_at_start != null && ` (${String(row.map_memory.rooms_at_start)} rooms known)`}
            </p>
            <pre className="resolved-state">{JSON.stringify(row.resolved_state ?? {}, null, 2)}</pre>
          </td>
        </tr>
      )}
    </>
  );
}

// Per-case model tool calls across the batch. Reuses nothing from Sparkline.tsx
// because that one is typed to UsagePoint; the shape here is a bare series and
// forcing it through that type would be worse than eight lines of SVG.
function CallsSparkline({ cases }: { cases: ReportCase[] }) {
  const values = cases.map((c) => Number(c.facts?.model_tool_calls ?? 0));
  if (values.length < 2) return null;

  const width = 640;
  const height = 48;
  const max = Math.max(...values, 1);
  const step = width / (values.length - 1);
  const coords = values.map((v, i) => `${Math.round(i * step)},${Math.round(height - (v / max) * (height - 4) - 2)}`).join(" ");

  return (
    <svg className="calls-sparkline" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="model tool calls per case">
      <polyline points={coords} fill="none" strokeWidth="1.5" />
    </svg>
  );
}

function judgeLabel(environment: Record<string, unknown>): string {
  const judge = environment.judge as { provider?: string; model?: string } | undefined;
  if (!judge) return "not run";
  return [judge.provider, judge.model].filter(Boolean).join(" / ") || "—";
}
