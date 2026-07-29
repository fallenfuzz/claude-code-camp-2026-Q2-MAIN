import { useState } from "react";
import { Link } from "react-router";
import { fetchKnowledgeRooms } from "../../api/client";
import type { KnowledgeExit } from "../../api/types";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { formatTime, truncate } from "../../format";
import { useDebouncedValue } from "../../useDebouncedValue";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";

const FILTERS = [
  { value: "", label: "all" },
  { value: "surveyed", label: "surveyed" },
  { value: "unsurveyed", label: "unsurveyed" },
  { value: "provisional", label: "provisional" },
];

const MAX_VISIBLE_ENTITIES = 3;

// An exit whose destination is known links; one whose destination has never
// been walked renders as plain text. That difference is the frontier, and
// making it a link-vs-not distinction means it reads correctly everywhere
// without a legend.
function ExitList({ exits }: { exits: KnowledgeExit[] }) {
  const href = useKnowledgeHref();
  if (exits.length === 0) return <span className="muted-cell">none</span>;

  return (
    <span className="exit-list">
      {exits.map((exit) => (
        <span key={exit.direction} className={exit.target_room_id == null ? "exit exit-frontier" : "exit"}>
          <span className="exit-dir">{exit.direction}</span>
          {exit.target_room_id != null ? (
            <Link to={href(`/knowledge/rooms/${exit.target_room_id}`)}>{exit.target_name ?? `#${exit.target_room_id}`}</Link>
          ) : (
            <span title="never walked — this is the frontier">{exit.target_name ?? "?"}</span>
          )}
        </span>
      ))}
    </span>
  );
}

export default function Rooms() {
  const href = useKnowledgeHref();
  const [ q, setQ ] = useState("");
  const [ filter, setFilter ] = useState("");
  const debouncedQ = useDebouncedValue(q);
  const session = useKnowledgeSession();
  const { data, error } = usePolling(
    () => fetchKnowledgeRooms({ q: debouncedQ || undefined, filter: filter || undefined }, session),
    [ debouncedQ, filter, session ],
  );
  useReportEnvelope(data);

  return (
    <>
      <div className="manager-filters">
        <label>
          Search
          <input type="text" value={q} onChange={(e) => setQ(e.target.value)} placeholder="name or description" />
        </label>
        <label>
          Show
          <select value={filter} onChange={(e) => setFilter(e.target.value)}>
            {FILTERS.map((f) => (
              <option key={f.value} value={f.value}>
                {f.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      {error && <p className="error">Failed to read rooms: {error}</p>}
      {!error && !data && <p>Loading…</p>}
      {data && !data.attached && <KnowledgeEmpty />}
      {data?.attached && data.rooms.length === 0 && <p className="empty">No rooms match.</p>}

      {data?.attached && data.rooms.length > 0 && (
        <table className="manager knowledge-rooms">
          <thead>
            <tr>
              <th className="nowrap">#</th>
              <th>Room</th>
              <th>Exits</th>
              <th className="nowrap">Visits</th>
              <th>Entities seen</th>
              <th>Look targets</th>
              <th className="nowrap">Last seen</th>
            </tr>
          </thead>
          <tbody>
            {data.rooms.map((room) => (
              <tr key={room.id} className={room.confidence === "provisional" ? "room-provisional" : ""}>
                <td className="nowrap">
                  <Link to={href(`/knowledge/rooms/${room.id}`)}>{room.id}</Link>
                </td>
                <td>
                  <Link to={href(`/knowledge/rooms/${room.id}`)}>{room.name}</Link>
                  {room.confidence === "provisional" && (
                    <span className="tag tag-provisional" title="the fingerprint resolver is not sure this is one room">
                      provisional
                    </span>
                  )}
                  {!room.surveyed_at && (
                    <span className="tag" title="never surveyed — exits and contents may be incomplete">
                      unsurveyed
                    </span>
                  )}
                  <div className="room-description" title={room.description}>
                    {truncate(room.description, 90)}
                  </div>
                </td>
                <td>
                  <ExitList exits={room.exits} />
                </td>
                <td className="nowrap">{room.visit_count}</td>
                <td>
                  {room.entities.length === 0 ? (
                    <span className="muted-cell">—</span>
                  ) : (
                    <>
                      {room.entities.slice(0, MAX_VISIBLE_ENTITIES).map((entity) => (
                        <span key={entity.id} className="tag" title={entity.descr}>
                          {entity.keyword || entity.descr}
                        </span>
                      ))}
                      {room.entities.length > MAX_VISIBLE_ENTITIES && (
                        <span
                          className="tag"
                          title={`${room.entities.length - MAX_VISIBLE_ENTITIES} more shown on the room page`}
                        >
                          +{room.entities.length - MAX_VISIBLE_ENTITIES}
                        </span>
                      )}
                    </>
                  )}
                </td>
                <td>
                  {room.look_candidates.length === 0 ? (
                    <span className="muted-cell">—</span>
                  ) : (
                    room.look_candidates.map((c) => (
                      <span key={c} className="tag">
                        {c}
                      </span>
                    ))
                  )}
                </td>
                <td className="nowrap" title={room.last_seen_at}>
                  {formatTime(room.last_seen_at)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
