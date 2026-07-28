import { useEffect, useMemo, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { ApiRequestError, fetchSessions } from "../api/client";
import type { SessionSummary } from "../api/types";
import LaunchBadge from "../components/LaunchBadge";
import TaskChip from "../components/TaskChip";
import { fmtCost, fmtDuration, formatTime, pct, truncate } from "../format";

// Port of week1_baseline/log_viz/views/index.erb, plus the provenance column
// (batch_sesssion_testing.md §7.1).
//
// Two changes the moment batch runs exist: the list gains a `mode` column,
// because otherwise a hand-driven exploration and one of twenty automated cases
// are indistinguishable; and the session NAME becomes the primary label with
// the raw id demoted to a subtitle, because a column of
// `20260728T143241Z-fef86633` is unreadable at twenty rows and that is the
// whole reason naming exists.
export default function Sessions() {
  const [sessions, setSessions] = useState<SessionSummary[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  // Client-side over the payload the list already fetches — no new endpoint for
  // a filter over data that is entirely in hand.
  const [params, setParams] = useSearchParams();
  const modeFilter = params.get("mode") ?? "";
  const scenarioFilter = params.get("scenario") ?? "";

  useEffect(() => {
    fetchSessions()
      .then((body) => setSessions(body.sessions))
      .catch((err) => setError(err instanceof ApiRequestError ? err.message : String(err)));
  }, []);

  const visible = useMemo(() => {
    if (!sessions) return null;
    return sessions.filter((s) => {
      if (modeFilter && (s.mode ?? "legacy") !== modeFilter) return false;
      if (scenarioFilter && s.launch?.scenario !== scenarioFilter) return false;
      return true;
    });
  }, [sessions, modeFilter, scenarioFilter]);

  const scenarios = useMemo(
    () => [...new Set((sessions ?? []).map((s) => s.launch?.scenario).filter(Boolean))] as string[],
    [sessions],
  );

  const setFilter = (key: string, value: string) => {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value);
    else next.delete(key);
    setParams(next);
  };

  return (
    <>
      <h1>Sessions</h1>

      {sessions && sessions.length > 0 && (
        <div className="filters">
          <label>
            Mode{" "}
            <select value={modeFilter} onChange={(e) => setFilter("mode", e.target.value)}>
              <option value="">all</option>
              <option value="interactive">human</option>
              <option value="test">test</option>
              <option value="legacy">legacy</option>
            </select>
          </label>
          {scenarios.length > 0 && (
            <label>
              Scenario{" "}
              <select value={scenarioFilter} onChange={(e) => setFilter("scenario", e.target.value)}>
                <option value="">all</option>
                {scenarios.map((name) => (
                  <option key={name} value={name}>
                    {name}
                  </option>
                ))}
              </select>
            </label>
          )}
          <span className="filter-count">
            {visible?.length ?? 0} of {sessions.length}
          </span>
        </div>
      )}

      {error && <p className="error">Failed to load sessions: {error}</p>}

      {!error && sessions === null && <p>Loading…</p>}

      {sessions && sessions.length === 0 && <p className="empty">No session logs found.</p>}

      {visible && visible.length > 0 && (
        <table className="sessions">
          <thead>
            <tr>
              <th className="nowrap">Mode</th>
              <th>Started</th>
              <th className="nowrap">Duration</th>
              <th>Session</th>
              <th>Task</th>
              <th>Model(s)</th>
              <th>Iterations</th>
              <th>Tokens (in / out)</th>
              <th className="nowrap">Peak ctx</th>
              <th className="nowrap">Cost</th>
            </tr>
          </thead>
          <tbody>
            {visible.map((session) => (
              <tr key={session.id}>
                <td className="nowrap">
                  <LaunchBadge launch={session.launch} />
                </td>
                <td className="nowrap">{formatTime(session.started_at)}</td>
                <td className="nowrap duration-cell" title={`ended ${formatTime(session.ended_at)}`}>
                  {fmtDuration(session.duration_ms)}
                </td>
                <td>
                  <Link to={`/sessions/${session.id}`}>{session.name ?? session.id}</Link>
                  {session.any_limit_tripped && (
                    <span className="limit-flag" title="a turn tripped a limit">
                      ⚠
                    </span>
                  )}
                  {session.name && <div className="session-id-sub">{session.id}</div>}
                </td>
                <td className="task">
                  <div className="task-roster">
                    {session.tasks.map((t) => (
                      <TaskChip key={t} task={t} />
                    ))}
                    {session.sub_runs > 0 && (
                      <span className="sub-run-count" title={`${session.sub_runs} delegated sub-runs`}>
                        ⑂ {session.sub_runs}
                      </span>
                    )}
                  </div>
                  <div className="task-goal">{truncate(session.task, 70)}</div>
                </td>
                <td className="model-list">{truncate(session.models.join(", "), 54)}</td>
                <td className="nowrap">{session.iterations}</td>
                <td className="nowrap">
                  {session.input_tokens} / {session.output_tokens}
                </td>
                <td className="nowrap">
                  {session.context_window && session.context_window > 0
                    ? `${pct(session.peak_input_tokens, session.context_window)}%`
                    : "—"}
                </td>
                <td className="nowrap">{fmtCost(session.cost_usd)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
