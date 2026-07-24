export interface SessionSummary {
  id: string;
  started_at: string | null;
  ended_at: string | null;
  duration_ms: number | null;
  live: boolean;
  /** The goal text the user typed. */
  task: string | null;
  /** The task that owns depth 0 — usually "player", but a standalone sub-run is its own root. */
  root_task: string | null;
  /** Every task that ran in this session, delegations included. */
  tasks: string[];
  /** Number of delegated sub-runs (task_start events). */
  sub_runs: number;
  /** Sub-runs whose task_end never arrived — process died mid-delegation. */
  unclosed_tasks: number;
  models: string[];
  turns: number;
  iterations: number;
  tool_calls: number;
  input_tokens: number;
  output_tokens: number;
  peak_input_tokens: number;
  context_window: number | null;
  cost_usd: number | null;
  end_reason: string | null;
  stopped: boolean;
  any_limit_tripped: boolean;
  timing_source: "monotonic" | "wallclock" | "wallclock_coarse";
  timing: TimingSummary;
  bytes: number;
}

export interface TimingSummary {
  p50_tool_ms: number | null;
  p95_tool_ms: number | null;
  p50_model_ms: number | null;
  p95_model_ms: number | null;
  total_idle_ms: number;
  wall_ms: number | null;
  busy_ms: number | null;
}

export interface SessionSnapshot {
  model: string | null;
  max_iterations: number | null;
  max_turn_tokens: number | null;
  context_window: number | null;
}

export interface TurnRow {
  n: number;
  iterations: number | null;
  tokens: number;
  reason: string | null;
  started_at: string | null;
  ended_at: string | null;
  duration_ms: number | null;
}

export interface UsagePoint {
  turn: number;
  iteration: number;
  input: number;
  output: number;
  cache_read: number;
  cache_creation: number;
  running: number;
  at: string | null;
  task: string | null;
  provider: string | null;
  model: string | null;
  cost_usd: number | null;
}

export interface CostBreakdownRow {
  task: string;
  provider: string;
  model: string;
  calls: number;
  input: number;
  output: number;
  cost: number;
  cost_known: boolean;
}

export type EntryType =
  | "user"
  | "assistant"
  | "reasoning"
  | "plan"
  | "tool"
  | "compaction"
  | "clear"
  | "request"
  | "turn_end"
  | "task_start"
  | "task_end"
  | "unknown";

export interface Entry {
  seq: number;
  type: EntryType;
  /** The task that produced this entry. Null on logs written before Amendment A. */
  task: string | null;
  /** 0 = root task, 1 = delegated, … */
  depth: number;
  turn: number;
  iteration: number;
  at: string | null;
  dt_ms: number | null;
  duration_ms: number | null;

  // user | assistant | reasoning | plan
  text?: string;

  // assistant
  usage?: Record<string, unknown>;
  stop_reason?: string | null;
  running_turn_tokens?: number;
  provider?: string | null;
  model?: string | null;
  input_tokens?: number;
  output_tokens?: number;
  cost_usd?: number | null;

  // reasoning
  redacted?: boolean;

  // tool
  tool_name?: string;
  tool_args?: Record<string, unknown>;
  tool_result?: string;
  tool_ok?: boolean;
  tool_error?: string | null;
  result_html?: string;

  // compaction | clear
  before?: number;
  dropped?: number;

  // request (a marker that opens the sidebar at the matching checkpoint)
  request_seq?: number;
  message_count?: number;

  // turn_end
  reason?: string | null;
  iterations?: number;
  tokens?: number | null;

  // task_start | task_end
  task_name?: string;
  max_iterations?: number | null;

  // unknown
  raw?: Record<string, unknown>;
}

// ---- message timeline (the raw array fed to the model) ------------------
// A single content block inside an assistant message. `input`/`name`/`id` are
// present on tool_use; `text` on text blocks. Kept permissive because the log
// passes provider content through untouched.
export interface ContentBlock {
  type: string;
  text?: string;
  name?: string;
  id?: string;
  input?: Record<string, unknown>;
  content?: unknown;
  [key: string]: unknown;
}

// One logged message: role + content, where content is a plain string
// (user / tool_result) or an array of content blocks (assistant).
export interface TimelineMessage {
  role: string;
  content: string | ContentBlock[];
}

// Authoritative token accounting from the model's usage on the answering
// response. Counts are null when no response was logged for the call.
export interface CheckpointTokens {
  input: number | null;
  output: number | null;
  cache_read: number | null;
  cache_creation: number | null;
  /** The real prompt size: input + both cache buckets. The "watch it grow" number. */
  context: number | null;
  /** Growth in `context` since the previous call that had usage. */
  context_delta: number | null;
}

// Estimated split of the prompt across its parts (system / tools / messages).
// `tokens` is scaled to the authoritative context total when known; `share` is
// the raw proportion; `cost_usd` is priced at the call's blended input rate.
export interface CompositionRow {
  label: "system" | "tools" | "messages";
  tokens: number;
  share?: number;
  cost_usd?: number | null;
  estimated: boolean;
}

// A logged tool definition (provider wire shape — permissive across backends).
export interface TimelineTool {
  name?: string;
  description?: string;
  input_schema?: Record<string, unknown>;
  [key: string]: unknown;
}

// One model call: the complete payload the model saw, plus how the message
// array changed since the previous call.
//   source          "request" = the definitive body (system + tool schemas +
//                   wire messages); "prompt" = a legacy reconstruction (no
//                   system/tools, role+content only).
//   system/tools    carried-forward constants; *_changed says whether this call
//                   is where they actually changed (the logger dedups them).
//   messages.slice(carried)  the appended tail (the delta); `dropped` is how
//                   many fell off the front and `marker` says why.
export interface MessageCheckpoint {
  seq: number;
  source: "request" | "prompt";
  turn: number;
  iteration: number;
  at: string | null;
  model: string | null;
  max_tokens: number | null;
  system: string | null;
  system_changed: boolean;
  tools: TimelineTool[] | null;
  tool_count: number | null;
  tools_changed: boolean;
  message_count: number;
  dropped: number;
  carried: number;
  marker: "compaction" | "clear" | "trim" | null;
  tokens: CheckpointTokens;
  input_cost_usd: number | null;
  composition: CompositionRow[];
  messages: TimelineMessage[];
}

export interface MessagesTimeline {
  checkpoints: MessageCheckpoint[];
  live: boolean;
}

export interface SessionDetail {
  session: SessionSummary;
  snapshot: SessionSnapshot;
  turns: TurnRow[];
  usage_series: UsagePoint[];
  cost_breakdown: CostBreakdownRow[];
  entries: Entry[];
}

export interface ApiError {
  error: { code: string; message: string };
}

// mode: "command" | "raw" | "poll" | "login" (spec §4.3)
export interface ManagerRecord {
  seq: number;
  at: string | null;
  mono_ms: number | null;
  session: string;
  mode: string;
  tool: string | null;
  args: Record<string, unknown> | null;
  correlation_id: string | null;
  correlation: "exact" | "inferred" | "none";
  sent: string | null;
  received: string | null;
  received_html: string;
  bytes_in: number;
  elapsed_ms: number | null;
  error: string | null;
}

export interface ManagerPage {
  entries: ManagerRecord[];
  next_seq: number;
  eof: boolean;
  live: boolean;
}

// dir: "in" | "out" (spec §4.2)
export interface TelnetRecord {
  seq: number;
  at: string | null;
  mono_ms: number | null;
  session: string;
  dir: "in" | "out";
  bytes: number;
  text: string;
  text_html: string;
  redacted: boolean;
}

export interface TelnetPage {
  entries: TelnetRecord[];
  next_seq: number;
  eof: boolean;
  live: boolean;
}

// cause: "pre_command_drain" | "post_prompt_leftover" | "login" (spec §3.6)
export interface DroppedEvent {
  at: string | null;
  telnet_seqs: number[];
  text: string;
  text_html: string;
  bytes: number;
  between: { after_manager_seq: number | null; before_manager_seq: number | null };
  cause: "pre_command_drain" | "post_prompt_leftover" | "login";
}

export interface DroppedSummary {
  dropped_bytes: number;
  dropped_runs: number;
  received_bytes: number;
  drop_ratio: number | null;
}

export interface DroppedDiff {
  dropped: DroppedEvent[];
  summary: DroppedSummary;
}

// ---------- Knowledge (docs/plans/week_2/knowledge_tab.md) ----------
//
// Everything above this line describes a LOG — an ordered record of what
// happened, with a cursor. Knowledge is a snapshot of BELIEF: what the agent
// currently thinks the world is. Hence no `seq`, no `next_seq`, no `eof`.

// Present on every knowledge payload so any view can render freshness without
// a second request.
export interface KnowledgeEnvelope {
  attached: boolean;
  live: boolean;
  last_write_at: string | null;
  schema_version: number | null;
  /** WAL size — grows all session and only shrinks on checkpoint (plan §7). */
  wal_bytes: number | null;
}

export interface KnowledgeStats {
  rooms: number;
  surveyed: number;
  provisional: number;
  entities: number;
  mobs: number;
  objects: number;
  exits: number;
  /** Exits whose destination the agent has never stood in. */
  frontier: number;
  traversed: number;
  encounters: number;
  /** Both 0 against a pre-V2 agent file, which has neither table. */
  skills: number;
  items: number;
}

export interface RoomRef {
  id: number;
  name: string | null;
}

export interface KnowledgePlayer {
  hp: number | null;
  max_hp: number | null;
  mana: number | null;
  move: number | null;
  /**
   * Only `score` carries these — the prompt line rides on every response but
   * gives currents alone. So they are null far more often than max_hp is, and
   * a bar without its denominator must render as a bare number, never as 0%.
   */
  max_mana: number | null;
  max_move: number | null;
  level: number | null;
  gold: number | null;
  gold_bank: number | null;
  exp: number | null;
  exp_to_next: number | null;
  position: string | null;
  last_direction: string | null;
  title: string | null;
  /** Reserved. Null until a capture proves this build's `score` prints them. */
  char_class: string | null;
  race: string | null;
  /** Verbatim "94/10" — two numbers, and deciding which is which is a guess. */
  armor_class: string | null;
  alignment: number | null;
  age_years: number | null;
  practices_left: number | null;
  /** Split server-side from the stored comma list. */
  conditions: string[];
  /**
   * When the item snapshot was last REPLACED — deliberately a different clock
   * from `updated_at`. The agent does not re-read its pack after every get and
   * drop, and the page says how old the list is rather than implying it is now.
   */
  items_updated_at: string | null;
  /** The boukensha run that last wrote — links belief back to its transcript. */
  session_id: string | null;
  updated_at: string | null;
  current_room: RoomRef | null;
  prev_room: RoomRef | null;
}

/** EARNED: survives logout, updated in place, never wiped by a short listing. */
export interface KnowledgeSkill {
  name: string;
  /**
   * A WORD — "good", "not learned" — because that is what this MUD prints.
   * There is no percent in the output, so there is none here; null means the
   * listing carried no grade, not that the character has no ability.
   */
  proficiency: string | null;
  learned: boolean;
  kind: string | null;
  learned_level: number | null;
  first_seen_at: string | null;
  last_seen_at: string | null;
}

/** VOLATILE: replaced wholesale on each reading. There is no history here. */
export interface KnowledgeItem {
  id: number;
  location: "inventory" | "equipped";
  /** Equipped rows only: "wielded", "worn on body". */
  worn_on: string | null;
  keyword: string | null;
  descr: string;
  quantity: number;
  updated_at: string | null;
}

export interface KnowledgeOverview extends KnowledgeEnvelope {
  stats: KnowledgeStats;
  /** null until the agent has looked at something. */
  player: KnowledgePlayer | null;
}

export interface KnowledgePlayerPage extends KnowledgeEnvelope {
  player: KnowledgePlayer | null;
  /** All empty against a pre-V2 file — an older agent's memory, served. */
  skills: KnowledgeSkill[];
  inventory: KnowledgeItem[];
  equipped: KnowledgeItem[];
}

export interface KnowledgeExit {
  direction: string;
  target_name: string | null;
  /** null IS the exploration frontier — a named door never walked through. */
  target_room_id: number | null;
  traversals: number;
  last_seen_at: string;
}

export interface KnowledgeRoom {
  id: number;
  name: string;
  description: string;
  confidence: "confirmed" | "provisional";
  look_candidates: string[];
  visit_count: number;
  first_seen_at: string;
  last_seen_at: string;
  surveyed_at: string | null;
  weak_fingerprint: string;
  strong_fingerprint: string | null;
  exits: KnowledgeExit[];
  entity_count: number;
  entities: KnowledgeRoomEntity[];
}

export interface KnowledgeRoomEntity {
  id: number;
  kind: "mob" | "object";
  descr: string;
  keyword: string | null;
}

export interface KnowledgeSighting {
  room_id: number;
  room_name: string;
  count: number;
  sighting_count: number;
  last_seen_at: string;
}

export interface KnowledgeEntity {
  id: number;
  kind: "mob" | "object";
  descr: string;
  keyword: string | null;
  equipment: string[];
  /** consider's verdict — meaningless without threat_level (see ThreatChip). */
  threat: string | null;
  /** The player level the verdict was measured at. Null = never appraised. */
  threat_level: number | null;
  seen_count: number;
  first_seen_at: string;
  last_seen_at: string;
  /** Present on /entities; absent on a room's inhabitant list. */
  sightings?: KnowledgeSighting[];
  /** Present only on a room's inhabitant list — that room's own counters. */
  count?: number;
  sighting_count?: number;
}

export interface KnowledgeEncounter {
  id: number;
  room_id: number | null;
  room_name: string | null;
  entity_id: number | null;
  entity_descr: string | null;
  player_level: number | null;
  outcome: "won" | "fled" | "died" | "abandoned" | null;
  hp_before: number | null;
  hp_after: number | null;
  at: string;
}

export interface InboundExit {
  room_id: number;
  room_name: string;
  direction: string;
}

export interface KnowledgeRoomsPage extends KnowledgeEnvelope {
  rooms: KnowledgeRoom[];
}

/**
 * The rooms payload plus the player pin, stitched client-side from the two
 * endpoints that already exist — /knowledge/rooms is already a graph (`id`,
 * `name`, `exits[].target_room_id`), so the map is a renderer over an unchanged
 * API rather than a seventh endpoint restating the sixth.
 */
export interface KnowledgeMapPage extends KnowledgeRoomsPage {
  player: KnowledgePlayer | null;
}

export interface KnowledgeRoomDetail extends KnowledgeEnvelope {
  room: KnowledgeRoom;
  entities: KnowledgeEntity[];
  encounters: KnowledgeEncounter[];
  inbound: InboundExit[];
}

export interface KnowledgeEntitiesPage extends KnowledgeEnvelope {
  entities: KnowledgeEntity[];
}

export interface FrontierExit {
  room_id: number;
  room_name: string;
  direction: string;
  target_name: string | null;
  last_seen_at: string;
  room_surveyed: boolean;
}

export interface KnowledgeFrontierPage extends KnowledgeEnvelope {
  frontier: FrontierExit[];
  count: number;
}

// --- Progression journal ---------------------------------------------------
// The agent's append-only change log (.boukensha/journal/*.jsonl), read by the
// Progression view. Unlike knowledge (a snapshot), this is a time series: the
// server folds the day's records into per-key point arrays plus a milestone
// timeline and an item ledger. See change_capture.md.

export interface JournalPoint {
  seq: number;
  at: string;
  value: number | string | null;
}

export interface JournalMilestone {
  seq: number;
  at: string;
  op: string;
  level?: number | null;
  [key: string]: unknown;
}

export interface JournalItemEvent {
  seq: number;
  at: string;
  op: string;
  keyword?: string | null;
  descr?: string | null;
  tool?: string | null;
  qty?: number | null;
  [key: string]: unknown;
}

export interface JournalSeries {
  stats: Record<string, JournalPoint[]>;
  skills: Record<string, JournalPoint[]>;
  milestones: JournalMilestone[];
  items: JournalItemEvent[];
}

export interface JournalPage {
  date: string;
  series: JournalSeries;
  entries: Array<Record<string, unknown>>;
  next_seq: number;
  live: boolean;
}
