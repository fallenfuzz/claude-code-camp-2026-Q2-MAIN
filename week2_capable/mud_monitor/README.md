# Mud Monitor

Unified observability app: Rails 8 API (SQLite) + Vite/React/TS frontend.
Spec: `docs/plans/week_2/mud_monitor.md`.

Status: through **Phase 5** (§9 of the spec). Session API + React transcript
(ported from `week1_baseline/log_viz`), ms timestamps + timing gutter, SSE live
tailing, `ManagerLog` (`/manager`, every command mud_manager actually executed
against the MUD), and `TelnetLog` (`/telnet`, every byte that crossed the
socket in both directions, independent of what the manager or agent layer
kept). Both logs are off by default (`MUD_MANAGER_LOG_DIR` /
`MUD_TELNET_LOG_DIR` unset). No dropped/reshaped diffs, correlation ids, or
world pages yet — those land in later phases.

The **Knowledge** page reads the agent's world memory (`knowledge.sqlite3`). Its
change history is the append-only journal (`.boukensha/journal/*.jsonl`), served
by `/api/v1/journal` and surfaced two ways:

- **Change Log** (top-level nav, `/journal`) — the raw CDC feed: every
  upsert/update/delete across the whole knowledgebase (player stats, rooms,
  exits, entities, sightings, encounters, items), filterable by stream, emitted
  only when a value actually changed. This is generic change data capture wired
  at the `Memory::Store` layer.
- **Knowledge → Progression** subtab — the graphed timeline of that same data:
  level/exp/gold/vitals over time, a milestone timeline (level-ups, deaths),
  skills, and an item ledger.

Unlike knowledge (a polled snapshot), the journal is a streamable time series
with a `seq` cursor. Path is resolved from `boukensha_dir` (override with
`MUD_MONITOR_JOURNAL_DIR`); when the agent has not journalled yet, both views
render empty. See `docs/plans/week_2/change_capture.md`.

## Run

```
bin/setup   # bundle install + npm ci + db:prepare
bin/dev     # api on :3000, web on :5173 (proxies /api -> :3000)
```

Open http://localhost:5173.

## Layout

- `api/` — Rails API-only app (`app/controllers/api/v1`, `config/database.yml`)
- `web/` — Vite + React + TS app (mirrors `week0_explore/preview/web`'s stack)
- `Procfile.dev` — the two dev processes, run via `bin/dev` (foreman)
