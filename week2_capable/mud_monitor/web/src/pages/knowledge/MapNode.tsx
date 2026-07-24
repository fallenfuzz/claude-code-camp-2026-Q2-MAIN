import type { CSSProperties } from "react";
import { Link } from "react-router";
import { CELL_H, CELL_W, STEP_X, STEP_Y, displayName } from "./layout";
import type { FrontierStub, PlacedNode } from "./layout";

const MAX_VISIBLE_ENTITIES = 3;
const MAX_VISIBLE_LOOKS = 3;
/** Visits at which the heat ramp saturates — past this it's "well trodden". */
const HEAT_CEILING = 8;

const GLYPH: Record<string, string> = {
  north: "↑", south: "↓", east: "→", west: "←",
  northeast: "↗", northwest: "↖", southeast: "↘", southwest: "↙",
  up: "⇧", down: "⇩",
};

interface Props {
  node: PlacedNode;
  /** Every unwalked exit out of this room — chips for the ones that cannot be
   *  drawn as a stub arrow, and a count for all of them. */
  stubs: FrontierStub[];
  current: boolean;
  /** false below the LOD threshold, or with Detail switched off. The current
   *  room ignores it: the one node you are looking for stays readable. */
  detailed: boolean;
}

// One room box. HTML rather than SVG because it is wrapping text, a <Link> and
// `.tag` chips — the same markup Rooms.tsx already renders, which in SVG would
// mean foreignObject or measuring text by hand.
export default function MapNode({ node, stubs, current, detailed }: Props) {
  const room = node.room;
  const full = detailed || current;
  const chips = stubs.filter((s) => !s.free);

  const classes = [ "map-node" ];
  if (current) classes.push("map-node-current");
  if (room.confidence === "provisional") classes.push("map-node-provisional");
  if (!full) classes.push("map-node-lod");

  return (
    <Link
      to={`/knowledge/rooms/${room.id}`}
      className={classes.join(" ")}
      style={{
        left: node.cx * STEP_X,
        top: node.cy * STEP_Y,
        width: CELL_W,
        height: CELL_H,
        // A subtle background ramp, so the agent's well-trodden path is visible
        // at a glance rather than needing the ×N read off every box.
        "--heat": Math.min(1, room.visit_count / HEAT_CEILING),
      } as CSSProperties}
      title={room.description || undefined}
    >
      <span className="map-node-head">
        {/* Never hidden by LOD: this is the id you paste into chat and the key
            for /knowledge/rooms/:id. */}
        <span className="map-node-id">#{room.id}</span>
        <span className="map-node-name">{displayName(room)}</span>
      </span>

      <span className="map-node-badges">
        <span className="map-node-visits" title={`seen ${room.visit_count}×`}>
          ×{room.visit_count}
        </span>
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
      </span>

      {full && (
        <>
          {room.entities.length > 0 && (
            <span className="map-node-chips">
              {room.entities.slice(0, MAX_VISIBLE_ENTITIES).map((entity) => (
                <span key={entity.id} className={`tag tag-${entity.kind}`} title={entity.descr}>
                  {entity.keyword || entity.descr}
                </span>
              ))}
              {room.entities.length > MAX_VISIBLE_ENTITIES && (
                <span className="tag" title={`${room.entities.length} seen here in total`}>
                  +{room.entities.length - MAX_VISIBLE_ENTITIES}
                </span>
              )}
            </span>
          )}

          {room.look_candidates.length > 0 && (
            <span className="map-node-chips">
              {room.look_candidates.slice(0, MAX_VISIBLE_LOOKS).map((c) => (
                <span key={c} className="tag" title={`look ${c}`}>
                  {c}
                </span>
              ))}
              {room.look_candidates.length > MAX_VISIBLE_LOOKS && (
                <span className="tag">+{room.look_candidates.length - MAX_VISIBLE_LOOKS}</span>
              )}
            </span>
          )}
        </>
      )}

      {/* The frontier that could not be drawn as an arrow: a vertical exit, an
          unrecognised token, or a direction whose cell is already a room. */}
      {full && chips.length > 0 && (
        <span className="map-node-chips">
          {chips.map((s) => (
            <span key={s.direction} className="tag tag-frontier" title={`${s.direction} — never walked`}>
              {GLYPH[s.direction] ?? s.direction} {s.label}
            </span>
          ))}
        </span>
      )}

      {/* Survives the LOD threshold and the occupied-cell case, so "how much is
          left here" is answerable from any zoom level. */}
      {stubs.length > 0 && (
        <span className="map-node-foot" title="exits seen but never walked through">
          {stubs.length} unwalked
        </span>
      )}
    </Link>
  );
}
