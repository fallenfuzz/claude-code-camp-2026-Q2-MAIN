import { createContext, useContext, useEffect, useState } from "react";
import { NavLink, Outlet } from "react-router";
import type { KnowledgeEnvelope } from "../../api/types";
import { fmtBytes, formatTime } from "../../format";

// Each sub-view fetches its own payload, and every knowledge payload carries
// the same envelope — so rather than the shell making a second request just to
// render one badge, children publish the envelope they already have.
const ReportEnvelope = createContext<(envelope: KnowledgeEnvelope | null) => void>(() => {});

export function useReportEnvelope(envelope: KnowledgeEnvelope | null | undefined) {
  const report = useContext(ReportEnvelope);
  useEffect(() => {
    report(envelope ?? null);
  }, [ report, envelope ]);
}

const TABS = [
  { to: "/knowledge", end: true, label: "Overview" },
  { to: "/knowledge/rooms", end: false, label: "Rooms" },
  { to: "/knowledge/map", end: true, label: "Map" },
  { to: "/knowledge/entities", end: true, label: "Entities" },
  { to: "/knowledge/frontier", end: true, label: "Frontier" },
  { to: "/knowledge/player", end: true, label: "Player" },
  { to: "/knowledge/progression", end: true, label: "Progression" },
];

// The agent's world memory — the first page in this monitor that is not a log.
// Sessions, telnet and manager all answer "what happened, in what order".
// This answers "what does the agent currently believe", which is a different
// kind of thing: no cursor, no ordering, and it changes underneath you.
export default function Knowledge() {
  const [ envelope, setEnvelope ] = useState<KnowledgeEnvelope | null>(null);

  return (
    <>
      <h1>
        Knowledge
        {envelope?.attached && (
          <span className={`live-badge live-badge-${envelope.live ? "connected" : "ended"}`}>
            <span className="live-badge-dot" />
            {envelope.live ? "live" : "idle"}
          </span>
        )}
      </h1>
      <p className="meta">
        What the agent believes about the world, read from <code>knowledge.sqlite3</code>. Everything here is
        belief, not fact — including the rooms it identified wrongly.
      </p>

      <nav className="subnav">
        {TABS.map((tab) => (
          <NavLink
            key={tab.to}
            to={tab.to}
            end={tab.end}
            className={({ isActive }) => (isActive ? "subnav-link subnav-link-active" : "subnav-link")}
          >
            {tab.label}
          </NavLink>
        ))}
      </nav>

      <ReportEnvelope.Provider value={setEnvelope}>
        <Outlet />
      </ReportEnvelope.Provider>

      {envelope?.attached && (
        <p className="knowledge-footer">
          last write {formatTime(envelope.last_write_at)} · schema v{envelope.schema_version}
          {/* The WAL only shrinks on checkpoint, which the reader cannot do
              (query_only). Surfaced so unbounded growth is noticed here before
              it becomes a problem for the writer. */}
          {envelope.wal_bytes != null && ` · wal ${fmtBytes(envelope.wal_bytes)}`}
        </p>
      )}
    </>
  );
}
