import type {
  ApiError,
  DroppedDiff,
  ErrorPage,
  KnowledgeEntitiesPage,
  KnowledgeFrontierPage,
  KnowledgeMapPage,
  KnowledgeOverview,
  KnowledgePlayerPage,
  KnowledgeRegionsPage,
  KnowledgeRoomDetail,
  KnowledgeRoomsPage,
  JournalPage,
  ManagerPage,
  MessagesTimeline,
  ReportPage,
  ReportsPage,
  SessionDetail,
  SessionSummary,
  TelnetPage,
} from "./types";

class ApiRequestError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`/api/v1${path}`);
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as ApiError | null;
    throw new ApiRequestError(res.status, body?.error?.message ?? `${res.status} ${res.statusText}`);
  }
  return res.json() as Promise<T>;
}

export function fetchSessions(): Promise<{ sessions: SessionSummary[] }> {
  return get("/sessions");
}

export function fetchSession(id: string): Promise<SessionDetail> {
  return get(`/sessions/${encodeURIComponent(id)}`);
}

// The raw message array handed to the model on every call — what the curated
// transcript can't show. On-demand: the sidebar calls this when opened/refreshed.
export function fetchSessionMessages(id: string): Promise<MessagesTimeline> {
  return get(`/sessions/${encodeURIComponent(id)}/messages`);
}

export interface ManagerFilters {
  date?: string;
  session?: string;
  mode?: string;
}

export function fetchManager(filters: ManagerFilters = {}): Promise<ManagerPage> {
  const params = new URLSearchParams();
  if (filters.date) params.set("date", filters.date);
  if (filters.session) params.set("session", filters.session);
  if (filters.mode) params.set("mode", filters.mode);
  const qs = params.toString();
  return get(`/manager${qs ? `?${qs}` : ""}`);
}

export interface TelnetFilters {
  date?: string;
  session?: string;
  dir?: string;
}

export function fetchTelnet(filters: TelnetFilters = {}): Promise<TelnetPage> {
  const params = new URLSearchParams();
  if (filters.date) params.set("date", filters.date);
  if (filters.session) params.set("session", filters.session);
  if (filters.dir) params.set("dir", filters.dir);
  const qs = params.toString();
  return get(`/telnet${qs ? `?${qs}` : ""}`);
}

export interface ErrorFilters {
  component?: string;
  exceptionClass?: string;
  sessionId?: string;
  q?: string;
  before?: number;
  limit?: number;
}

export function fetchErrors(filters: ErrorFilters = {}): Promise<ErrorPage> {
  const params = new URLSearchParams();
  if (filters.component) params.set("component", filters.component);
  if (filters.exceptionClass) params.set("exception_class", filters.exceptionClass);
  if (filters.sessionId) params.set("session_id", filters.sessionId);
  if (filters.q) params.set("q", filters.q);
  if (filters.before != null) params.set("before", String(filters.before));
  if (filters.limit != null) params.set("limit", String(filters.limit));
  const qs = params.toString();
  return get(`/errors${qs ? `?${qs}` : ""}`);
}

export interface DroppedFilters {
  date?: string;
  session?: string;
  from?: string;
  to?: string;
}

export function fetchDropped(filters: DroppedFilters = {}): Promise<DroppedDiff> {
  const params = new URLSearchParams();
  if (filters.date) params.set("date", filters.date);
  if (filters.session) params.set("session", filters.session);
  if (filters.from) params.set("from", filters.from);
  if (filters.to) params.set("to", filters.to);
  const qs = params.toString();
  return get(`/diffs/dropped${qs ? `?${qs}` : ""}`);
}

// ---------- Knowledge ----------
//
// No stream sibling for any of these: knowledge is a snapshot, not a log, so
// the pages poll (usePolling) rather than tailing a cursor.
//
// Every read takes an optional session id. Omitted, it is the profile's live
// memory; given, it is the map that session ENDED with, out of the harness's
// retained directory. Same shapes either way — the envelope's `session` field
// is how a view knows which of the two it is rendering.

/** Appends `?session=` to a knowledge path, preserving any query already on it. */
function withSession(path: string, session?: string | null): string {
  if (!session) return path;
  return `${path}${path.includes("?") ? "&" : "?"}session=${encodeURIComponent(session)}`;
}

export function fetchKnowledge(session?: string | null): Promise<KnowledgeOverview> {
  return get(withSession("/knowledge", session));
}

export interface KnowledgeRoomFilters {
  q?: string;
  filter?: string;
  /** Server clamps to 1..1000; the default is 200. */
  limit?: number;
}

export function fetchKnowledgeRooms(
  filters: KnowledgeRoomFilters = {},
  session?: string | null,
): Promise<KnowledgeRoomsPage> {
  const params = new URLSearchParams();
  if (filters.q) params.set("q", filters.q);
  if (filters.filter) params.set("filter", filters.filter);
  if (filters.limit != null) params.set("limit", String(filters.limit));
  const qs = params.toString();
  return get(withSession(`/knowledge/rooms${qs ? `?${qs}` : ""}`, session));
}

/**
 * The map's payload: two existing requests, one poll tick.
 *
 * A dedicated `knowledge#map` action would buy nothing at this size and cost a
 * controller action, a reader method and a serializer shape that all restate
 * `#rooms`. The trigger to revisit is payload size, not request count:
 * /knowledge/rooms ships full `description` text per room, which is fine to a
 * couple of hundred rooms and wasteful past ~500 polled every 3s. The fix then
 * is a `fields=map` param on THIS action that drops `description` and
 * `entities[].descr` — not a second action.
 */
export function fetchKnowledgeMap(session?: string | null): Promise<KnowledgeMapPage> {
  return Promise.all([
    fetchKnowledgeRooms({ limit: 1000 }, session),
    fetchKnowledge(session),
    fetchKnowledgeRegions(session),
  ]).then(
    ([ rooms, overview, regions ]) => ({ ...rooms, player: overview.player, regions: regions.regions }),
  );
}

export function fetchKnowledgeRegions(session?: string | null): Promise<KnowledgeRegionsPage> {
  return get(withSession("/knowledge/regions", session));
}

export function fetchKnowledgeRoom(id: number | string, session?: string | null): Promise<KnowledgeRoomDetail> {
  return get(withSession(`/knowledge/rooms/${encodeURIComponent(String(id))}`, session));
}

export interface KnowledgeEntityFilters {
  kind?: string;
  q?: string;
}

export function fetchKnowledgeEntities(
  filters: KnowledgeEntityFilters = {},
  session?: string | null,
): Promise<KnowledgeEntitiesPage> {
  const params = new URLSearchParams();
  if (filters.kind) params.set("kind", filters.kind);
  if (filters.q) params.set("q", filters.q);
  const qs = params.toString();
  return get(withSession(`/knowledge/entities${qs ? `?${qs}` : ""}`, session));
}

export function fetchKnowledgeFrontier(session?: string | null): Promise<KnowledgeFrontierPage> {
  return get(withSession("/knowledge/frontier", session));
}

// Its own endpoint rather than more keys on /knowledge, for the same reason
// rooms and entities are: the Overview polls every 3s and must not start
// carrying a full skill list and two item snapshots to render four tiles.
export function fetchKnowledgePlayer(session?: string | null): Promise<KnowledgePlayerPage> {
  return get(withSession("/knowledge/player", session));
}

// The progression journal, folded into series server-side. A snapshot of the
// whole day is fine to poll (like knowledge) even though the underlying file is
// an append-only log — the fold is cheap and a chart wants the full history.
export function fetchJournal(date?: string): Promise<JournalPage> {
  const qs = date ? `?date=${encodeURIComponent(date)}` : "";
  return get(`/journal${qs}`);
}

// The change log, narrowed to one unit of work. Called when a span's journal
// summary is expanded — the detail is deliberately NOT bundled into the session
// payload, because the session view should not grow a second full log inside it.
export function fetchJournalForOperation(operationId: string, date?: string): Promise<JournalPage> {
  const qs = new URLSearchParams({ operation_id: operationId });
  if (date) qs.set("date", date);
  return get(`/journal?${qs.toString()}`);
}

// Batch test-run reports. No stream sibling and no polling: a report is written
// once, when the run finishes. There is no cursor to follow.
export function fetchReports(profile?: string): Promise<ReportsPage> {
  const qs = profile ? `?profile=${encodeURIComponent(profile)}` : "";
  return get(`/reports${qs}`);
}

export function fetchReport(id: string): Promise<ReportPage> {
  return get(`/reports/${encodeURIComponent(id)}`);
}

export { ApiRequestError };
