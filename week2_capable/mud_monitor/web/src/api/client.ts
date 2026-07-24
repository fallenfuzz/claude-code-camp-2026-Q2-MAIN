import type {
  ApiError,
  DroppedDiff,
  KnowledgeEntitiesPage,
  KnowledgeFrontierPage,
  KnowledgeOverview,
  KnowledgePlayerPage,
  KnowledgeRoomDetail,
  KnowledgeRoomsPage,
  JournalPage,
  ManagerPage,
  MessagesTimeline,
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

export function fetchKnowledge(): Promise<KnowledgeOverview> {
  return get("/knowledge");
}

export interface KnowledgeRoomFilters {
  q?: string;
  filter?: string;
}

export function fetchKnowledgeRooms(filters: KnowledgeRoomFilters = {}): Promise<KnowledgeRoomsPage> {
  const params = new URLSearchParams();
  if (filters.q) params.set("q", filters.q);
  if (filters.filter) params.set("filter", filters.filter);
  const qs = params.toString();
  return get(`/knowledge/rooms${qs ? `?${qs}` : ""}`);
}

export function fetchKnowledgeRoom(id: number | string): Promise<KnowledgeRoomDetail> {
  return get(`/knowledge/rooms/${encodeURIComponent(String(id))}`);
}

export interface KnowledgeEntityFilters {
  kind?: string;
  q?: string;
}

export function fetchKnowledgeEntities(filters: KnowledgeEntityFilters = {}): Promise<KnowledgeEntitiesPage> {
  const params = new URLSearchParams();
  if (filters.kind) params.set("kind", filters.kind);
  if (filters.q) params.set("q", filters.q);
  const qs = params.toString();
  return get(`/knowledge/entities${qs ? `?${qs}` : ""}`);
}

export function fetchKnowledgeFrontier(): Promise<KnowledgeFrontierPage> {
  return get("/knowledge/frontier");
}

// Its own endpoint rather than more keys on /knowledge, for the same reason
// rooms and entities are: the Overview polls every 3s and must not start
// carrying a full skill list and two item snapshots to render four tiles.
export function fetchKnowledgePlayer(): Promise<KnowledgePlayerPage> {
  return get("/knowledge/player");
}

// The progression journal, folded into series server-side. A snapshot of the
// whole day is fine to poll (like knowledge) even though the underlying file is
// an append-only log — the fold is cheap and a chart wants the full history.
export function fetchJournal(date?: string): Promise<JournalPage> {
  const qs = date ? `?date=${encodeURIComponent(date)}` : "";
  return get(`/journal${qs}`);
}

export { ApiRequestError };
