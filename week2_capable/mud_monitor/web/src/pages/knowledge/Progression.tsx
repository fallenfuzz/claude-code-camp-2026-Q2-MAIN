import { Link } from "react-router";
import { fetchJournal } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import type { JournalItemEvent, JournalMilestone, JournalPoint } from "../../api/types";
import { formatTime } from "../../format";
import { useReportEnvelope } from "./Knowledge";

// A self-contained line chart over one journal series. It reuses the sparkline
// token styling (.spark / .spark-line) rather than the Sparkline component,
// which is bound to per-iteration token usage — the shape here is a plain
// [{seq, at, value}] time series folded server-side by Journal::Series.
function SeriesChart({ label, points }: { label: string; points: JournalPoint[] }) {
  const numeric = points
    .map((p) => ({ ...p, n: typeof p.value === "number" ? p.value : Number(p.value) }))
    .filter((p) => Number.isFinite(p.n));
  if (numeric.length === 0) return null;

  const latest = numeric[numeric.length - 1].n;
  const values = numeric.map((p) => p.n);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = Math.max(max - min, 1);
  const width = 640;
  const height = 48;
  const step = numeric.length > 1 ? width / (numeric.length - 1) : 0;

  const coords = numeric
    .map((p, i) => {
      const x = Math.round(i * step * 10) / 10;
      const y = Math.round((height - ((p.n - min) / span) * (height - 4) - 2) * 10) / 10;
      return `${x},${y}`;
    })
    .join(" ");

  return (
    <div className="spark-wrap">
      <div className="spark-label">
        {label} · now <strong>{latest}</strong>
        {numeric.length > 1 && (
          <>
            {" "}
            · {min}–{max} over {numeric.length} points
          </>
        )}
      </div>
      {numeric.length > 1 ? (
        <svg className="spark" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" role="img" aria-label={label}>
          <polyline className="spark-line" points={coords} />
        </svg>
      ) : (
        <p className="empty">one reading so far — a line appears once it changes</p>
      )}
    </div>
  );
}

function MilestoneRow({ m }: { m: JournalMilestone }) {
  const tone = m.op === "death" ? "journal-chip-bad" : "journal-chip-good";
  return (
    <li className="journal-event">
      <span className={`journal-chip ${tone}`}>{m.op.replace("_", " ")}</span>
      {m.level != null && <span className="journal-event-meta">level {m.level}</span>}
      <span className="journal-event-at">{formatTime(m.at)}</span>
    </li>
  );
}

function ItemRow({ e }: { e: JournalItemEvent }) {
  const tone = e.op === "drop" ? " journal-chip-bad" : e.op === "acquire" ? " journal-chip-good" : "";
  return (
    <li className="journal-event">
      <span className={`journal-chip${tone}`}>{e.op}</span>
      <span className="journal-event-descr">{e.descr || e.keyword || "an item"}</span>
      {e.qty != null && e.qty !== 1 && <span className="journal-event-meta">×{e.qty}</span>}
      <span className="journal-event-at">{formatTime(e.at)}</span>
    </li>
  );
}

// The stat keys worth a chart, in display order. Generic CDC now journals every
// player_state column (positions, directions, ids, session_id …); only these
// numeric progression/vitals fields get a line — the rest are readable on the
// dedicated Change Log page.
const CHARTED_STATS = [
  "level",
  "exp",
  "exp_to_next",
  "gold",
  "hp",
  "max_hp",
  "mana",
  "max_mana",
  "move",
  "max_move",
  "alignment",
];

export default function Progression() {
  const { data, error } = usePolling(() => fetchJournal(), []);
  // The journal is not knowledge.sqlite3, so it publishes no KnowledgeEnvelope —
  // clear the shell's badge/footer rather than leave another tab's stale one up.
  useReportEnvelope(null);

  if (error) return <p className="error">Failed to read the progression journal: {error}</p>;
  if (!data) return <p>Loading…</p>;

  const { series } = data;
  const statKeys = CHARTED_STATS.filter((k) => series.stats[k]?.length);
  const skillNames = Object.keys(series.skills).sort();
  const nothingToGraph =
    statKeys.length === 0 && skillNames.length === 0 && series.milestones.length === 0 && series.items.length === 0;

  return (
    <>
      <p className="meta">
        Progression over time for <code>{data.date}</code>, from the agent's append-only journal
        {" "}
        <span className={`live-badge live-badge-${data.live ? "connected" : "ended"}`}>
          <span className="live-badge-dot" />
          {data.live ? "live" : "idle"}
        </span>
        . This is the graphed timeline; the full per-record change data lives on the{" "}
        <Link to="/journal">Change Log</Link> page.
      </p>

      {nothingToGraph && (
        <p className="empty">
          Nothing to graph yet. Progression charts appear as the agent levels, earns, fights, and moves items — a
          session that only walked around has no timeline to plot, but its moves are all in the{" "}
          <Link to="/journal">Change Log</Link>.
        </p>
      )}

      {statKeys.length > 0 && (
        <section>
          <h2>Stats over time</h2>
          {statKeys.map((k) => (
            <SeriesChart key={k} label={k} points={series.stats[k]} />
          ))}
        </section>
      )}

      {skillNames.length > 0 && (
        <section>
          <h2>Skills</h2>
          {skillNames.map((name) => (
            <SeriesChart key={name} label={name} points={series.skills[name]} />
          ))}
        </section>
      )}

      {series.milestones.length > 0 && (
        <section>
          <h2>Milestones</h2>
          <ul className="journal-feed">
            {series.milestones.map((m) => (
              <MilestoneRow key={m.seq} m={m} />
            ))}
          </ul>
        </section>
      )}

      {series.items.length > 0 && (
        <section>
          <h2>Item ledger</h2>
          <ul className="journal-feed journal-feed-scroll">
            {series.items.map((e) => (
              <ItemRow key={e.seq} e={e} />
            ))}
          </ul>
        </section>
      )}
    </>
  );
}
