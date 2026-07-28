import { Link } from "react-router";
import type { SessionLaunch } from "../api/types";

// How a session was started, at a glance.
//
// Today a hand-driven exploration and an automated case are indistinguishable
// in the session list, and the moment batch runs exist that list is 95% robot.
// This is the one column that makes it readable again.
//
// A log written before the provenance contract renders as "—" rather than as a
// guess: "we cannot say" and "a human ran it" are different answers, and the
// same distinction `has_provenance` already draws for tool calls.
export default function LaunchBadge({ launch }: { launch: SessionLaunch | null }) {
  if (!launch) {
    return (
      <span className="launch-badge launch-legacy" title="written before the provenance contract — unknown">
        —
      </span>
    );
  }

  if (launch.mode === "test") {
    const label = (
      <span className="launch-badge launch-test" title={testTitle(launch)}>
        test
      </span>
    );
    // A case belongs to a run, so the badge IS the link back to the report it
    // came from — the join key already travels in the launch object.
    return launch.run_id ? <Link to={`/reports/${launch.run_id}`}>{label}</Link> : label;
  }

  return (
    <span className="launch-badge launch-human" title={`run by ${launch.runner}`}>
      human
    </span>
  );
}

function testTitle(launch: SessionLaunch): string {
  return [
    launch.scenario && `scenario: ${launch.scenario}`,
    launch.plan && `plan: ${launch.plan}`,
    launch.case_index && launch.batch_size && `case ${launch.case_index} of ${launch.batch_size}`,
    launch.map_memory && `map: ${launch.map_memory}`,
  ]
    .filter(Boolean)
    .join(" · ");
}
