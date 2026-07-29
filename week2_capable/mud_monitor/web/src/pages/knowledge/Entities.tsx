import { useState } from "react";
import { Link } from "react-router";
import { fetchKnowledgeEntities } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import ThreatChip from "../../components/ThreatChip";
import { formatTime } from "../../format";
import { useDebouncedValue } from "../../useDebouncedValue";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";

const KINDS = [
  { value: "", label: "all" },
  { value: "mob", label: "mobs" },
  { value: "object", label: "objects" },
];

// The bestiary. One row per TYPE, not per instance: "A cityguard stands here."
// is a single row however many rooms it patrols, which is what makes the
// appraisal reusable — a cityguard met in a brand-new room costs zero
// consider/examine round trips because this row already answers both questions.
export default function Entities() {
  const href = useKnowledgeHref();
  const [ kind, setKind ] = useState("");
  const [ q, setQ ] = useState("");
  const debouncedQ = useDebouncedValue(q);
  const session = useKnowledgeSession();
  const { data, error } = usePolling(
    () => fetchKnowledgeEntities({ kind: kind || undefined, q: debouncedQ || undefined }, session),
    [ kind, debouncedQ, session ],
  );
  useReportEnvelope(data);

  return (
    <>
      <div className="manager-filters">
        <label>
          Search
          <input type="text" value={q} onChange={(e) => setQ(e.target.value)} placeholder="description or keyword" />
        </label>
        <label>
          Kind
          <select value={kind} onChange={(e) => setKind(e.target.value)}>
            {KINDS.map((k) => (
              <option key={k.value} value={k.value}>
                {k.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      {error && <p className="error">Failed to read entities: {error}</p>}
      {!error && !data && <p>Loading…</p>}
      {data && !data.attached && <KnowledgeEmpty />}
      {data?.attached && data.entities.length === 0 && <p className="empty">Nothing matches.</p>}

      {data?.attached && data.entities.length > 0 && (
        <table className="manager">
          <thead>
            <tr>
              <th className="nowrap">Kind</th>
              <th>Description</th>
              <th>Threat</th>
              <th>Equipment</th>
              <th>Seen in</th>
              <th className="nowrap">Times</th>
              <th className="nowrap">Last seen</th>
            </tr>
          </thead>
          <tbody>
            {data.entities.map((entity) => (
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
                <td>
                  {entity.equipment.length === 0 ? (
                    <span className="muted-cell">—</span>
                  ) : (
                    entity.equipment.map((item) => (
                      <span key={item} className="tag">
                        {item}
                      </span>
                    ))
                  )}
                </td>
                {/* Mobs wander, so this is a list of places it has been, not
                    a home. Ordered most-recent first. */}
                <td>
                  {(entity.sightings ?? []).length === 0 ? (
                    <span className="muted-cell">—</span>
                  ) : (
                    <span className="sighting-list">
                      {(entity.sightings ?? []).map((s) => (
                        <Link key={s.room_id} to={href(`/knowledge/rooms/${s.room_id}`)}>
                          {s.room_name}
                        </Link>
                      ))}
                    </span>
                  )}
                </td>
                <td className="nowrap">{entity.seen_count}</td>
                <td className="nowrap" title={entity.last_seen_at}>
                  {formatTime(entity.last_seen_at)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
