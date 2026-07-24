import { Link } from "react-router";
import { fetchKnowledge } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { formatTime } from "../../format";
import { useReportEnvelope } from "./Knowledge";

function Tile({ label, value, sub }: { label: string; value: string | number; sub?: string }) {
  return (
    <div className="stat-tile">
      <div className="stat-tile-label">{label}</div>
      <div className="stat-tile-value">{value}</div>
      {sub && <div className="stat-tile-sub">{sub}</div>}
    </div>
  );
}

export default function Overview() {
  const { data, error } = usePolling(() => fetchKnowledge(), []);
  useReportEnvelope(data);

  if (error) return <p className="error">Failed to read knowledge: {error}</p>;
  if (!data) return <p>Loading…</p>;
  if (!data.attached) return <KnowledgeEmpty />;

  const { stats, player } = data;

  return (
    <>
      <div className="stat-grid">
        <Tile label="Rooms known" value={stats.rooms} sub={`${stats.surveyed} surveyed`} />
        {/* The honest measure of exploration: doors the agent has seen named
            but never walked through. */}
        <Tile
          label="Frontier"
          value={stats.frontier}
          sub={`of ${stats.exits} exits · ${stats.traversed} walked`}
        />
        <Tile label="Entities" value={stats.entities} sub={`${stats.mobs} mobs · ${stats.objects} objects`} />
        <Tile label="Encounters" value={stats.encounters} />
        {stats.provisional > 0 && (
          <Tile label="Provisional" value={stats.provisional} sub="rooms it is unsure about" />
        )}
      </div>

      <h2>Player</h2>
      {!player && <p className="empty">No player state recorded yet — the agent has not looked around.</p>}
      {player && (
        <>
          <div className="stat-grid">
            <Tile label="HP" value={`${player.hp ?? "?"} / ${player.max_hp ?? "?"}`} />
            <Tile label="Level" value={player.level ?? "?"} sub={player.position ?? undefined} />
            <Tile label="Mana / Move" value={`${player.mana ?? "?"} / ${player.move ?? "?"}`} />
            <Tile label="Gold" value={player.gold ?? "?"} sub={player.exp != null ? `${player.exp} exp` : undefined} />
          </div>

          <dl className="knowledge-facts">
            <dt>Location</dt>
            <dd>
              {player.current_room ? (
                <Link to={`/knowledge/rooms/${player.current_room.id}`}>{player.current_room.name}</Link>
              ) : (
                <span className="muted-cell">unknown</span>
              )}
              {player.prev_room && (
                <span className="muted-cell">
                  {" "}
                  — came {player.last_direction ?? "?"} from{" "}
                  <Link to={`/knowledge/rooms/${player.prev_room.id}`}>{player.prev_room.name}</Link>
                </span>
              )}
            </dd>

            {/* The join that makes this a monitor page rather than a sqlite3
                one-liner: belief, linked to the transcript that produced it. */}
            <dt>Written by</dt>
            <dd>
              {player.session_id ? (
                <Link to={`/sessions/${player.session_id}`}>{player.session_id}</Link>
              ) : (
                <span className="muted-cell">—</span>
              )}
            </dd>

            <dt>Updated</dt>
            <dd>{formatTime(player.updated_at)}</dd>
          </dl>

          {/* Stale state is not a bug in the monitor, it is a fact about the
              file: player_state survives across runs and a new session must
              re-confirm it with a real look before trusting it. */}
          <p className="meta">
            This row is whatever the last run left behind. On a new session the agent re-confirms its location
            with a real look rather than trusting it.
          </p>
        </>
      )}
    </>
  );
}
