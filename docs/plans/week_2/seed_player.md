# SEED_PLAYER — a harness that creates and populates a test character

> **Status: plan, for review.** A script at `week2_capable/bin/seed_player` that logs an
> **immortal** in beside a fresh **mortal** character and grants it a level, gold, skills,
> and items — then reads back `score` / `inventory` / `equipment` / `practice` as that
> mortal and captures the real bytes. Its reason to exist is `player_update.md`: that plan
> cannot parse inventory/equipment/skills it has never seen, and today the agent is a
> level-1 pauper with an empty pack, so there is nothing to harvest. This script
> manufactures a rich character on demand and harvests the fixtures `player_update.md`'s
> parsers are built and tested against.

## Why this, and why now

The player half of the knowledgebase is empty because the *source* is empty:

- `parse_score` drops `exp` on this build (matches the stock `"scored N exp"`, but this MUD
  says `"You have N exp"`), and `parse_inventory` / `parse_equipment` / `parse_skills`
  **do not exist**.
- Even if they did, a level-1 newbie with `"You are not carrying anything."` and no
  practised skills gives them nothing to chew on.

`player_update.md` §0 is explicit that **fixtures are harvested, not authored** — every
parser test is seeded from a real string pulled out of the telnet log, because tbaMUD is
forked per install and the engine source is not in this repo. So before that plan can move,
we need real captures of a *populated* character's `score`, `inventory`, `equipment`, and
`practice`. That is this script's whole job: **stand up the character `player_update.md`
needs, and record what the MUD actually prints.**

This is a test/dev harness, not part of the live agent path. It ships in `bin/`, beside
`move_player_to_start_room` and `rebuild`.

## What already exists (reuse, don't rebuild)

The MUD SDK is done; this script is glue over it, exactly like `move_player_to_start_room`:

| Piece | What it gives us |
|---|---|
| `MudManager::Session` | telnet client: `open`, `login(user, pass)`, `send_command(cmd)`, `read_until(pattern)`, `read_until_quiet(s)`, `read_until_prompt`, `close` |
| `MudManager::Primitives` | builds validated command lines; mortal surface (`info_self("score"/"inventory"/"equipment")`, `practice`, `equip`, `get`, `drop`) **and** immortal `goto` / `transfer` / `teleport` / `at_location`; `START_ROOM = 3001` |
| `bin/move_player_to_start_room` | the template — logs in a player **and** an admin on separate sessions, issues an immortal command, reads the result; env-overridable creds (`ADMIN_USERNAME`/`ADMIN_PASSWORD` default `admin`/`password`, `PLAYER_USERNAME`/`PLAYER_PASSWORD` default `dummy`/`helloworld`, `MUD_HOST`/`MUD_PORT` default `localhost:4000`) |

So the connection, login, immortal-session, and read-until machinery are all solved. Two
things are genuinely missing and are the substance of this plan: **the immortal grant
commands** and **new-character creation**.

## Ground truth first — this install, not CircleMUD memory

Per the project rule (and `[[mud-engine-is-tbamud]]` / `[[verify-mud-mechanics-against-source]]`):
the exact god-command syntax and the character-creation prompt sequence are **forked per
install and must be confirmed against this MUD before being hardcoded.** The standard
CircleMUD/tbaMUD forms below are the *starting hypothesis*, not the spec:

| Intent | Hypothesised command | Must verify |
|---|---|---|
| set level | `advance <name> <level>` | name; whether it must be done while player is online; level cap for the granting immortal |
| set gold | `set <name> gold <n>` | field name (`gold`), and `set` vs `set file` for online vs offline |
| set exp | `set <name> exp <n>` | field name (`exp` vs `experience`) |
| set alignment | `set <name> align <n>` | field name |
| grant a skill | `skillset <name> '<skill>' <percent>` | quoting of multi-word skills; percent range; whether the skill must be legal for the class |
| spawn an item | `load obj <vnum>` | that it lands in the **loader's** inventory (so admin must then `give` it to the player), or whether a target arg exists |

**Phase 0 is a capture-only dry run** that issues each of these against the live MUD once
and records the reply, so every later hardcoded command is backed by a real transcript —
the same discipline `player_update.md` applies to its parsers. If a command comes back
`"Huh?!"` or an error, the transcript says so and the plan adjusts before automating it.

## New primitives (`MudManager::Primitives`)

Add the four immortal grant builders, in the existing style (build the line, validate args,
return a `Command`; never check live preconditions). They live in the `Admin / immortal`
section beside `goto`/`teleport`:

```ruby
def advance(name, level)          # "advance <name> <level>"
def set_field(name, field, value) # "set <name> <field> <value>"   (gold, exp, align, …)
def skillset(name, skill, pct)    # "skillset <name> '<skill>' <pct>"
def load_obj(vnum)                # "load obj <vnum>"
```

`set_field` is deliberately generic (one builder, any field) rather than one method per
stat — the field set is large and install-specific, and Phase 0 tells us which fields this
build honours. `skillset` quotes the skill name (multi-word skills like `second attack`).
All four validate types (`Integer` level/pct/vnum, non-empty name) but **not** legality —
that is the MUD's job and its refusal is itself a capture worth keeping.

## New-character creation (`Session#create_character`, or script-local)

`Session#login` only knows the **existing-user** flow (`Name → Password → into game`). A
brand-new name diverges into a prompt walk that this MUD's exact wording must be captured
for (Phase 0), but shapes up as:

```
Name?                         → <newname>
Did I get that right (Y/N)?   → Y
New character. Password:       → <pw>
Retype password:              → <pw>
Sex (M/F)?                    → M
Select a class: …             → <class letter>
[MOTD] → press RETURN         → \n
… into the game at the start room
```

Implemented as a `read_until(pattern)` walk (the Session already exposes it). Two honest
choices for **which** character, recommend the first:

- **A reusable fixture character** (default name e.g. `fixture`, overridable). Created once;
  on later runs the name already exists, so the script logs in and *re-populates* instead of
  re-creating. Keeps the MUD's pfile dir from filling with junk, and makes runs idempotent.
- **A fresh timestamped name each run** (`fixture_<ts>`). Guarantees a clean slate but
  litters pfiles and needs cleanup. Offer behind `--fresh`.

The creation walk is the most install-fragile part; it is gated behind Phase 0's captured
transcript and wrapped so a prompt mismatch fails loudly with the raw buffer, never hangs.

## What the script does (end to end)

`bin/seed_player` — env/flag-overridable throughout, mirroring `move_player_to_start_room`:

1. **Ensure the mortal exists.** Try `login`; on "unknown name", run the creation walk.
2. **Bring the mortal in-world** (they must be online for `advance`/`set`/`skillset`/`give`).
3. **Log the immortal in** on a second session.
4. **Grant**, each command echoed and its reply printed (and captured):
   - `advance <name> <target_level>` (default e.g. 10);
   - `set <name> gold <n>`, `set <name> exp <n>`, `set <name> align <n>`;
   - `skillset <name> '<skill>' <pct>` for a small class-legal set;
   - for each item vnum: immortal `goto <name>` → `load obj <vnum>` → `give <obj> <name>`
     (or whatever Phase 0 proves is the working path to the **player's** pack).
5. **Dress the mortal** so `equipment` is non-empty: player-session `wear`/`wield` some of
   the received items, leaving the rest carried — so both `inventory` and `equipment`
   capture real, non-empty output.
6. **Read back as the mortal**, capturing each verbatim: `score`, `inventory`, `equipment`,
   and `practice` (noting the guild caveat below).
7. **Emit fixtures** (see next section) and a human-readable summary of what was granted.

Positions in the world matter: `practice` with no argument lists skills **only at a
guildmaster** on stock CircleMUD (`player_update.md` §3 flags this). So step 6 optionally
`teleport`s the mortal to their class guild before `practice`, and captures both the guild
listing and the non-guild refusal — both are fixtures the parser must handle.

## The output — fixtures for `player_update.md`

The captures are the deliverable. Written where that plan's parser tests will read them,
mirroring how room fixtures are seeded:

```
week2_capable/boukensha/test/fixtures/player/
  score.txt          # populated: level, gold, exp, AC, align, title, conditions, maxes
  inventory.txt      # a pack with several items incl. a "(N) a torch" stack
  inventory_empty.txt# the "You are not carrying anything." baseline
  equipment.txt      # worn slots: <wielded>, <worn on body>, …
  practice_guild.txt # the skill listing at a guildmaster
  practice_refuse.txt# "You can't practice here." elsewhere
```

Plain `.txt` of the raw bytes (ANSI kept — the parser strips it, and the fixture must be
what the MUD really sent). A run also appends to the telnet log automatically, so the
captures are cross-checkable against `.boukensha/telnet/` exactly as the level-1 `score`
fixture already is. **Writing fixtures is behind `--emit-fixtures`**; the default run just
prints, so a curious run never overwrites a hand-checked fixture.

## Safety & etiquette

- **Read-only by default beyond the grants it announces.** It never deletes a character,
  never `set`s destructive fields, and prints every immortal command before sending it.
- **Guarded teardown** like the template's `ensure player&.close; admin&.close`.
- **Redaction.** Passwords come from env and are sent with `send_command(cmd, redact: true)`
  so they never reach the telnet log (the Session already supports `redact:`).
- **Local MUD only.** Defaults target `localhost:4000`; this is a dev fixture harness, not a
  tool to point at a shared server.

## Phasing

- **P0 — Discovery capture (dry run).** A throwaway `--probe` mode that logs the immortal in
  and issues each hypothesised command **once** against an existing char (`dummy`), plus a
  one-time manual capture of the new-character prompt sequence, recording every reply.
  *Done when* we have a transcript confirming the real syntax of `advance`/`set`/`skillset`/
  `load`/`give` and the creation prompts on **this** install.
- **P1 — Primitives.** Add `advance`, `set_field`, `skillset`, `load_obj` to
  `MudManager::Primitives` with unit tests (line-building + arg validation, the shape the
  existing primitive specs use). *Done when* the primitive suite is green.
- **P2 — Creation walk.** `Session#create_character` (or script-local) driven off the P0
  transcript, with a mismatch failing loudly. *Done when* a run creates the fixture char
  from cold and lands it in the start room.
- **P3 — Seed script.** `bin/seed_player`: ensure-exists → grant → dress → read-back, all
  echoed. *Done when* one invocation yields a level-N character with gold, skills, worn gear,
  and a non-empty pack, and prints its `score`/`inventory`/`equipment`/`practice`.
- **P4 — Fixtures.** `--emit-fixtures` writes the six `.txt` captures. *Done when*
  `test/fixtures/player/` is populated and hands `player_update.md` its P0 inputs.

## Invariants

1. **Ground truth over memory.** Every hardcoded god command traces to a P0 capture from
   this install; an unproven command is probed, not assumed.
2. **Reuse the SDK.** Connection/login/immortal/read machinery is `MudManager::Session` +
   `Primitives`; this script adds only the four grant builders and the creation walk.
3. **Idempotent by default.** Re-running re-populates the same fixture character rather than
   spawning a new one; `--fresh` is the opt-in that litters pfiles.
4. **Announce every mutation.** Each immortal command is printed before it is sent; nothing
   destructive is issued.
5. **Captures are verbatim.** Fixtures are the raw bytes (ANSI intact); the parser adapts to
   the MUD, never the reverse.
6. **Dev-only, local-only.** Not on the agent path; defaults target the local MUD.

## Not now / out of scope

- **Building the parsers or schema V2.** That is `player_update.md`; this script only feeds
  its fixtures. The two are adjacent, not merged.
- **A returning-character "top-up" for the live agent.** Auto-granting the *real* agent
  character levels/gold to speed play is a different (and judgment-laden) tool; this harness
  is for producing fixtures, not for pay-to-win.
- **Deleting/cleaning pfiles.** If `--fresh` litters, cleanup is a manual `purge`/pfile
  chore for now, not automated here.
- **Non-player world seeding** (spawning mobs/rooms for other tests) — the same immortal
  `load`/`goto` primitives would serve it, but that is a later harness.
