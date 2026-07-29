import { Link } from "react-router";
import { fetchKnowledgePlayer } from "../../api/client";
import type { KnowledgeItem, KnowledgePlayer } from "../../api/types";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { formatTime } from "../../format";
import { useKnowledgeHref, useKnowledgeSession, useReportEnvelope } from "./Knowledge";

// A reading the agent has never taken. Rendered as an em dash rather than as 0
// or "unknown" everywhere, because on this page most fields are legitimately
// unread most of the time — only `score` carries the sheet, and the agent reads
// it once per process.
function Unread() {
  return <span className="muted-cell">—</span>;
}

function Fact({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <>
      <dt>{label}</dt>
      <dd>{value ?? <Unread />}</dd>
    </>
  );
}

// "19 / 88", or just "19" when the denominator was never read. Never a
// percentage and never a bar: max_mana and max_move come from `score` alone,
// so the missing case is the common one, and a bar with no denominator would
// have to invent one.
function Ratio({ value, max }: { value: number | null; max: number | null }) {
  if (value == null) return <Unread />;
  return (
    <>
      {value}
      {max != null && <span className="muted-cell"> / {max}</span>}
    </>
  );
}

function Tile({ label, value, sub }: { label: string; value: React.ReactNode; sub?: string }) {
  return (
    <div className="stat-tile">
      <div className="stat-tile-label">{label}</div>
      <div className="stat-tile-value">{value}</div>
      {sub && <div className="stat-tile-sub">{sub}</div>}
    </div>
  );
}

// The paperdoll. Ordered by the MUD's own listing order rather than by a slot
// taxonomy we would have to invent — this build prints body before wielded and
// that is as much structure as the text gives us.
function Equipment({ items }: { items: KnowledgeItem[] }) {
  if (items.length === 0) {
    return <p className="empty">No equipment reading yet — the agent has not run <code>check(equipment)</code>.</p>;
  }
  return (
    <table className="manager">
      <thead>
        <tr>
          <th className="nowrap">Slot</th>
          <th>Item</th>
        </tr>
      </thead>
      <tbody>
        {items.map((item) => (
          <tr key={item.id}>
            <td className="nowrap">{item.worn_on ?? <Unread />}</td>
            <td>
              {/* A slot the MUD named nothing for is still a filled slot, and
                  saying so is more honest than dropping the row. */}
              {item.descr === "" ? <span className="muted-cell">(unnamed)</span> : item.descr}
              {item.keyword && <code className="entity-keyword">{item.keyword}</code>}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export default function Player() {
  const href = useKnowledgeHref();
  const session = useKnowledgeSession();
  const { data, error } = usePolling(() => fetchKnowledgePlayer(session), [ session ]);
  useReportEnvelope(data);

  if (error) return <p className="error">Failed to read the player: {error}</p>;
  if (!data) return <p>Loading…</p>;
  if (!data.attached) return <KnowledgeEmpty />;

  const player: KnowledgePlayer | null = data.player;
  if (!player) {
    return <p className="empty">No player state recorded yet — the agent has not looked around.</p>;
  }

  // The pre-V2 case: an older agent's file has the four numbers and nothing
  // else. Served, not rejected — but the page should say why it is bare rather
  // than look broken.
  const preV2 = data.schema_version != null && data.schema_version < 2;

  return (
    <>
      <div className="stat-grid">
        <Tile label="HP" value={<Ratio value={player.hp} max={player.max_hp} />} />
        <Tile label="Mana" value={<Ratio value={player.mana} max={player.max_mana} />} />
        <Tile label="Move" value={<Ratio value={player.move} max={player.max_move} />} />
        <Tile
          label="Level"
          value={player.level ?? "?"}
          sub={player.exp_to_next != null ? `${player.exp_to_next} exp to next` : undefined}
        />
      </div>

      {preV2 && (
        <p className="meta">
          This file was written by an agent on schema v{data.schema_version}, before the player half existed.
          Everything below the vitals is empty because it was never recorded — not because it failed to load.
        </p>
      )}

      <h2>Score sheet</h2>
      <dl className="knowledge-facts">
        <Fact label="Title" value={player.title} />
        <Fact label="Class" value={player.player_class} />
        <Fact label="Gender" value={player.gender} />
        <Fact label="Experience" value={player.exp} />
        <Fact
          label="Gold"
          value={
            player.gold == null ? null : (
              <>
                {player.gold}
                {player.gold_bank != null && <span className="muted-cell"> · {player.gold_bank} banked</span>}
              </>
            )
          }
        />
        {/* Verbatim. "94/10" is two numbers and choosing which is which is a
            guess the parser declined to make. */}
        <Fact label="Armor class" value={player.armor_class} />
        <Fact label="Alignment" value={player.alignment} />
        <Fact label="Age" value={player.age_years == null ? null : `${player.age_years} years`} />
        <Fact label="Position" value={player.position} />
        <Fact label="Practices left" value={player.practices_left} />
        <Fact
          label="Condition"
          value={
            player.conditions.length === 0 ? null : (
              player.conditions.map((c) => (
                <span key={c} className="tag">
                  {c}
                </span>
              ))
            )
          }
        />
        <Fact
          label="Location"
          value={
            player.current_room ? (
              <Link to={href(`/knowledge/rooms/${player.current_room.id}`)}>{player.current_room.name}</Link>
            ) : null
          }
        />
        <Fact
          label="Written by"
          value={player.session_id ? <Link to={`/sessions/${player.session_id}`}>{player.session_id}</Link> : null}
        />
        <Fact label="Updated" value={formatTime(player.updated_at)} />
      </dl>

      <h2>Equipment</h2>
      <Equipment items={data.equipped} />

      <h2>Inventory</h2>
      {/* Staleness is a fact, and it gets a headline rather than a footnote.
          The bag is replaced wholesale on each reading and the agent only reads
          it when it has a reason to, so this list can be several actions out of
          date — and the one thing the monitor must never do is imply otherwise. */}
      <p className="meta">
        {player.items_updated_at ? (
          <>
            Snapshot as of <strong>{formatTime(player.items_updated_at)}</strong>. Items are replaced wholesale on
            each reading, never accumulated — so anything the agent picked up or dropped since then is not here.
          </>
        ) : (
          <>The agent has never read its pack, so there is no snapshot to be stale.</>
        )}
      </p>
      {data.inventory.length === 0 ? (
        <p className="empty">
          {player.items_updated_at
            ? "The pack was empty at the last reading."
            : "No inventory reading yet."}
        </p>
      ) : (
        <table className="manager">
          <thead>
            <tr>
              <th className="nowrap">Qty</th>
              <th>Item</th>
            </tr>
          </thead>
          <tbody>
            {data.inventory.map((item) => (
              <tr key={item.id}>
                <td className="nowrap">{item.quantity}</td>
                <td>
                  {item.descr}
                  {item.keyword && <code className="entity-keyword">{item.keyword}</code>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <h2>Skills</h2>
      {data.skills.length === 0 ? (
        <p className="empty">No skill reading yet — the agent has not run <code>practice</code>.</p>
      ) : (
        <>
          <table className="manager">
            <thead>
              <tr>
                <th>Name</th>
                <th className="nowrap">Kind</th>
                <th className="nowrap">Proficiency</th>
                <th className="nowrap">Learned at</th>
              </tr>
            </thead>
            <tbody>
              {data.skills.map((skill) => (
                <tr key={skill.name}>
                  <td>{skill.name}</td>
                  <td className="nowrap">{skill.kind ?? <Unread />}</td>
                  <td className="nowrap">
                    {skill.proficiency == null ? (
                      <Unread />
                    ) : (
                      <span className={skill.learned ? "tag" : "muted-cell"}>{skill.proficiency}</span>
                    )}
                  </td>
                  <td className="nowrap">
                    {skill.learned_level == null ? <Unread /> : `level ${skill.learned_level}`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {/* Why there is no progress bar here, in one line, so the next person
              does not "fix" it by inventing a percentage. */}
          <p className="meta">
            Proficiency is the word the MUD printed — this build grades skills as <code>(good)</code> /{" "}
            <code>(not learned)</code> and emits no percentage anywhere, so none is shown. Unlike the inventory
            above, skills are never wiped by a later reading: a listing that omits one is not evidence the
            character forgot it.
          </p>
        </>
      )}
    </>
  );
}
