import { useEffect, useState } from "react";
import { Link } from "react-router";
import { ApiRequestError, fetchReports } from "../api/client";
import type { ReportSummary } from "../api/types";
import { fmtCost, fmtDuration, formatTime, truncate } from "../format";

// One row per RUN — one `boukensha -ts …` invocation, N cases.
//
// The load-bearing display decision is the settings-digest separator. A batch
// of 20 is a measurement of ONE configuration, and a table that silently
// interleaves two of them invites exactly the wrong comparison — "it got worse
// after my prompt edit" when what changed was the model. So runs whose digest
// differs from the row above are visually separated rather than sorted
// together and hoped about.
export default function Reports() {
  const [reports, setReports] = useState<ReportSummary[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [dir, setDir] = useState<string | null>(null);

  useEffect(() => {
    fetchReports()
      .then((body) => {
        setReports(body.reports);
        setDir(body.dir);
      })
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, []);

  return (
    <>
      <h1>Test reports</h1>

      {error && <p className="error">Failed to load reports: {error}</p>}
      {!error && reports === null && <p>Loading…</p>}

      {reports && reports.length === 0 && (
        <p className="empty">
          No test runs yet. Run one with <code>boukensha -ts find_bakery --batch 20</code>
          {dir && <> — reports land in <code>{dir}</code>.</>}
        </p>
      )}

      {reports && reports.length > 0 && (
        <table className="reports">
          <thead>
            <tr>
              <th>When</th>
              <th>Run</th>
              <th>Profile</th>
              <th>Model</th>
              <th>Pass rate</th>
              <th className="nowrap">Cases</th>
              <th className="nowrap">Duration</th>
              <th className="nowrap">Cost</th>
            </tr>
          </thead>
          <tbody>
            {reports.map((report, i) => {
              const previous = reports[i - 1];
              const newConfig = i > 0 && previous.settings_digest !== report.settings_digest;
              return (
                <tr key={report.id} className={newConfig ? "config-boundary" : undefined}>
                  <td className="nowrap" title={newConfig ? "a different configuration from the run above" : undefined}>
                    {formatTime(report.started_at)}
                  </td>
                  <td>
                    <Link to={`/reports/${report.id}`}>{report.name}</Link>
                    <span className="report-kind"> {report.kind}</span>
                    {report.git_sha && <div className="report-sha">{report.git_sha}</div>}
                  </td>
                  <td>{truncate(report.profile, 24)}</td>
                  <td className="model-list">{truncate([report.provider, report.model].filter(Boolean).join(" / "), 32)}</td>
                  <td>
                    <PassBar report={report} />
                  </td>
                  <td className="nowrap">
                    {report.passed}/{report.cases}
                    {report.errored > 0 && (
                      <span className="limit-flag" title={`${report.errored} errored — a broken harness is not a failing agent`}>
                        !
                      </span>
                    )}
                  </td>
                  <td className="nowrap">{fmtDuration(durationOf(report))}</td>
                  <td className="nowrap">{fmtCost(report.cost_usd)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </>
  );
}

function PassBar({ report }: { report: ReportSummary }) {
  if (report.pass_rate == null) return <span>—</span>;

  const cases = Math.max(report.cases, 1);
  const width = (n: number) => `${(n / cases) * 100}%`;

  return (
    <div className="pass-bar" title={`${report.passed} passed, ${report.failed} failed, ${report.errored} errored`}>
      <div className="pass-bar-track">
        <span className="pass-seg pass" style={{ width: width(report.passed) }} />
        <span className="pass-seg fail" style={{ width: width(report.failed) }} />
        <span className="pass-seg error" style={{ width: width(report.errored) }} />
      </div>
      <span className="pass-bar-label">{Math.round(report.pass_rate * 100)}%</span>
    </div>
  );
}

function durationOf(report: ReportSummary): number | null {
  if (!report.started_at || !report.ended_at) return null;
  const ms = new Date(report.ended_at).getTime() - new Date(report.started_at).getTime();
  return Number.isNaN(ms) ? null : ms;
}
