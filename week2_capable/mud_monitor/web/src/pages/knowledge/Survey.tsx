import { Link } from "react-router";
import { fetchKnowledgeSurvey } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { formatTime } from "../../format";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";
import type { Claim, ClaimStatus } from "../../api/types";

/**
 * What the agent is trying to ESTABLISH, as opposed to what it has recorded.
 *
 * Every other tab under Knowledge is observation: a room was entered, an entity
 * was seen, an exit was walked. A claim is an investigation, and it is the only
 * thing in this file that can be wrong in an interesting way — it carries a
 * confidence, it accumulates evidence for AND against, and it can end up
 * refuted. So the job here is to keep three things in front of the reader that
 * a bare status column would hide: the predicate that actually ran (the
 * statement beside it is prose for a human and proves nothing), the evidence on
 * both sides, and — for anything unfinished — what would still settle it.
 *
 * The features and hints sit on this page rather than tabs of their own because
 * they are the same investigation seen from two more sides. Feature membership
 * is what `circuit_closes` and `connects` are computed over, so a chain
 * assembled wrongly is the likeliest reason a survey walked somewhere strange;
 * and a hint is the guess that moved it there. Splitting them out would make a
 * reader join by hand what the writer already relates.
 */
export default function Survey() {
  const href = useKnowledgeHref();
  const session = useKnowledgeSession();
  const { data, error } = usePolling(() => fetchKnowledgeSurvey(session), [ session ]);
  useReportEnvelope(data);

  if (error) return <p className="error">Failed to read the survey ledger: {error}</p>;
  if (!data) return <p>Loading…</p>;
  if (!data.attached) return <KnowledgeEmpty />;

  // A pre-V7 file has no claims table at all, which is served rather than
  // rejected — the reader gates the SELECT on the file's own version.
  if ((data.schema_version ?? 0) < 7) {
    return (
      <p className="empty">
        This memory file predates the claim ledger (schema v{data.schema_version ?? "?"}). Nothing is missing
        — the agent that wrote it could explore, but it had nowhere to record what it was trying to find out.
      </p>
    );
  }

  if (data.count === 0) {
    return (
      <p className="empty">
        No claims yet. The agent has not been asked to survey anywhere — a claim is opened by{" "}
        <code>move_to(survey: …)</code>, never by ordinary travel.
      </p>
    );
  }

  const settled = data.count - data.open_count;
  const objective = data.claims.find((c) => c.objective)?.objective;

  return (
    <>
      <p className="meta">
        <strong>{data.count}</strong> claim{data.count === 1 ? "" : "s"} · {settled} settled ·{" "}
        {data.open_count} still open. A claim states what would settle it, so the survey's route and its
        stopping point are both computed from this table rather than judged.
      </p>

      {/* The question that produced the ledger, verbatim. Without it every
          statement below reads as something the agent decided to care about on
          its own, which is exactly backwards. */}
      {objective && (
        <p className="knowledge-region-description">
          Asked: <em>{objective}</em>
        </p>
      )}

      {data.claims.map((claim) => (
        <ClaimCard key={claim.id} claim={claim} href={href} />
      ))}

      {data.features.length > 0 && (
        <section className="knowledge-region">
          <h3>Feature chains</h3>
          <p className="meta">
            Which separately observed rooms belong to one road or one wall.{" "}
            <code>circuit_closes</code>, <code>connects</code> and <code>bounds</code> are all computed over
            these, so a chain assembled wrongly is the likeliest reason a survey walked somewhere strange.
          </p>
          <table className="manager">
            <thead>
              <tr>
                <th>Feature</th>
                <th className="nowrap">Rooms</th>
                <th>Members</th>
              </tr>
            </thead>
            <tbody>
              {data.features.map((feature) => (
                <tr key={feature.id}>
                  <td>
                    {feature.label ?? feature.slug}
                    <code className="tag">{feature.slug}</code>
                  </td>
                  <td className="nowrap">{feature.room_count}</td>
                  <td>
                    {feature.rooms.length === 0 ? (
                      // Not cosmetic: a predicate over an empty chain can never
                      // be settled, so this is the row that explains a stuck claim.
                      <span className="muted-cell">
                        nothing tagged yet — a predicate over this chain cannot settle
                      </span>
                    ) : (
                      feature.rooms.map((room, i) => (
                        <span key={room.room_id}>
                          {i > 0 && " · "}
                          <Link to={href(`/knowledge/rooms/${room.room_id}`)}>
                            {room.room_name ?? `#${room.room_id}`}
                          </Link>
                        </span>
                      ))
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      {data.hints.length > 0 && (
        <section className="knowledge-region">
          <h3>Frontier hints</h3>
          <p className="meta">
            What the surveyor expects to find behind an exit nobody has walked. This is the one genuinely
            semantic guess in a survey — the deterministic scorer sees the exit's name and nothing else — so
            it is where a frontier choice that looks wrong usually comes from.
          </p>
          <table className="manager">
            <thead>
              <tr>
                <th>From</th>
                <th className="nowrap">Direction</th>
                <th>Said to lead to</th>
                <th>Expected</th>
                <th>Note</th>
              </tr>
            </thead>
            <tbody>
              {data.hints.map((hint) => (
                <tr key={`${hint.room_id}-${hint.direction}`}>
                  <td>
                    <Link to={href(`/knowledge/rooms/${hint.room_id}`)}>
                      {hint.room_name ?? `#${hint.room_id}`}
                    </Link>
                  </td>
                  <td className="nowrap">{hint.direction}</td>
                  <td>{hint.target_name ?? <span className="muted-cell">unnamed</span>}</td>
                  <td>
                    {hint.expected_class ?? <span className="muted-cell">no guess</span>}
                  </td>
                  <td>{hint.note ?? <span className="muted-cell">—</span>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </>
  );
}

// `unresolved` is a SUCCESSFUL outcome and is styled as one: "the wall runs
// along three sides and the fourth was not reached" answers the question far
// better than a room count does. Only `refuted` reads as a negative, and even
// that is a finding.
const VERDICTS: Record<ClaimStatus, { label: string; tone: string; title: string }> = {
  confirmed:  { label: "confirmed",  tone: "ok",   title: "the decisive condition fired positively" },
  refuted:    { label: "refuted",    tone: "warn", title: "the decisive condition fired negatively — a finding, not a failure" },
  unresolved: { label: "unresolved", tone: "idle", title: "budget ran out with evidence intact" },
  parked:     { label: "parked",     tone: "idle", title: "outranked by higher-priority claims; its evidence is kept" },
  open:       { label: "open",       tone: "live", title: "still being investigated" },
};

function ClaimCard({ claim, href }: { claim: Claim; href: (path: string) => string }) {
  const verdict = VERDICTS[claim.status as ClaimStatus] ?? { label: claim.status, tone: "idle", title: "" };
  const unfinished = claim.status === "open" || claim.status === "parked" || claim.status === "unresolved";
  const spent = claim.room_budget != null ? `${claim.rooms_spent}/${claim.room_budget}` : `${claim.rooms_spent}`;

  return (
    <section className="knowledge-region">
      <h3>
        <code className="tag">{claim.ref}</code> {claim.statement}
        <span className={`live-badge live-badge-${verdict.tone}`} title={verdict.title}>
          {verdict.label}
        </span>
      </h3>

      <p className="meta">
        {/* The predicate is what actually ran. The statement above is prose and
            proves nothing on its own, so the two are never separated. */}
        <code>{claim.predicate}</code>
        {claim.subject && <> · {claim.subject}</>}
        {" · priority "}
        <strong>{claim.priority.toFixed(2)}</strong>
        {" · confidence "}
        <strong>{claim.confidence.toFixed(2)}</strong>
        {" · "}
        {spent} room{claim.rooms_spent === 1 && claim.room_budget == null ? "" : "s"} spent
        {" · "}
        <span title={claim.updated_at}>updated {formatTime(claim.updated_at)}</span>
      </p>

      {claim.settled_reason && <p className="knowledge-region-description">{claim.settled_reason}</p>}

      {/* The line that makes a second survey cheap: it says precisely what
          would finish this, so the next run resumes instead of rediscovering. */}
      {unfinished && claim.decisive_when && (
        <p className="meta">
          <strong>To settle:</strong> {claim.decisive_when}
        </p>
      )}

      {Object.keys(claim.args).length > 0 && (
        <p className="meta">
          {Object.entries(claim.args).map(([ key, value ], i) => (
            <span key={key}>
              {i > 0 && " · "}
              {key}: <code>{Array.isArray(value) ? value.join(", ") : String(value)}</code>
            </span>
          ))}
        </p>
      )}

      {claim.evidence.length === 0 ? (
        <p className="muted-cell">No evidence recorded yet.</p>
      ) : (
        <table className="manager">
          <thead>
            <tr>
              <th className="nowrap">For / against</th>
              <th>Room</th>
              <th>What was observed</th>
              <th className="nowrap">When</th>
            </tr>
          </thead>
          <tbody>
            {claim.evidence.map((row) => (
              <tr key={row.id}>
                <td className="nowrap">
                  <span className={row.polarity === "contradict" ? "map-warn" : undefined}>
                    {row.polarity}
                  </span>
                </td>
                <td>
                  {/* Evidence outlives the room that produced it: the column is
                      nullable ON DELETE SET NULL, and the note is still the finding. */}
                  {row.room_id == null ? (
                    <span className="muted-cell">room since removed</span>
                  ) : (
                    <Link to={href(`/knowledge/rooms/${row.room_id}`)}>
                      {row.room_name ?? `#${row.room_id}`}
                    </Link>
                  )}
                </td>
                <td>{row.note ?? <span className="muted-cell">no note</span>}</td>
                <td className="nowrap" title={row.observed_at}>
                  {formatTime(row.observed_at)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
