import { Link, useParams } from "react-router";
import { fetchKnowledgeRoom } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import FingerprintCode from "../../components/FingerprintCode";
import ThreatChip from "../../components/ThreatChip";
import { formatTime } from "../../format";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";

export default function RoomDetail() {
  const href = useKnowledgeHref();
  const { id } = useParams();
  const session = useKnowledgeSession();
  const { data, error } = usePolling(() => fetchKnowledgeRoom(id ?? "", session), [ id, session ]);
  useReportEnvelope(data);

  if (error) return <p className="error">Failed to read room: {error}</p>;
  if (!data) return <p>Loading…</p>;

  const { room, entities, encounters, inbound } = data;

  return (
    <>
      <Link to={href("/knowledge/rooms")} className="back">
        ← all rooms
      </Link>

      <h2>
        {room.name}
        {room.confidence === "provisional" && <span className="tag tag-provisional">provisional</span>}
        {!room.surveyed_at && <span className="tag">unsurveyed</span>}
      </h2>

      <pre className="room-description-full">{room.description}</pre>

      <dl className="knowledge-facts">
        <dt>Visits</dt>
        <dd>{room.visit_count}</dd>
        <dt>First seen</dt>
        <dd>{formatTime(room.first_seen_at)}</dd>
        <dt>Last seen</dt>
        <dd>{formatTime(room.last_seen_at)}</dd>
        <dt>Surveyed</dt>
        <dd>{room.surveyed_at ? formatTime(room.surveyed_at) : <span className="muted-cell">never</span>}</dd>
        <dt>Look targets</dt>
        <dd>
          {room.look_candidates.length === 0 ? (
            <span className="muted-cell">none</span>
          ) : (
            room.look_candidates.map((c) => (
              <span key={c} className="tag">
                {c}
              </span>
            ))
          )}
        </dd>
        {/* Two rooms that look identical to the agent will share a weak
            fingerprint. When a room on this tab looks wrong, comparing these is
            how you find out why. */}
        <dt>Fingerprints</dt>
        <dd>
          weak <FingerprintCode value={room.weak_fingerprint} /> · strong{" "}
          <FingerprintCode value={room.strong_fingerprint} />
        </dd>
      </dl>

      <h3>Exits</h3>
      {room.exits.length === 0 && <p className="empty">No exits recorded.</p>}
      {room.exits.length > 0 && (
        <table className="manager">
          <thead>
            <tr>
              <th>Direction</th>
              <th>Leads to</th>
              <th className="nowrap">Walked</th>
              <th className="nowrap">Last seen</th>
            </tr>
          </thead>
          <tbody>
            {room.exits.map((exit) => (
              <tr key={exit.direction} className={exit.target_room_id == null ? "exit-row-frontier" : ""}>
                <td className="nowrap">{exit.direction}</td>
                <td>
                  {exit.target_room_id != null ? (
                    <Link to={href(`/knowledge/rooms/${exit.target_room_id}`)}>
                      {exit.target_name ?? `#${exit.target_room_id}`}
                    </Link>
                  ) : (
                    <>
                      {exit.target_name ?? <span className="muted-cell">unnamed</span>}
                      <span className="tag tag-frontier">frontier</span>
                    </>
                  )}
                </td>
                <td className="nowrap">{exit.traversals}×</td>
                <td className="nowrap">{formatTime(exit.last_seen_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {/* What the room's own row cannot say: how you get here. */}
      <h3>Reached from</h3>
      {inbound.length === 0 && (
        <p className="empty">Nothing known leads here — the agent has not walked into this room from anywhere.</p>
      )}
      {inbound.length > 0 && (
        <ul className="knowledge-list">
          {inbound.map((from) => (
            <li key={`${from.room_id}-${from.direction}`}>
              <Link to={href(`/knowledge/rooms/${from.room_id}`)}>{from.room_name}</Link>{" "}
              <span className="muted-cell">going {from.direction}</span>
            </li>
          ))}
        </ul>
      )}

      <h3>Seen here</h3>
      {entities.length === 0 && <p className="empty">Nothing recorded in this room.</p>}
      {entities.length > 0 && (
        <table className="manager">
          <thead>
            <tr>
              <th className="nowrap">Kind</th>
              <th>Description</th>
              <th>Threat</th>
              <th className="nowrap">Seen here</th>
            </tr>
          </thead>
          <tbody>
            {entities.map((entity) => (
              <tr key={entity.id}>
                <td className="nowrap">{entity.kind}</td>
                <td>
                  {entity.descr}
                  {entity.keyword && <code className="entity-keyword">{entity.keyword}</code>}
                </td>
                <td>
                  {entity.kind === "mob" ? (
                    <ThreatChip threat={entity.threat} level={entity.threat_level} />
                  ) : (
                    <span className="muted-cell">—</span>
                  )}
                </td>
                {/* A mob does not belong to a room, it was merely in it when we
                    looked — so these are this room's counters, not the type's. */}
                <td className="nowrap">
                  {entity.sighting_count ?? 0}× {(entity.count ?? 1) > 1 && `(${entity.count} at once)`}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <h3>Encounters</h3>
      {encounters.length === 0 && <p className="empty">No fights recorded here.</p>}
      {encounters.length > 0 && (
        <table className="manager">
          <thead>
            <tr>
              <th className="nowrap">When</th>
              <th>Against</th>
              <th className="nowrap">Outcome</th>
              <th className="nowrap">At level</th>
              <th className="nowrap">HP</th>
            </tr>
          </thead>
          <tbody>
            {encounters.map((fight) => (
              <tr key={fight.id} className={fight.outcome === "died" ? "manager-row-error" : ""}>
                <td className="nowrap">{formatTime(fight.at)}</td>
                <td>{fight.entity_descr ?? <span className="muted-cell">unknown</span>}</td>
                <td className="nowrap">{fight.outcome ?? "—"}</td>
                <td className="nowrap">{fight.player_level ?? "?"}</td>
                <td className="nowrap">
                  {fight.hp_before ?? "?"} → {fight.hp_after ?? "?"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
