## Player Scoping

We are on week2_capable of our implementation.

I want to seed another new player so I can have enough data in my knoweldge.sqlite3 to create information in the mud monitor.
But the problem is my entire boukensha is scoped for a single player and same with my mud monitor.

In mud monitor I would assume we would have a drop down to change between players.
Probably the easiest thing is to have a .boukensha folder per player. It would be the easiest way to isolate them.

Our .boukensharc is also a sticking point. if we used a boukensha folder for each maybe it should be ./bounkensha/<player-profile>

and when we use boukensha we have to specific the profile eg. boukensha --profile dummy

## Technical Solution

Treat a **profile as one player's identity and runtime directory**. Do not add
`player_id` to `knowledge.sqlite3`, session logs, journals, or the memory
schema. Those artifacts describe one agent/player, so selecting a different
runtime root gives us the desired isolation with much less cross-cutting work.

Installation-level configuration and large/read-only assets stay at the top
level. A profile contains only settings and state that differ by player:

```text
~/.boukensha/
├── .env                         # shared provider/API secrets
├── settings.yaml                # shared agent/tool configuration
├── models/                      # installed once, shared read-only
├── prompts/                     # shared task prompts
└── profiles/
    ├── Andrew/
    │   ├── profile.yaml         # MUD identity + player overrides
    │   ├── knowledge.sqlite3
    │   ├── sessions/
    │   ├── journal/
    │   ├── manager/
    │   └── telnet/
    └── Dummy/
        └── ...
```

Profiles should be named after the player/character (`Andrew`, `Dummy`,
`Gandalf`), not after a role such as `main`, `default`, or `test`. The profile
name is the stable identifier shown by the CLI and Mud Monitor; `display_name`
in `profile.yaml` may preserve the exact capitalization shown by the MUD.

### Shared versus player-specific settings

The current `.boukensha/settings.yaml` is mostly installation configuration and
should not be copied into every profile.

| Top-level, shared once | Player profile |
|---|---|
| `.env` provider API keys (`ANTHROPIC_API_KEY`, etc.) | MUD character name |
| `models/look_candidates/**` and its manifest | MUD password's environment-variable name |
| default prompts and general player instructions | persona, preferences, and player-specific prompt additions |
| provider/model defaults and agent limits | optional provider/model override for an experiment |
| memory policy and look-candidate extractor choice | knowledge database and progression journal |
| tool and task permission allowlists | sessions, manager logs, and telnet logs |
| MCP command, args, prefix, and `required` | rare player-specific MCP environment overrides |
| MUD host/port when all characters use the same server | host/port override if a profile plays elsewhere |

Use a narrow, explicit `profile.yaml` schema rather than recursively merging a
second complete `settings.yaml`:

```yaml
player:
  name: Dummy
  password_env: MUD_PASSWORD_DUMMY
  persona: cautious-explorer

# Optional; absent keys inherit the top-level settings.
overrides:
  task:
    provider:
    model:
  mud:
    host:
    port:
```

The one top-level `.env` contains shared API keys and any player secrets under
namespaced keys:

```dotenv
ANTHROPIC_API_KEY=...
MUD_PASSWORD_ANDREW=...
MUD_PASSWORD_DUMMY=...
```

`password_env` is a reference, not the password itself. This keeps `.env`
top-level, avoids committing secrets to `profile.yaml`, and still allows every
player to authenticate differently. On launch, the profile resolver builds the
Mud Manager environment from shared MCP settings plus the selected profile:

```text
MUD_NAME=<profile.player.name>
MUD_PASSWORD=ENV.fetch(<profile.player.password_env>)
MUD_MANAGER_LOG_DIR=<profile runtime dir>/manager
MUD_TELNET_LOG_DIR=<profile runtime dir>/telnet
```

`Boukensha::Config` should expose both `root_dir` (shared config and assets) and
`profile_dir` (runtime state). Existing writers that currently use `config.dir`
should be changed to use `profile_dir`; model and prompt lookup should use
`root_dir`. Do not overload `BOUKENSHA_DIR` to mean both after this split.

### Launcher configuration and CLI

`~/.boukensharc` remains global launcher configuration, not player
configuration:

```yaml
boukensha_path: ~/Sites/omenking/claude-code-camp-2026-Q2/week2_capable/boukensha
boukensha_dir: ~/.boukensha
```

Add these invocations:

```bash
boukensha --profile Andrew
boukensha --profile Dummy
BOUKENSHA_PROFILE=Dummy boukensha
boukensha --list-profiles
```

The loader must parse and remove `--profile NAME` **before requiring
`boukensha.rb`**, then resolve:

```text
BOUKENSHA_DIR=<shared ~/.boukensha root>
BOUKENSHA_PROFILE_DIR=<BOUKENSHA_DIR>/profiles/<profile>
BOUKENSHA_PROFILE=<profile>
```

`BOUKENSHA_DIR` continues to identify the shared installation configuration.
`BOUKENSHA_PROFILE_DIR` is the root used by `Memory::Store.for_dir`, logger,
journal, and the Mud Manager log paths.

Selection precedence:

1. `--profile NAME`
2. `BOUKENSHA_PROFILE`
3. fail and print the available player names

There is deliberately no `default_profile`: requiring a player name prevents a
command intended for one character from silently logging in as another.
`BOUKENSHA_DIR` and a profile are no longer ambiguous because they select
different things (shared root versus child player).

Profile names are identifiers, not paths: accept something like
`[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}`, match them case-insensitively to an existing
directory, reject `.`/`..` and path separators, expand the result, and verify
that it remains below `<BOUKENSHA_DIR>/profiles`.

Do not silently create a misspelled profile during normal play. A selected
profile must already contain `profile.yaml`. Initially, creating one can be a
documented filesystem operation; a later `boukensha profile create NAME`
command may make that friendlier.

### Mud Monitor

Mud Monitor currently fixes one runtime `boukensha_dir` in its Rails
initializer. Replace that single-runtime-directory assumption with a small
`ProfileRegistry`:

- reads profiles from `<boukensha_dir>/profiles`;
- enumerates only valid child directories;
- returns a profile name plus its canonical runtime directory;
- also exposes the old unprofiled directory as `legacy` during migration;
- never accepts an arbitrary directory from the browser.

Add:

```text
GET /api/v1/profiles
  -> { profiles: [{ id, label, available }] }
```

In React, save the selected profile ID in
`localStorage["mud-monitor.profile"]`. There is no `profile` GET parameter and
changing tabs does not put profile state into the URL.

The backend still needs to know which local directory to read. Mirror the
localStorage value into a same-origin `mud_monitor_profile` cookie whenever the
selection changes. Normal `fetch` calls and `EventSource` SSE connections then
send the selection automatically. The cookie contains only a non-secret profile
ID, may be JavaScript-readable, and should use `SameSite=Strict`. If it is
missing or names a nonexistent profile, data endpoints return
`409 profile_selection_required` with the available profiles; they must not
guess a player. `/api/v1/profiles` is the only endpoint that does not require
the cookie.

Every endpoint resolves all of its paths from the cookie-selected profile. This
matters beyond `knowledge.sqlite3`: showing one player's knowledge beside
another player's sessions or journal would produce a convincing but false
history. Put the selected profile in every response envelope so the UI can
detect accidental mixing.

Add the profile selector to the top bar. On startup, load the saved choice,
confirm that it still exists in `/profiles`, set the cookie, and then render
profile-backed routes. Changing it updates localStorage and the cookie,
invalidates/refetches every page, and reconnects SSE streams. Because selection
is browser-local, shared URLs intentionally open using the receiving browser's
last selected player.

The monitor is read-only and must tolerate profiles at different lifecycle
stages: no knowledge DB yet, no sessions yet, or no journal yet are empty
states, not server errors.

### Migration

1. Keep `.env`, `settings.yaml`, `models/`, and shared prompts at
   `~/.boukensha`.
2. Create a profile named after the current character and move only its
   database and log directories under that profile.
3. Create `~/.boukensha/profiles/Dummy` with `profile.yaml` and empty runtime
   state.
4. Move MUD identity out of shared `settings.yaml`; store each character name
   and password environment-variable reference in its `profile.yaml`, with the
   actual secrets remaining in the top-level `.env`.
5. During migration only, expose the existing unprofiled runtime artifacts as
   `legacy` in Mud Monitor. Do not permit new Boukensha runs to select
   `legacy`.
6. Run the seed-player work against `Dummy`, then launch
   `boukensha --profile Dummy`; the monitor should switch between the two
   player names without restarting.

Do not merge the two knowledge databases. Their room IDs may describe the same
world, but confidence, encounters, player state, and progression are
player-specific observations.

### Implementation phases

- **P1 — Split shared/profile configuration.** Add `root_dir`, `profile_dir`,
  the narrow `profile.yaml` schema, namespaced password lookup, model/prompt
  lookup from the root, and state writers under the profile.
- **P2 — Profile resolver and loader.** Add CLI parsing, validation, and
  `--list-profiles`. Unit-test traversal rejection, missing profiles, env/CLI
  precedence, missing password variables, and the no-default behavior.
- **P3 — Two-profile CLI smoke test.** Run two player-named profiles; prove
  their knowledge DB, sessions, journals, manager logs, and telnet logs are
  written under different runtime roots while sharing models and API keys.
- **P4 — Monitor registry/API.** Add `/profiles`, require a cookie-resolved
  profile in every file/knowledge reader, and test that a request cannot escape
  `profiles/` or combine roots.
- **P5 — Monitor selector.** Add localStorage persistence plus cookie
  transport, propagate changes through normal requests and SSE reconnects, and
  render per-profile empty states.
- **P6 — Migration and seeding.** Establish two player-named profiles,
  configure and seed `Dummy`, and verify live switching in Mud Monitor.

### Invariants

1. One Boukensha process runs exactly one profile.
2. Shared configuration/assets have one root; each profile owns exactly one
   runtime root.
3. No SQLite table or JSONL record needs a `player_id` merely to implement
   profile switching.
4. Mud Monitor selects one profile for the whole UI, not independently per tab.
5. Profile input is a validated name resolved through the registry, never a
   client-supplied filesystem path.
6. Neither CLI nor monitor silently chooses a default player.
7. Legacy single-player installations keep working during migration.

### Not now

- Running multiple player agents inside one Boukensha process. Two concurrent
  players should initially be two processes with two profiles.
- Shared/cross-player world knowledge. That requires explicit provenance and
  merge semantics; it should not emerge from pointing two writers at one
  SQLite file.
- Arbitrary recursive configuration inheritance between profiles.
- Character creation and stat/item grants; those remain the responsibility of
  `seed_player.md`.
