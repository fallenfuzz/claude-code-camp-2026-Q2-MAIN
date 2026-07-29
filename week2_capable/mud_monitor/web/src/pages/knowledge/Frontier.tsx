import { Link } from "react-router";
import { fetchKnowledgeFrontier } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { formatTime } from "../../format";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";

// Every exit the agent has seen named but never walked through.
//
// `target_room_id IS NULL` is not missing data — it is information the agent
// has never had, and it is the only honest answer to "how much of the world is
// left". Everything else on this tab describes what was found; this describes
// what was not.
export default function Frontier() {
  const href = useKnowledgeHref();
  const session = useKnowledgeSession();
  const { data, error } = usePolling(() => fetchKnowledgeFrontier(session), [ session ]);
  useReportEnvelope(data);

  if (error) return <p className="error">Failed to read frontier: {error}</p>;
  if (!data) return <p>Loading…</p>;
  if (!data.attached) return <KnowledgeEmpty />;

  if (data.count === 0) {
    return (
      <p className="empty">
        No unwalked exits. Every door the agent has seen, it has been through — either it has explored
        everything reachable, or it has not looked at much.
      </p>
    );
  }

  // Grouped by origin room so "I should go back to X and try north" reads as one
  // trip rather than scattered rows.
  const byRoom = new Map<number, typeof data.frontier>();
  for (const exit of data.frontier) {
    const list = byRoom.get(exit.room_id) ?? [];
    list.push(exit);
    byRoom.set(exit.room_id, list);
  }

  return (
    <>
      <p className="meta">
        <strong>{data.count}</strong> unwalked exit{data.count === 1 ? "" : "s"} across {byRoom.size} room
        {byRoom.size === 1 ? "" : "s"}.
      </p>

      <table className="manager">
        <thead>
          <tr>
            <th>From</th>
            <th className="nowrap">Direction</th>
            <th>Said to lead to</th>
            <th className="nowrap">Last seen</th>
          </tr>
        </thead>
        <tbody>
          {[ ...byRoom.entries() ].map(([ roomId, exits ]) =>
            exits.map((exit, i) => (
              <tr key={`${roomId}-${exit.direction}`}>
                <td>
                  {i === 0 && (
                    <>
                      <Link to={href(`/knowledge/rooms/${roomId}`)}>{exit.room_name}</Link>
                      {!exit.room_surveyed && (
                        <span className="tag" title="the room itself was never surveyed">
                          unsurveyed
                        </span>
                      )}
                    </>
                  )}
                </td>
                <td className="nowrap">{exit.direction}</td>
                <td>
                  {/* An exit the MUD never named is still frontier — it just
                      has no label to show. */}
                  {exit.target_name ?? <span className="muted-cell">unnamed</span>}
                </td>
                <td className="nowrap" title={exit.last_seen_at}>
                  {formatTime(exit.last_seen_at)}
                </td>
              </tr>
            )),
          )}
        </tbody>
      </table>
    </>
  );
}
