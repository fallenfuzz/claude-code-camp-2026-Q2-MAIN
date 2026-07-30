import { Link } from "react-router";
import { fetchKnowledgeFrontier } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { formatTime } from "../../format";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";

// Every exit the agent has seen named but never walked through — and, beneath
// it, the ones that stopped counting as frontier.
//
// `target_room_id IS NULL` is not missing data — it is information the agent
// has never had, and it is the only honest answer to "how much of the world is
// left". Everything else on this tab describes what was found; this describes
// what was not.
//
// The presumed table is here rather than on a tab of its own because it is the
// same question answered differently: the MUD names the room behind an exit,
// and where that name matches a room already in memory the exit is routable and
// is NOT exploration. Reading the two lists apart is how you tell "nobody has
// been there" from "something believes it knows, on a name alone" — and the
// third table explains the exits that look resolvable and were refused.
export default function Frontier() {
  const href = useKnowledgeHref();
  const session = useKnowledgeSession();
  const { data, error } = usePolling(() => fetchKnowledgeFrontier(session), [ session ]);
  useReportEnvelope(data);

  if (error) return <p className="error">Failed to read frontier: {error}</p>;
  if (!data) return <p>Loading…</p>;
  if (!data.attached) return <KnowledgeEmpty />;

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
      {data.count === 0 ? (
        <p className="empty">
          No unwalked exits. Every door the agent has seen, it has been through or already knows the room
          behind — either it has explored everything reachable, or it has not looked at much.
        </p>
      ) : (
        <p className="meta">
          <strong>{data.count}</strong> unwalked exit{data.count === 1 ? "" : "s"} across {byRoom.size} room
          {byRoom.size === 1 ? "" : "s"}
          {data.presumed_count > 0 && (
            <>
              {", plus "}
              <strong>{data.presumed_count}</strong> whose destination is presumed from its name — listed
              below, and deliberately not counted here
            </>
          )}
          .
        </p>
      )}

      {data.count > 0 && (
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
      )}

      {/* An exit the MUD named as a room already in memory. Routable, and
          honestly weaker than a traversal — walking it either promotes it or
          disproves it, and either way it stops being a guess. */}
      {data.presumed.length > 0 && (
        <section className="knowledge-region">
          <h3>Presumed destinations</h3>
          <p className="meta">
            The MUD printed a destination name for these exits and it matched a room the agent has stood in.
            Nothing has walked them, so routes over them are ranked behind routes made entirely of walked
            edges — but they are not frontier, because something already knows what is through the door.
          </p>
          <table className="manager">
            <thead>
              <tr>
                <th>From</th>
                <th className="nowrap">Direction</th>
                <th>Named as</th>
                <th>Matched to</th>
                <th className="nowrap">Last seen</th>
              </tr>
            </thead>
            <tbody>
              {data.presumed.map((exit) => (
                <tr key={`${exit.room_id}-${exit.direction}`}>
                  <td>
                    <Link to={href(`/knowledge/rooms/${exit.room_id}`)}>{exit.room_name}</Link>
                  </td>
                  <td className="nowrap">{exit.direction}</td>
                  <td>{exit.target_name ?? <span className="muted-cell">unnamed</span>}</td>
                  <td>
                    <Link to={href(`/knowledge/rooms/${exit.presumed_target_id}`)}>
                      {exit.presumed_target_name ?? `#${exit.presumed_target_id}`}
                    </Link>
                  </td>
                  <td className="nowrap" title={exit.last_seen_at}>
                    {formatTime(exit.last_seen_at)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      {/* Why an obviously-matching exit was left as frontier. A name that once
          identified two rooms is not an identifier, and it is never trusted
          again even where only one candidate is now known. */}
      {data.ambiguous_names.length > 0 && (
        <section className="knowledge-region">
          <h3>Names refused as identifiers</h3>
          <p className="meta">
            These destination names are never matched to a room, so exits carrying them stay in the frontier
            list above however obvious the match looks.
          </p>
          <table className="manager">
            <thead>
              <tr>
                <th>Name</th>
                <th>Why</th>
                <th className="nowrap">Noted</th>
              </tr>
            </thead>
            <tbody>
              {data.ambiguous_names.map((row) => (
                <tr key={row.name}>
                  <td>{row.name}</td>
                  <td>{row.reason}</td>
                  <td className="nowrap" title={row.noted_at}>
                    {formatTime(row.noted_at)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}
