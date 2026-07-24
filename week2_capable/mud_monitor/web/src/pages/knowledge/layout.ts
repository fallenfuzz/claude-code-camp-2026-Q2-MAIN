// Rooms -> geometry. No React, no DOM: this is the only genuinely algorithmic
// code in web/, and keeping it a pure `rooms[] -> coordinates` function is what
// makes it testable (layout.test.ts) and keeps Map.tsx about rendering.
//
// The job is NOT graph layout in the dagre sense. A layered DAG layout assigns
// ranks and minimises crossings — it discards geometry in favour of its own
// ordering, and geometry is the only spatial information the agent actually
// has. If the agent walked north to get somewhere, that room goes above this
// one. Everything here follows from that.

import type { KnowledgeRoom } from "../../api/types";
import { truncate } from "../../format";

/** The eight planar directions, matching room_parser.rb's DIRECTIONS table —
 *  the only writer of `room_exits.direction`. Screen coords: +y is south. */
const V: Record<string, [number, number]> = {
  north: [ 0, -1 ],
  south: [ 0, 1 ],
  east: [ 1, 0 ],
  west: [ -1, 0 ],
  northeast: [ 1, -1 ],
  northwest: [ -1, -1 ],
  southeast: [ 1, 1 ],
  southwest: [ -1, 1 ],
};

// `up`, `down` and anything the parser passed through verbatim (room 26 has an
// exit whose direction is the literal string "(s)") are non-planar: they never
// consume a cell by vector and they must never throw.
const DIR_ORDER = [
  "north", "northeast", "east", "southeast",
  "south", "southwest", "west", "northwest",
  "up", "down",
];

/** Cell geometry, exported so the SVG edge layer and the CSS node boxes cannot
 *  disagree about where a room is. Mirrors --map-cell-* in index.css. */
export const CELL_W = 190;
export const CELL_H = 120;
export const GAP_X = 40;
export const GAP_Y = 40;
/** Blank columns between disconnected components. */
const COMPONENT_GUTTER = 2;

export const STEP_X = CELL_W + GAP_X;
export const STEP_Y = CELL_H + GAP_Y;

export interface PlacedNode {
  room: KnowledgeRoom;
  /** Grid cell, not pixels. Origin is the top-left of the packed extent. */
  cx: number;
  cy: number;
  component: number;
}

export interface PlacedEdge {
  from: number;
  to: number;
  direction: string;
  /** false = up/down/unrecognised token: the grid cannot express this move. */
  planar: boolean;
  /** true = the two rooms are not where this direction says they should be.
   *  The one place the picture stops matching the data, so it is said out loud. */
  displaced: boolean;
  traversals: number;
  /** The far room records an exit back to this one — absence means a one-way. */
  reciprocal: boolean;
  key: string;
}

export interface FrontierStub {
  roomId: number;
  direction: string;
  /** The door's name from the autoexit line, or the direction if it had none. */
  label: string;
  /** true = planar direction into an empty cell, so it can be drawn as a stub
   *  arrow. false = draw a chip on the node instead; an arrow would either
   *  point at an existing room (implying a link that is not recorded) or point
   *  in a direction the grid does not have. */
  free: boolean;
  dx: number;
  dy: number;
}

export interface MapLayout {
  nodes: PlacedNode[];
  edges: PlacedEdge[];
  stubs: FrontierStub[];
  /** Extent in cells. Always anchored at 0,0 after component packing. */
  cols: number;
  rows: number;
  components: number;
  /** Placement collisions — geometry the map had to lie about. Surfaced. */
  displacedCount: number;
}

const cellKey = (x: number, y: number) => `${x},${y}`;

function dirRank(direction: string): number {
  const i = DIR_ORDER.indexOf(direction);
  return i === -1 ? DIR_ORDER.length : i;
}

// Fixed exit ordering so BFS visits neighbours in the same sequence on every
// tick. Without this the layout would reshuffle every 3s poll and nodes would
// teleport under the cursor.
function sortedExits(room: KnowledgeRoom) {
  return [ ...room.exits ].sort((a, b) => {
    const d = dirRank(a.direction) - dirRank(b.direction);
    return d !== 0 ? d : a.direction.localeCompare(b.direction);
  });
}

/** First free cell at increasing Chebyshev distance from (wx, wy), scanned in a
 *  fixed order. Ties resolve identically every run. */
function nearestFree(occupied: Map<string, number>, wx: number, wy: number): [ number, number ] {
  if (!occupied.has(cellKey(wx, wy))) return [ wx, wy ];
  for (let r = 1; r <= 512; r++) {
    for (let dy = -r; dy <= r; dy++) {
      for (let dx = -r; dx <= r; dx++) {
        if (Math.max(Math.abs(dx), Math.abs(dy)) !== r) continue;
        if (!occupied.has(cellKey(wx + dx, wy + dy))) return [ wx + dx, wy + dy ];
      }
    }
  }
  // Unreachable for any world that fits in memory, but a layout function must
  // not throw on the page that renders the agent's memory.
  return [ wx + 1024, wy ];
}

interface LocalNode {
  room: KnowledgeRoom;
  x: number;
  y: number;
}

/**
 * Place every room on an integer grid by walking its exits.
 *
 * Determinism is a hard requirement, not a nicety: the page repolls every 3s
 * and re-runs this on data that changes underneath it. Anchor is the lowest
 * room id (ids are assigned in discovery order, so id 1 is a stable landmark —
 * anchoring on the player would slide the whole world sideways every time the
 * agent walks through a door; keeping the player centred is the viewport's job).
 * No Object.keys iteration, no Set ordering, no clock.
 */
export function layoutRooms(rooms: KnowledgeRoom[]): MapLayout {
  const sorted = [ ...rooms ].sort((a, b) => a.id - b.id);
  const byId = new Map<number, KnowledgeRoom>();
  for (const room of sorted) byId.set(room.id, room);

  const placed = new Map<number, { x: number; y: number; component: number }>();
  const components: LocalNode[][] = [];

  for (const anchor of sorted) {
    if (placed.has(anchor.id)) continue;

    const component = components.length;
    const occupied = new Map<string, number>();
    const local: LocalNode[] = [];

    const put = (room: KnowledgeRoom, x: number, y: number) => {
      occupied.set(cellKey(x, y), room.id);
      placed.set(room.id, { x, y, component });
      local.push({ room, x, y });
    };

    put(anchor, 0, 0);
    const queue: number[] = [ anchor.id ];

    while (queue.length > 0) {
      const room = byId.get(queue.shift()!)!;
      const here = placed.get(room.id)!;

      for (const exit of sortedExits(room)) {
        const targetId = exit.target_room_id;
        if (targetId == null) continue;          // frontier — nothing to place
        if (placed.has(targetId)) continue;
        const target = byId.get(targetId);
        if (!target) continue;                   // target outside this payload

        const v = V[exit.direction];
        // A non-planar target goes in the nearest free cell to its source: a
        // stairwell drawn adjacent and explicitly styled as one beats leaving
        // the room floating in a component of its own.
        const [ wx, wy ] = v ? [ here.x + v[0], here.y + v[1] ] : [ here.x, here.y ];
        const [ x, y ] = nearestFree(occupied, wx, wy);
        put(target, x, y);
        queue.push(targetId);
      }
    }

    components.push(local);
  }

  // Pack components left-to-right by bounding box, in anchor-id order, with a
  // visible gutter. Islands are not a rendering failure — they are what
  // fingerprint mis-resolution looks like, and the room the resolver split in
  // two should be visibly floating.
  const nodes: PlacedNode[] = [];
  const coords = new Map<number, { cx: number; cy: number }>();
  let cursorX = 0;
  let rows = 0;

  for (let component = 0; component < components.length; component++) {
    const local = components[component];
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const n of local) {
      if (n.x < minX) minX = n.x;
      if (n.y < minY) minY = n.y;
      if (n.x > maxX) maxX = n.x;
      if (n.y > maxY) maxY = n.y;
    }

    for (const n of local) {
      const cx = n.x - minX + cursorX;
      const cy = n.y - minY;
      nodes.push({ room: n.room, cx, cy, component });
      coords.set(n.room.id, { cx, cy });
    }

    cursorX += (maxX - minX + 1) + COMPONENT_GUTTER;
    rows = Math.max(rows, maxY - minY + 1);
  }

  nodes.sort((a, b) => a.room.id - b.room.id);
  const cols = Math.max(0, cursorX - (components.length > 0 ? COMPONENT_GUTTER : 0));

  const occupiedGlobal = new Set<string>();
  for (const n of nodes) occupiedGlobal.add(cellKey(n.cx, n.cy));

  // Which rooms record an exit back — computed from the exits already in hand,
  // so one-way styling costs no extra request.
  const backlinks = new Map<number, Set<number>>();
  for (const room of sorted) {
    for (const exit of room.exits) {
      if (exit.target_room_id == null) continue;
      let set = backlinks.get(exit.target_room_id);
      if (!set) backlinks.set(exit.target_room_id, (set = new Set()));
      set.add(room.id);
    }
  }

  const edges: PlacedEdge[] = [];
  const stubs: FrontierStub[] = [];
  let displacedCount = 0;

  for (const room of sorted) {
    const from = coords.get(room.id);
    if (!from) continue;

    for (const exit of sortedExits(room)) {
      const v = V[exit.direction];
      const planar = v !== undefined;

      if (exit.target_room_id == null) {
        // target_room_id IS the exploration frontier: a named door the agent
        // has seen and never walked through.
        const free = planar && !occupiedGlobal.has(cellKey(from.cx + v[0], from.cy + v[1]));
        stubs.push({
          roomId: room.id,
          direction: exit.direction,
          label: exit.target_name ?? exit.direction,
          free,
          dx: planar ? v[0] : 0,
          dy: planar ? v[1] : 0,
        });
        continue;
      }

      const to = coords.get(exit.target_room_id);
      if (!to) continue;

      // Derived from the final coordinates rather than recorded at placement
      // time, so it also catches the second edge of a cycle that does not
      // close — the non-Euclidean geometry MUDs are full of.
      const displaced = planar && !(to.cx - from.cx === v[0] && to.cy - from.cy === v[1]);
      if (displaced) displacedCount++;

      edges.push({
        from: room.id,
        to: exit.target_room_id,
        direction: exit.direction,
        planar,
        displaced,
        traversals: exit.traversals,
        reciprocal: backlinks.get(room.id)?.has(exit.target_room_id) ?? false,
        key: `${room.id}:${exit.direction}:${exit.target_room_id}`,
      });
    }
  }

  return { nodes, edges, stubs, cols, rows, components: components.length, displacedCount };
}

/** A room the MUD never named still needs something on its box. */
export function displayName(room: KnowledgeRoom): string {
  const name = (room.name ?? "").trim();
  if (name) return name;
  const descr = truncate(room.description, 40);
  return descr || `#${room.id}`;
}

/** Centre of a cell, in world pixels. */
export function cellCenter(cx: number, cy: number): { x: number; y: number } {
  return { x: cx * STEP_X + CELL_W / 2, y: cy * STEP_Y + CELL_H / 2 };
}

export function worldSize(layout: MapLayout): { width: number; height: number } {
  return {
    width: Math.max(0, layout.cols * STEP_X - GAP_X),
    height: Math.max(0, layout.rows * STEP_Y - GAP_Y),
  };
}
