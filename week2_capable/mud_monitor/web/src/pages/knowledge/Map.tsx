import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent } from "react";
import { fetchKnowledgeMap } from "../../api/client";
import { usePolling } from "../../api/usePolling";
import KnowledgeEmpty from "../../components/KnowledgeEmpty";
import { useReportEnvelope } from "./Knowledge";
import MapNode from "./MapNode";
import { CELL_H, CELL_W, cellCenter, layoutRooms, worldSize } from "./layout";
import type { FrontierStub, PlacedNode } from "./layout";

const MIN_SCALE = 0.3;
const MAX_SCALE = 2;
/** Below this, node boxes are unreadable anyway, so drop to id + name. */
const LOD_SCALE = 0.6;
/** How far a frontier arrow reaches out of its room — half a cell. */
const STUB_LENGTH = 62;
/** Pointer travel that turns a click on a room into a pan of the map. */
const DRAG_THRESHOLD = 4;
const FIT_PADDING = 48;

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

interface View {
  x: number;
  y: number;
  k: number;
}

/** Where a line from a cell's centre crosses that cell's box. Without this the
 *  arrowheads end up buried under the node they point at. */
function onBoxEdge(from: { x: number; y: number }, to: { x: number; y: number }, pad = 6) {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  if (dx === 0 && dy === 0) return from;
  const halfW = CELL_W / 2 + pad;
  const halfH = CELL_H / 2 + pad;
  const s = Math.min(
    dx === 0 ? Infinity : halfW / Math.abs(dx),
    dy === 0 ? Infinity : halfH / Math.abs(dy),
  );
  return s >= 1 ? to : { x: from.x + dx * s, y: from.y + dy * s };
}

/**
 * What the agent thinks the world looks like.
 *
 * This is the strongest version of the warning the whole Knowledge tab carries:
 * a grid of boxes looks like a surveyed floor plan, and it is a guess assembled
 * from autoexit lines. The honesty mechanisms — provisional badges, visible
 * ids, and dashed edges wherever the picture stops matching the data — are not
 * decoration, they are the reason this is allowed to be drawn at all.
 */
export default function KnowledgeMap() {
  const { data, error } = usePolling(() => fetchKnowledgeMap(), []);
  useReportEnvelope(data);

  const [ view, setView ] = useState<View>({ x: 0, y: 0, k: 1 });
  const [ follow, setFollow ] = useState(true);
  const [ showFrontier, setShowFrontier ] = useState(true);
  const [ detail, setDetail ] = useState(true);

  const viewportRef = useRef<HTMLDivElement | null>(null);
  // Also held in state, because the wheel listener below is bound in an effect
  // and the first render of this page is the loading state — a plain ref is
  // still null when a mount-once effect runs, and the binding never happens.
  const [ viewportEl, setViewportEl ] = useState<HTMLDivElement | null>(null);
  const attachViewport = useCallback((el: HTMLDivElement | null) => {
    viewportRef.current = el;
    setViewportEl(el);
  }, []);

  const dragRef = useRef<{ id: number; x: number; y: number; moved: boolean } | null>(null);
  // A pan that ends over a room must not also navigate into that room.
  const suppressClick = useRef(false);

  const rooms = data?.rooms;
  const layout = useMemo(() => layoutRooms(rooms ?? []), [ rooms ]);

  const nodeById = useMemo(() => {
    const map = new Map<number, PlacedNode>();
    for (const node of layout.nodes) map.set(node.room.id, node);
    return map;
  }, [ layout ]);

  const stubsByRoom = useMemo(() => {
    const map = new Map<number, FrontierStub[]>();
    for (const stub of layout.stubs) {
      const list = map.get(stub.roomId);
      if (list) list.push(stub);
      else map.set(stub.roomId, [ stub ]);
    }
    return map;
  }, [ layout ]);

  const playerRoomId = data?.player?.current_room?.id ?? null;
  const world = worldSize(layout);

  const centreOn = useCallback((cx: number, cy: number, scale?: number) => {
    const el = viewportRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const c = cellCenter(cx, cy);
    setView((v) => {
      const k = scale ?? v.k;
      return { k, x: rect.width / 2 - c.x * k, y: rect.height / 2 - c.y * k };
    });
  }, []);

  // `fit` is a toolbar button and must not be rebuilt (and re-bound) on every
  // 3s poll, so it reads the layout through a ref instead of closing over it.
  const layoutRef = useRef(layout);
  layoutRef.current = layout;

  const fit = useCallback(() => {
    const el = viewportRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const size = worldSize(layoutRef.current);
    if (size.width <= 0 || size.height <= 0) return;
    const k = clamp(
      Math.min((rect.width - FIT_PADDING) / size.width, (rect.height - FIT_PADDING) / size.height),
      MIN_SCALE,
      MAX_SCALE,
    );
    setView({ k, x: (rect.width - size.width * k) / 2, y: (rect.height - size.height * k) / 2 });
  }, []);

  const centreOnPlayer = useCallback(() => {
    if (playerRoomId == null) return;
    const node = nodeById.get(playerRoomId);
    if (node) centreOn(node.cx, node.cy);
  }, [ playerRoomId, nodeById, centreOn ]);

  // First useful frame: sit on the player if there is one, otherwise show the
  // whole world. Only once — after that the viewport belongs to the reader.
  const initialised = useRef(false);
  useEffect(() => {
    if (initialised.current || layout.nodes.length === 0) return;
    initialised.current = true;
    if (playerRoomId != null && nodeById.has(playerRoomId)) centreOnPlayer();
    else fit();
  }, [ layout, playerRoomId, nodeById, centreOnPlayer, fit ]);

  // Follow is sticky-off: it keeps up with the agent until the reader pans or
  // zooms once, and then stays off until they ask for it back. Yanking the
  // viewport out from under someone mid-read is the worst thing this page could
  // do to them.
  useEffect(() => {
    if (follow && initialised.current) centreOnPlayer();
  }, [ follow, playerRoomId, centreOnPlayer ]);

  // Wheel is bound by hand because React's onWheel is passive, and a page that
  // scrolls the window while you are zooming a map is not usable.
  useEffect(() => {
    const el = viewportEl;
    if (!el) return;

    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;
      setFollow(false);
      setView((v) => {
        const k = clamp(v.k * Math.exp(-e.deltaY * 0.0015), MIN_SCALE, MAX_SCALE);
        if (k === v.k) return v;
        // Keep whatever is under the cursor under the cursor.
        return { k, x: mx - ((mx - v.x) / v.k) * k, y: my - ((my - v.y) / v.k) * k };
      });
    };

    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [ viewportEl ]);

  const onPointerDown = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return;
    // Cleared per gesture, not per click: a drag that ends without the browser
    // emitting a click (a pan released over empty canvas) would otherwise leave
    // the flag set and eat the NEXT click on a room, making the map look dead.
    suppressClick.current = false;
    dragRef.current = { id: e.pointerId, x: e.clientX, y: e.clientY, moved: false };
    // Capture is deliberately NOT taken here. A captured pointer retargets the
    // whole compatibility mouse sequence — including `click` — at the capture
    // element, so capturing on pointerdown means the room <Link> under the
    // cursor never receives its own click and every node on the map is dead.
    // It is taken below, once the gesture is actually a drag.
  };

  const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.id !== e.pointerId) return;
    const dx = e.clientX - drag.x;
    const dy = e.clientY - drag.y;
    if (!drag.moved && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
    if (!drag.moved) {
      drag.moved = true;
      // Now that this is a pan, keep receiving moves even if the cursor leaves
      // the viewport.
      e.currentTarget.setPointerCapture(e.pointerId);
    }
    suppressClick.current = true;
    drag.x = e.clientX;
    drag.y = e.clientY;
    setFollow(false);
    setView((v) => ({ ...v, x: v.x + dx, y: v.y + dy }));
  };

  const endDrag = (e: ReactPointerEvent<HTMLDivElement>) => {
    if (dragRef.current?.id !== e.pointerId) return;
    dragRef.current = null;
    if (e.currentTarget.hasPointerCapture(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId);
  };

  const onClickCapture = (e: ReactMouseEvent<HTMLDivElement>) => {
    if (!suppressClick.current) return;
    suppressClick.current = false;
    e.preventDefault();
    e.stopPropagation();
  };

  // Every state renders inside this wrapper, including the ones that show no
  // map at all. It is what `main:has(.knowledge-map-page)` keys off to drop the
  // 980px reading cap — if it only appeared once the rooms arrived, the whole
  // shell would visibly jump to full width three seconds into the page.
  if (error) {
    return (
      <div className="knowledge-map-page">
        <p className="error">Failed to read map: {error}</p>
      </div>
    );
  }
  if (!data) return <div className="knowledge-map-page"><p>Loading…</p></div>;
  if (!data.attached) return <div className="knowledge-map-page"><KnowledgeEmpty /></div>;
  if (data.rooms.length === 0) {
    return (
      <div className="knowledge-map-page">
        <p className="empty">No rooms in memory yet. The agent has not looked at anything.</p>
      </div>
    );
  }

  const detailed = detail && view.k >= LOD_SCALE;

  return (
    <div className="knowledge-map-page">
      <p className="meta">
        <strong>The agent's map, not the world's.</strong> Every box below is a room the agent believes it
        found, placed by following the directions it believes connect them. Rooms are laid out from{" "}
        <strong>#{layout.nodes[0]?.room.id}</strong> outward; the MUD is not a grid, so where two exits
        disagree the edge is drawn dashed rather than straightened out.
      </p>

      <div className="knowledge-map-toolbar">
        <button type="button" onClick={fit}>
          Fit
        </button>
        <button type="button" onClick={() => { setFollow(true); centreOnPlayer(); }} disabled={playerRoomId == null}>
          Centre on player
        </button>
        <label>
          <input type="checkbox" checked={showFrontier} onChange={(e) => setShowFrontier(e.target.checked)} />
          Show frontier
        </label>
        <label>
          <input type="checkbox" checked={detail} onChange={(e) => setDetail(e.target.checked)} />
          Detail
        </label>
        <span className="knowledge-map-stats">
          {layout.nodes.length} rooms · {layout.edges.length} known exits · {layout.stubs.length} unwalked
          {layout.components > 1 && (
            <>
              {" · "}
              <span
                className="map-warn"
                title="rooms with no walked path between them — often what a fingerprint mis-resolution looks like"
              >
                {layout.components} islands
              </span>
            </>
          )}
          {layout.displacedCount > 0 && (
            <>
              {" · "}
              <span
                className="map-warn"
                title="exits whose two rooms could not both sit where the direction says — drawn dashed"
              >
                {layout.displacedCount} displaced
              </span>
            </>
          )}
          {" · "}
          {Math.round(view.k * 100)}%
        </span>
      </div>

      <div
        className="knowledge-map-viewport"
        ref={attachViewport}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onClickCapture={onClickCapture}
      >
        <div
          className="knowledge-map-world"
          style={{
            transform: `translate(${view.x}px, ${view.y}px) scale(${view.k})`,
            width: world.width,
            height: world.height,
          }}
        >
          <svg
            className="knowledge-map-edges"
            width={world.width}
            height={world.height}
            viewBox={`0 0 ${world.width} ${world.height}`}
          >
            <defs>
              <marker id="map-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="5" markerHeight="5" orient="auto-start-reverse">
                <path d="M0,0 L8,4 L0,8 Z" className="map-arrow-head" />
              </marker>
              <marker id="map-frontier-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                <path d="M0,0 L8,4 L0,8 Z" className="map-frontier-head" />
              </marker>
            </defs>

            {layout.edges.map((edge) => {
              const a = nodeById.get(edge.from);
              const b = nodeById.get(edge.to);
              if (!a || !b) return null;
              const from = cellCenter(a.cx, a.cy);
              const to = cellCenter(b.cx, b.cy);
              const p1 = onBoxEdge(from, to);
              const p2 = onBoxEdge(to, from);

              // An edge the geometry cannot honour is bent away from the
              // straight line so it never reads as a plain corridor.
              const lie = edge.displaced || !edge.planar;
              const classes = [ "map-edge" ];
              if (lie) classes.push(edge.planar ? "map-edge-displaced" : "map-edge-nonplanar");
              else if (edge.traversals === 0) classes.push("map-edge-unwalked");
              else if (edge.reciprocal) classes.push("map-edge-walked");
              else classes.push("map-edge-oneway");

              const title = lie
                ? `${edge.direction} — drawn ${edge.planar ? "displaced" : "non-planar"}: the grid cannot place these two rooms as ${edge.direction}`
                : `${edge.direction}${edge.traversals === 0 ? " — known, never walked" : ""}${
                    edge.traversals > 0 && !edge.reciprocal ? " — one way: no exit back is recorded" : ""
                  }`;

              const d = lie
                ? `M${p1.x},${p1.y} Q${(p1.x + p2.x) / 2 - (p2.y - p1.y) * 0.22},${
                    (p1.y + p2.y) / 2 + (p2.x - p1.x) * 0.22
                  } ${p2.x},${p2.y}`
                : `M${p1.x},${p1.y} L${p2.x},${p2.y}`;

              return (
                <path
                  key={edge.key}
                  d={d}
                  className={classes.join(" ")}
                  markerEnd={edge.reciprocal && !lie ? undefined : "url(#map-arrow)"}
                >
                  <title>{title}</title>
                </path>
              );
            })}

            {/* Unwalked exits, beneath the nodes and visually subordinate to
                real edges. The distinction that has to read pre-attentively is
                walked vs not — on this world that is most of the graph. */}
            {showFrontier &&
              layout.stubs.map((stub) => {
                if (!stub.free) return null;
                const node = nodeById.get(stub.roomId);
                if (!node) return null;
                const c = cellCenter(node.cx, node.cy);
                const far = { x: c.x + stub.dx * 1000, y: c.y + stub.dy * 1000 };
                const start = onBoxEdge(c, far, 2);
                const len = Math.hypot(stub.dx, stub.dy);
                const end = {
                  x: start.x + (stub.dx / len) * STUB_LENGTH,
                  y: start.y + (stub.dy / len) * STUB_LENGTH,
                };
                return (
                  <g key={`${stub.roomId}:${stub.direction}`} className="map-stub">
                    <line
                      x1={start.x}
                      y1={start.y}
                      x2={end.x}
                      y2={end.y}
                      markerEnd="url(#map-frontier-arrow)"
                    >
                      <title>{`${stub.direction} — never walked`}</title>
                    </line>
                    {detailed && (
                      <text
                        x={end.x + (stub.dx === 0 ? 0 : Math.sign(stub.dx) * 6)}
                        y={end.y + (stub.dy > 0 ? 12 : stub.dy < 0 ? -6 : 4)}
                        textAnchor={stub.dx > 0 ? "start" : stub.dx < 0 ? "end" : "middle"}
                      >
                        {stub.label}
                      </text>
                    )}
                  </g>
                );
              })}
          </svg>

          {layout.nodes.map((node) => (
            <MapNode
              key={node.room.id}
              node={node}
              stubs={stubsByRoom.get(node.room.id) ?? []}
              current={node.room.id === playerRoomId}
              detailed={detailed}
            />
          ))}
        </div>
      </div>

      <p className="knowledge-map-legend">
        <span className="map-key map-key-walked" /> walked
        <span className="map-key map-key-oneway" /> one way only
        <span className="map-key map-key-unwalked" /> known, never walked
        <span className="map-key map-key-lie" /> displaced or vertical
        <span className="map-key map-key-frontier" /> frontier
        {playerRoomId == null && <span className="map-note">the agent does not know where it is</span>}
      </p>
    </div>
  );
}
