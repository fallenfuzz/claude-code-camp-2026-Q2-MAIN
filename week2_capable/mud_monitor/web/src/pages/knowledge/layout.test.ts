// The only unit tests in web/. `tsc -b --noEmit` is a meaningful bar for JSX;
// it is not a meaningful bar for a BFS with collision handling, and this is the
// one file in the frontend that can be wrong in a way no screenshot reveals.
//
// The live 26-room world lays out with 1 component and 0 collisions — a good
// result and a misleading one, because it means the collision and
// multi-component paths have no real-data coverage at all. Hence the synthetic
// graphs below.

import { describe, expect, it } from "vitest";
import type { KnowledgeExit, KnowledgeRoom } from "../../api/types";
import { displayName, layoutRooms } from "./layout";

type ExitSpec = [ direction: string, target: number | null, traversals?: number ];

function exit([ direction, target, traversals ]: ExitSpec): KnowledgeExit {
  return {
    direction,
    target_name: null,
    target_room_id: target,
    traversals: traversals ?? 0,
    last_seen_at: "2026-07-24T00:00:00Z",
  };
}

function room(id: number, exits: ExitSpec[] = [], over: Partial<KnowledgeRoom> = {}): KnowledgeRoom {
  return {
    id,
    name: `Room ${id}`,
    description: `Description of room ${id}.`,
    confidence: "confirmed",
    look_candidates: [],
    visit_count: 1,
    first_seen_at: "2026-07-24T00:00:00Z",
    last_seen_at: "2026-07-24T00:00:00Z",
    surveyed_at: "2026-07-24T00:00:00Z",
    weak_fingerprint: `w${id}`,
    strong_fingerprint: null,
    exits: exits.map(exit),
    entity_count: 0,
    entities: [],
    // Layout knows nothing about regions — tint is drawn over the placement
    // this function produces, never fed into it.
    region_id: null,
    ...over,
  };
}

const at = (layout: ReturnType<typeof layoutRooms>, id: number) => {
  const node = layout.nodes.find((n) => n.room.id === id);
  if (!node) throw new Error(`room ${id} was not placed`);
  return node;
};

const rel = (layout: ReturnType<typeof layoutRooms>, from: number, to: number) => {
  const a = at(layout, from), b = at(layout, to);
  return [ b.cx - a.cx, b.cy - a.cy ];
};

describe("layoutRooms", () => {
  it("puts north above and south below", () => {
    // The entire reason this module exists instead of dagre.
    const rooms = [
      room(1, [ [ "north", 2 ], [ "south", 3 ], [ "east", 4 ], [ "west", 5 ] ]),
      room(2, [ [ "south", 1 ] ]),
      room(3, [ [ "north", 1 ] ]),
      room(4, [ [ "west", 1 ] ]),
      room(5, [ [ "east", 1 ] ]),
    ];
    const layout = layoutRooms(rooms);

    expect(rel(layout, 1, 2)).toEqual([ 0, -1 ]);
    expect(rel(layout, 1, 3)).toEqual([ 0, 1 ]);
    expect(rel(layout, 1, 4)).toEqual([ 1, 0 ]);
    expect(rel(layout, 1, 5)).toEqual([ -1, 0 ]);
    expect(layout.displacedCount).toBe(0);
    expect(layout.components).toBe(1);
  });

  it("is deterministic under input reordering", () => {
    // This is the test that protects the 3s poll. If the anchor or the visit
    // order can shift, nodes teleport between ticks and the map is unusable.
    const rooms: KnowledgeRoom[] = [];
    for (let id = 1; id <= 30; id++) {
      const exits: ExitSpec[] = [];
      if (id > 1) exits.push([ id % 2 === 0 ? "north" : "east", id - 1, 1 ]);
      if (id < 30) exits.push([ id % 2 === 0 ? "south" : "west", id + 1, 1 ]);
      if (id % 7 === 0) exits.push([ "up", null ]);
      rooms.push(room(id, exits));
    }

    const base = layoutRooms(rooms);

    // A fixed shuffle, not Math.random — a flaky test about determinism would
    // be its own joke.
    for (let seed = 1; seed <= 5; seed++) {
      const shuffled = [ ...rooms ];
      for (let i = shuffled.length - 1; i > 0; i--) {
        const j = (i * 7 + seed * 13) % (i + 1);
        [ shuffled[i], shuffled[j] ] = [ shuffled[j], shuffled[i] ];
      }
      const other = layoutRooms(shuffled);
      expect(other.nodes.map((n) => [ n.room.id, n.cx, n.cy ])).toEqual(
        base.nodes.map((n) => [ n.room.id, n.cx, n.cy ]),
      );
      expect(other.cols).toBe(base.cols);
      expect(other.rows).toBe(base.rows);
    }
  });

  it("places both rooms and marks exactly one edge displaced when a cycle does not close", () => {
    // n, e, s, w — but west lands on a DIFFERENT room than the one we started
    // from. MUD geometry is non-Euclidean; the map is allowed to be
    // approximate, but not quietly wrong.
    const rooms = [
      room(1, [ [ "north", 2, 1 ] ]),
      room(2, [ [ "east", 3, 1 ] ]),
      room(3, [ [ "south", 4, 1 ] ]),
      room(4, [ [ "west", 5, 1 ] ]),
      room(5, []),
    ];
    const layout = layoutRooms(rooms);

    expect(layout.nodes).toHaveLength(5);
    expect(layout.components).toBe(1);
    expect(layout.displacedCount).toBe(1);

    const displaced = layout.edges.filter((e) => e.displaced);
    expect(displaced.map((e) => [ e.from, e.to, e.direction ])).toEqual([ [ 4, 5, "west" ] ]);
    // Room 5 wanted room 1's cell and had to go somewhere else entirely.
    expect(at(layout, 5).cx).not.toBe(at(layout, 1).cx);
  });

  it("lays out disconnected components with non-overlapping bounding boxes", () => {
    // Islands are not a rendering failure — they are what fingerprint
    // mis-resolution looks like, and they should be visibly floating.
    const rooms = [
      room(1, [ [ "north", 2, 1 ] ]),
      room(2, [ [ "south", 1, 1 ] ]),
      room(10, [ [ "east", 11, 1 ] ]),
      room(11, [ [ "west", 10, 1 ] ]),
    ];
    const layout = layoutRooms(rooms);

    expect(layout.components).toBe(2);
    expect(at(layout, 1).component).toBe(0);
    expect(at(layout, 10).component).toBe(1);

    const box = (component: number) => {
      const xs = layout.nodes.filter((n) => n.component === component).map((n) => n.cx);
      return [ Math.min(...xs), Math.max(...xs) ];
    };
    const [ , aMax ] = box(0);
    const [ bMin ] = box(1);
    expect(bMin).toBeGreaterThan(aMax + 1); // a visible gutter, not just adjacency
  });

  describe("non-planar directions", () => {
    it("does not let an up exit steal the cell north belongs in", () => {
      const rooms = [
        room(1, [ [ "north", 2, 1 ], [ "up", 3, 1 ] ]),
        room(2, []),
        room(3, []),
      ];
      const layout = layoutRooms(rooms);

      expect(rel(layout, 1, 2)).toEqual([ 0, -1 ]);
      expect(at(layout, 3)).toBeDefined();

      const up = layout.edges.find((e) => e.direction === "up")!;
      expect(up.planar).toBe(false);
      expect(up.displaced).toBe(false); // non-planar is labelled, not lied about
      expect(layout.edges.find((e) => e.direction === "north")!.planar).toBe(true);
    });

    it('tolerates the literal "(s)" direction that is in the live database today', () => {
      // room_parser.rb passes any unrecognised autoexit token through verbatim,
      // so a parenthesised direction is stored as a direction. Regression test
      // for real data: this must not throw and must not consume a cell.
      const rooms = [
        room(26, [ [ "(s)", null ], [ "north", 27, 1 ] ]),
        room(27, []),
      ];
      const layout = layoutRooms(rooms);

      expect(rel(layout, 26, 27)).toEqual([ 0, -1 ]);
      const stub = layout.stubs.find((s) => s.direction === "(s)")!;
      expect(stub.free).toBe(false); // no vector, so it renders as a chip
      expect([ stub.dx, stub.dy ]).toEqual([ 0, 0 ]);
    });
  });

  describe("frontier", () => {
    it("marks a stub free when its cell is empty and not free when a room sits there", () => {
      // Room 1 has a real room to the north and an unwalked door to the south.
      // Room 2 also claims a door south — into room 1's cell.
      const rooms = [
        room(1, [ [ "north", 2, 1 ], [ "south", null ] ]),
        room(2, [ [ "south", null ] ]),
      ];
      const layout = layoutRooms(rooms);

      const fromOne = layout.stubs.find((s) => s.roomId === 1)!;
      expect(fromOne.free).toBe(true);
      expect([ fromOne.dx, fromOne.dy ]).toEqual([ 0, 1 ]);

      // Drawing this one would point an arrow straight at room 1 and imply a
      // link the agent has not recorded.
      expect(layout.stubs.find((s) => s.roomId === 2)!.free).toBe(false);
    });

    it("labels a stub with the door name when the MUD gave one", () => {
      const rooms = [ room(1, [ [ "east", null ] ]) ];
      rooms[0].exits[0].target_name = "The Temple Gate";
      expect(layoutRooms(rooms).stubs[0].label).toBe("The Temple Gate");
      expect(layoutRooms([ room(2, [ [ "east", null ] ]) ]).stubs[0].label).toBe("east");
    });
  });

  it("records reciprocity so one-way exits can be drawn as one-way", () => {
    const rooms = [
      room(1, [ [ "north", 2, 1 ] ]),
      room(2, [ [ "south", 1, 1 ], [ "north", 3, 1 ] ]),
      room(3, []), // no way back down — a real MUD hazard, not decoration
    ];
    const layout = layoutRooms(rooms);

    const byPair = (from: number, to: number) => layout.edges.find((e) => e.from === from && e.to === to)!;
    expect(byPair(1, 2).reciprocal).toBe(true);
    expect(byPair(2, 1).reciprocal).toBe(true);
    expect(byPair(2, 3).reciprocal).toBe(false);
  });

  it("ignores exits pointing at rooms outside the payload", () => {
    const layout = layoutRooms([ room(1, [ [ "north", 999, 1 ] ]) ]);
    expect(layout.nodes).toHaveLength(1);
    expect(layout.edges).toHaveLength(0);
    expect(layout.stubs).toHaveLength(0);
  });

  it("handles an empty world", () => {
    const layout = layoutRooms([]);
    expect(layout).toMatchObject({ nodes: [], edges: [], stubs: [], cols: 0, rows: 0, components: 0 });
  });
});

describe("displayName", () => {
  it("falls back from name to truncated description to #id", () => {
    expect(displayName(room(1))).toBe("Room 1");
    expect(displayName(room(1, [], { name: "   " }))).toBe("Description of room 1.");
    expect(displayName(room(1, [], { name: "", description: "" }))).toBe("#1");

    const long = room(1, [], { name: "", description: "x".repeat(200) });
    expect(displayName(long).length).toBeLessThanOrEqual(41); // 40 + ellipsis
  });
});
