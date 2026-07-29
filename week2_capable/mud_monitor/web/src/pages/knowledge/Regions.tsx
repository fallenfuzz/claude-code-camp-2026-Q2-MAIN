import { Link } from "react-router";
import { fetchKnowledgeRegions } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { formatTime } from "../../format";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";
import type { KnowledgeRegion } from "../../api/types";

/**
 * The places the agent named, and the edges it named them at.
 *
 * This page exists because the map's region tint is simultaneously the most
 * authoritative-looking thing that canvas will ever draw and the least earned:
 * membership is DERIVED and rewritten wholesale on every recompute, while a
 * boundary is EARNED — the agent stood in a room and said a different place
 * starts here. Keeping that distinction in front of the reader is the whole
 * job here, so every declared edge is listed with the reason given for it, and
 * a misplaced boundary is one click from the room it was declared in.
 *
 * The failure this makes visible is boundaries_revised.md §9's first row: a
 * late split only fixes what is downstream of it, so a room reached by a route
 * that does not pass through the split room keeps the region it inherited. On
 * the map that is a cell of the wrong tint on the wrong side of a line; here it
 * is a member row whose basis says `inherited` in a region it should not be in.
 */
export default function Regions() {
  const href = useKnowledgeHref();
  const session = useKnowledgeSession();
  const { data, error } = usePolling(() => fetchKnowledgeRegions(session), [ session ]);
  useReportEnvelope(data);

  if (error) return <p className="error">Failed to read regions: {error}</p>;
  if (!data) return <p>Loading…</p>;
  if (!data.attached) return <KnowledgeEmpty />;

  // A pre-V5 file has no regions table at all, which is served rather than
  // rejected — the reader gates the SELECT on the file's own version.
  if ((data.schema_version ?? 0) < 5) {
    return (
      <p className="empty">
        This memory file predates regions (schema v{data.schema_version ?? "?"}). Nothing is missing — the
        agent that wrote it had nowhere to record where one place stops and the next begins.
      </p>
    );
  }

  if (data.count === 0) {
    return (
      <p className="empty">
        No regions yet. The agent has not stood anywhere long enough for a room to be recorded.
      </p>
    );
  }

  const byId = new Map<number, KnowledgeRegion>(data.regions.map((r) => [ r.id, r ]));
  const unconfirmed = data.regions.filter((r) => !r.confirmed).length;
  const declared = data.regions.reduce((n, r) => n + r.boundaries.length, 0);

  return (
    <>
      <p className="meta">
        <strong>{data.count}</strong> region{data.count === 1 ? "" : "s"} · {declared} declared boundar
        {declared === 1 ? "y" : "ies"}
        {unconfirmed > 0 && (
          <>
            {" · "}
            <span className="map-warn" title="still carrying a machine-made ⟨from …⟩ label">
              {unconfirmed} unconfirmed
            </span>
          </>
        )}
        . Membership is derived from first-arrival edges and rewritten on every recompute; the boundaries
        below are what the agent actually declared.
      </p>

      {data.regions.map((region) => {
        const parent = region.parent_id == null ? null : byId.get(region.parent_id);
        const inherited = region.rooms.filter((r) => r.basis === "inherited").length;
        return (
          <section key={region.id} className="knowledge-region">
            <h3>
              {region.label}
              {!region.confirmed && (
                <span className="tag" title="a machine-made label — provenance, not a claim about the world">
                  unconfirmed
                </span>
              )}
            </h3>

            <p className="meta">
              {region.room_count} room{region.room_count === 1 ? "" : "s"} ({inherited} inherited,{" "}
              {region.room_count - inherited} declared)
              {parent && (
                <>
                  {" · within "}
                  <strong>{parent.label}</strong>
                </>
              )}
              {region.seed_room_id != null && (
                <>
                  {" · seeded at "}
                  <Link to={href(`/knowledge/rooms/${region.seed_room_id}`)}>#{region.seed_room_id}</Link>
                </>
              )}
              {" · "}
              <span title={region.updated_at}>updated {formatTime(region.updated_at)}</span>
            </p>

            {region.description && <p className="knowledge-region-description">{region.description}</p>}

            {region.boundaries.length === 0 ? (
              <p className="muted-cell">
                No declared boundary. This region was seeded on a room reached with no arrival edge — a cold
                start, a flee, or a teleport — rather than split from a neighbour.
              </p>
            ) : (
              <table className="manager">
                <thead>
                  <tr>
                    <th>Declared at</th>
                    <th className="nowrap">Edge</th>
                    <th>Reason given</th>
                    <th className="nowrap">When</th>
                  </tr>
                </thead>
                <tbody>
                  {region.boundaries.map((b) => (
                    <tr key={b.id}>
                      <td>
                        <Link to={href(`/knowledge/rooms/${b.to_room_id}`)}>{b.to_room_name}</Link>
                      </td>
                      <td className="nowrap">
                        <Link to={href(`/knowledge/rooms/${b.from_room_id}`)}>{b.from_room_name}</Link>
                        {` —${b.direction}→`}
                      </td>
                      <td>{b.reason ?? <span className="muted-cell">none given</span>}</td>
                      <td className="nowrap" title={b.declared_at}>
                        {formatTime(b.declared_at)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </section>
        );
      })}
    </>
  );
}
