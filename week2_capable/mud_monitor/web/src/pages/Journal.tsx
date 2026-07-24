import { useState } from "react";
import { Link } from "react-router";
import { fetchJournal } from "../api/client";
import { usePolling } from "../api/usePolling";
import { formatTime } from "../format";

// One raw journal record rendered as a CDC line — the honest view of what is on
// disk. `change` rows show the field transition; `event` rows show the op and
// its payload; `snapshot` rows show the seeded baseline.
function describe(rec: Record<string, unknown>): string {
  const kind = String(rec.kind ?? "");
  const stream = String(rec.stream ?? "");
  if (kind === "change") {
    const from = rec.from == null ? "∅" : JSON.stringify(rec.from);
    return `${stream}.${String(rec.key)}: ${from} → ${JSON.stringify(rec.to)}`;
  }
  if (kind === "event") {
    const rest = Object.fromEntries(
      Object.entries(rec).filter(
        ([k]) => !["kind", "stream", "seq", "session_id", "at", "mono_ms", "op"].includes(k),
      ),
    );
    const payload = Object.keys(rest).length ? ` · ${JSON.stringify(rest)}` : "";
    return `${stream} ${String(rec.op)}${payload}`;
  }
  if (kind === "snapshot") return `${stream} baseline · ${JSON.stringify(rec.values ?? {})}`;
  return JSON.stringify(rec);
}

// The change log — a generic, append-only CDC feed of every mutation to the
// agent's knowledgebase (player stats, rooms, exits, entities, sightings,
// encounters, items). Its own top-level page so it can be read and parsed on
// its own; the Progression subtab under Knowledge is the graphed timeline view
// of the same data.
export default function Journal() {
  const { data, error } = usePolling(() => fetchJournal(), []);
  const [stream, setStream] = useState<string>("all");

  if (error) return <p className="error">Failed to read the change log: {error}</p>;
  if (!data) return <p>Loading…</p>;

  const entries = data.entries ?? [];
  const streams = Array.from(new Set(entries.map((e) => String(e.stream ?? "")))).sort();
  const shown = stream === "all" ? entries : entries.filter((e) => String(e.stream ?? "") === stream);

  return (
    <>
      <h1>
        Change Log
        <span className={`live-badge live-badge-${data.live ? "connected" : "ended"}`}>
          <span className="live-badge-dot" />
          {data.live ? "live" : "idle"}
        </span>
      </h1>
      <p className="meta">
        Generic change data capture over the agent's knowledgebase for <code>{data.date}</code> — every upsert /
        update / delete, in order, emitted only when a value actually changed. Read from{" "}
        <code>.boukensha/journal/*.jsonl</code>. For the graphed timeline of this data, see{" "}
        <Link to="/knowledge/progression">Knowledge → Progression</Link>.
      </p>

      {streams.length > 0 && (
        <div className="journal-filter">
          <button
            type="button"
            className={`journal-filter-chip${stream === "all" ? " journal-filter-chip-active" : ""}`}
            onClick={() => setStream("all")}
          >
            all ({entries.length})
          </button>
          {streams.map((s) => (
            <button
              key={s}
              type="button"
              className={`journal-filter-chip${stream === s ? " journal-filter-chip-active" : ""}`}
              onClick={() => setStream(s)}
            >
              {s} ({entries.filter((e) => String(e.stream ?? "") === s).length})
            </button>
          ))}
        </div>
      )}

      {entries.length === 0 ? (
        <p className="empty">
          Nothing recorded yet today. The change log fills as the agent moves, levels, earns, fights, and moves items
          — an unchanged reading is deliberately not logged.
        </p>
      ) : (
        <table className="journal-table">
          <thead>
            <tr>
              <th>#</th>
              <th>kind</th>
              <th>change</th>
              <th>time</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((rec, i) => {
              const kind = String(rec.kind ?? "");
              return (
                <tr key={`${String(rec.seq)}-${i}`}>
                  <td className="journal-td-seq">{String(rec.seq)}</td>
                  <td>
                    <span className={`journal-chip${kind === "change" ? " journal-chip-good" : ""}`}>{kind}</span>
                  </td>
                  <td className="journal-td-detail">{describe(rec)}</td>
                  <td className="journal-td-at">{formatTime(String(rec.at))}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </>
  );
}
