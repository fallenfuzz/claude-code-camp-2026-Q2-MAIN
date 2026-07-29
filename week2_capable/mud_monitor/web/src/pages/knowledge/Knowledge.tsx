import { createContext, useContext, useEffect, useState } from "react";
import { Link, NavLink, Outlet, useSearchParams } from "react-router";
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

/**
 * Which memory these tabs are reading: a past session's retained map when
 * `?session=` is set, the profile's live file otherwise.
 *
 * It lives in the URL rather than in state because that is what makes a past
 * map something you can paste into chat — the same reason rooms are routes and
 * not a `useState` tab index. Every sub-view passes it to its fetch and lists
 * it in its `usePolling` deps, so changing it reloads rather than showing one
 * world's rooms under another world's banner.
 */
export function useKnowledgeSession(): string | null {
  const [ params ] = useSearchParams();
  return params.get("session");
}

/**
 * Builds a link that stays inside whichever memory is being read.
 *
 * A room link that dropped `?session=` would take a reader from a past map to
 * the live one silently, with a room number that may mean something else there
 * — which is the exact confusion the banner exists to prevent.
 */
export function useKnowledgeHref(): (path: string) => string {
  const session = useKnowledgeSession();
  return (path) => (session ? `${path}?session=${encodeURIComponent(session)}` : path);
}

// `memory: false` marks a tab that does NOT read knowledge.sqlite3 — today only
// Progression, which folds the journal. Those tabs drop `?session=` rather than
// carrying it, because a retained map says nothing about the journal and a
// banner over live data would be a lie.
const TABS = [
  { to: "/knowledge", end: true, label: "Overview", memory: true },
  { to: "/knowledge/rooms", end: false, label: "Rooms", memory: true },
  { to: "/knowledge/map", end: true, label: "Map", memory: true },
  { to: "/knowledge/entities", end: true, label: "Entities", memory: true },
  { to: "/knowledge/frontier", end: true, label: "Frontier", memory: true },
  { to: "/knowledge/regions", end: true, label: "Regions", memory: true },
  { to: "/knowledge/player", end: true, label: "Player", memory: true },
  { to: "/knowledge/progression", end: true, label: "Progression", memory: false },
];

// The agent's world memory — the first page in this monitor that is not a log.
// Sessions, telnet and manager all answer "what happened, in what order".
// This answers "what does the agent currently believe", which is a different
// kind of thing: no cursor, no ordering, and it changes underneath you.
export default function Knowledge() {
  const [ envelope, setEnvelope ] = useState<KnowledgeEnvelope | null>(null);
  const session = useKnowledgeSession();
  const search = session ? `?session=${encodeURIComponent(session)}` : "";

  return (
    <>
      <h1>
        Knowledge
        {envelope?.attached && !session && (
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

      {/* A page that looks exactly like the live map while showing a two-day-old
          one is worse than no page, so the banner is on EVERY tab rather than
          just the one the reader arrived on. */}
      {session && (
        <p className="banner banner-warn">
          Showing the memory <Link to={`/sessions/${encodeURIComponent(session)}`}>session {session}</Link> ended
          with — a past world, not the live one.{" "}
          <Link to="/knowledge">Back to the live map</Link>
        </p>
      )}

      <nav className="subnav">
        {TABS.map((tab) => (
          <NavLink
            key={tab.to}
            to={{ pathname: tab.to, search: tab.memory ? search : "" }}
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
