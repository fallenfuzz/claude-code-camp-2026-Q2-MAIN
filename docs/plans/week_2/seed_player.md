# SEED_PLAYER — replace and fully populate a test character

> **Status: implemented; live protocol verification pending.** `week2_capable/bin/seed_player` is a deterministic
> dev harness that deletes the configured mortal if it exists, creates that same player
> again from scratch, and applies a configurable uplift (level, money, stats, skills,
> inventory, and equipment). It then captures the populated player's real `score`,
> `inventory`, `equipment`, and `practice` output for `player_update.md`.

## Required behavior

Every invocation produces a new character, never a top-up of an old one:

1. Validate all seed settings before connecting.
2. Detect whether `PLAYER_NAME` exists.
3. If it exists, authenticate it, run this MUD's verified character-deletion flow, close
   the session, and prove on a fresh connection that the name is now treated as new.
4. Create `PLAYER_NAME` from scratch with the configured password, gender, and class.
5. Verify the new character reached the in-world prompt with a level-1 `score`.
6. Log in the immortal and apply every configured uplift.
7. Dress the configured equipment from the mortal session.
8. Read back and verify the actual player against the configuration.
9. Print the captures and optionally emit parser fixtures.

There is deliberately no “reuse existing character,” “top up,” or timestamped-name path.
Re-running is idempotent because it replaces the player before applying uplift, so money,
items, and other values cannot accumulate between runs.

## One easy edit point

All frequently changed non-secret values and the names of their secret environment
variables are hardcoded together at the top of `week2_capable/bin/seed_player`. The
password values themselves live in `.env` under the resolved Boukensha directory:

```ruby
require "dotenv"
require_relative "../boukensha/lib/boukensha_loader"

rc = BoukenshaLoader.load_rc
boukensha_dir = ENV["BOUKENSHA_DIR"] ||
  BoukenshaLoader.expand_rc_path(rc["boukensha_dir"]) ||
  File.join(Dir.home, ".boukensha")
ENV_FILE = File.join(File.expand_path(boukensha_dir), ".env")
Dotenv.load(ENV_FILE)

HOST = "localhost"
PORT = 4000

ADMIN_NAME         = "admin"
ADMIN_PASSWORD_ENV = "MUD_PASSWORD_ADMIN"

PLAYER_NAME         = "Andrew"
PLAYER_PASSWORD_ENV = "MUD_PASSWORD_ANDREW"
PLAYER_GENDER       = "M" # exact creation-menu input, verified in P0
PLAYER_CLASS        = "C" # exact creation-menu input, verified in P0

ADMIN_PASSWORD  = ENV.fetch(ADMIN_PASSWORD_ENV)
PLAYER_PASSWORD = ENV.fetch(PLAYER_PASSWORD_ENV)

UPLIFT = {
  level: 10,

  money: {
    gold: 5_000,
    bank: 1_000
  },

  stats: {
    align: 0
  },

  skills: {
    "armor" => 75,
    "cure light" => 75
  },

  # Spawned and left in the player's pack.
  inventory: [
    { vnum: 3001, keyword: "bottle", quantity: 2 }
  ],

  # Spawned, given to the player, then equipped with `wear`.
  equipment: [
    { vnum: 3023, keyword: "club", quantity: 1, wear: "wield" },
    { vnum: 3043, keyword: "jacket", quantity: 1, wear: "wear" }
  ]
}.freeze
```

The example vnums and uplift defaults come from the checked-in CircleMUD world data but
still require P0 confirmation against the running install. `money`, `stats`, and `skills` are separate so the
uplift is easy to scan. `inventory` means items left carried; `equipment` means items that
are spawned, transferred, and then dressed. `quantity` expands to repeated object loads.
`keyword` is the exact one-token identifier used to give and wear the freshly loaded object.

For example, the shared secret file contains:

```dotenv
MUD_PASSWORD_ADMIN=...
MUD_PASSWORD_ANDREW=...
```

The script validates the complete block before opening a socket:

- the resolved Boukensha directory's `.env` exists and is a regular file;
- both configured password-variable names are non-empty and exist in the loaded
  environment with non-empty values;
- names/gender/class are non-empty and creation choices are allowlisted;
- the player name cannot equal the admin name;
- numeric values, percentages, quantities, and vnums are integers in valid ranges;
- every equipment entry has a supported mortal wear command;
- duplicate or contradictory equipment declarations fail with a useful error.

The editable configuration therefore contains `MUD_PASSWORD_ANDREW`, not Andrew's
password. `Dotenv.load` does not overwrite a value already present in the process
environment; that standard precedence is acceptable, but the script must print only the
selected variable names and never their values. Both resolved passwords must be redacted
from terminal output, exceptions, and telnet logs.

## Reuse the existing SDK

The script is glue over the existing MUD Manager, following the shape of
`week2_capable/bin/reset`:

| Existing piece | Use |
|---|---|
| `MudManager::Session` | `open`, prompt reads, command sends, login, quiet reads, and close |
| `MudManager::Primitives` | mortal `score`/`inventory`/`equipment`/`practice`, item actions, and existing immortal movement commands |
| `week2_capable/bin/reset` | two-session lifecycle, redacted credentials, banners, and guarded cleanup |

New behavior belongs in narrowly scoped `Session` helpers when it is reusable
(`character_exists?`, `delete_character`, `create_character`); install-specific orchestration
may stay in the script. Prompt walking must use bounded `read_until` calls and fail loudly
with the raw buffer on a mismatch rather than hanging.

## Ground truth first

The exact deletion, creation, and god-command protocols are fork-specific. P0 must capture
them from this installation before implementation hardcodes them. These are hypotheses,
not specifications:

| Intent | Starting hypothesis | Must verify |
|---|---|---|
| delete player | main-menu option `5` → password verification → `yes` | exact prompts and proof the pfile/index entry is gone |
| create player | name confirmation → password twice → gender → class → MOTD | exact prompt text and accepted gender/class inputs |
| set level | `advance <name> <level>` | target must be online; valid range |
| set money/stat | `set <name> <field> <value>` | exact field names (`gold`, bank money, `exp`, alignment) |
| grant skill | `skillset <name> '<skill>' <percent>` | quoting, percent range, and class legality |
| spawn item | `load obj <vnum>` then `give` | where the item lands and how to identify it reliably for transfer |

The discovery transcript must include successful output and known refusal output so the
script can distinguish acceptance from `"Huh?!"`, invalid fields, illegal skills, bad
vnums, and failed transfers.

## Delete, prove absence, then create

Existence detection must use the login/name conversation and classify its captured prompt;
it must not infer existence from a timeout.

If the player exists, authenticate with the password resolved from `PLAYER_PASSWORD_ENV`,
remain at the tbaMUD main menu, select option `5`, re-enter the password, and type `yes`.
If authentication fails, a confirmation prompt differs, deletion is refused, or a new
connection still recognizes the name as existing, stop before uplift. Never seed over the
old character, silently choose a different name, or attempt a guessed admin deletion
command.

Deletion is destructive but tightly scoped:

- only the literal `PLAYER_NAME` constant can be targeted;
- `ADMIN_NAME` is explicitly rejected as a target;
- print `Resetting <name>: delete → recreate → uplift` before beginning;
- never accept an arbitrary deletion target from CLI input;
- never delete a pfile directly from the filesystem, because the MUD may maintain indexes
  or other in-memory state.

Once absence is proven, creation walks the captured prompts using `PLAYER_NAME`, the
resolved player password, `PLAYER_GENDER`, and `PLAYER_CLASS`. Success means reaching the
in-world prompt and reading a level-1 score. A partial or ambiguous creation stops the run.

## New immortal primitives

Add builders beside the existing immortal primitives, using the exact syntax proven by P0:

```ruby
def advance(name, level)
def set_field(name, field, value)
def skillset(name, skill, percent)
def load_obj(vnum)
```

They build and validate command lines but do not claim the live MUD accepted them.
`set_field` stays generic because supported fields are install-specific. `skillset` safely
quotes multi-word names. Unit tests cover command construction, escaping, types, ranges,
and rejection of empty input.

If deletion is an immortal command on this build, add one dedicated, strongly named
primitive for the verified command. Do not overload `purge`: removing a character from a
room is not proof that its saved player record was deleted.

## Applying the uplift

Keep both player and immortal sessions open after successful creation. Apply settings in a
stable order, echoing every non-secret command and checking each reply:

1. Advance to `UPLIFT[:level]`.
2. Apply every `money` and `stats` field with the verified `set` syntax.
3. Apply every configured skill percentage.
4. For each inventory/equipment entry and each unit of `quantity`, load the vnum and
   transfer that exact object to the player.
5. From the player session, issue the entry's configured `wear`/`wield` action for every
   equipment item. Inventory entries remain carried.

Object transfer must not rely on a vague keyword when two loaded objects could collide.
P0 must establish the reliable identifier/ordering strategy. Any rejected command, failed
transfer, or failed wear action is fatal; the final summary must not call a partial seed
successful.

After applying uplift, read `score`, `inventory`, `equipment`, and `practice` and compare
what is observable with the configuration:

- configured level, money, exp, and alignment match;
- every configured carried item and quantity appears;
- every configured equipped item appears in an equipment slot;
- configured skills appear at their expected percentages.

For fields that this MUD does not expose in those commands, print them as “applied but not
observable,” backed by the accepted immortal response. The summary shows configured versus
actual values and exits non-zero on any observable mismatch.

`practice` may list skills only at a class guildmaster. If confirmed in P0, the script
temporarily teleports the player to the configured class guild for the capture and also
captures the non-guild refusal.

## Fixture output

The normal run prints captures and verification but does not overwrite fixtures.
`--emit-fixtures` writes the hand-reviewable raw bytes (ANSI retained) to:

```text
week2_capable/boukensha/test/fixtures/player/
  score.txt
  inventory.txt
  inventory_empty.txt
  equipment.txt
  practice_guild.txt
  practice_refuse.txt
```

The populated files come from the final recreated/uplifted player. Empty/refusal fixtures
must be separately captured at the appropriate point in the lifecycle, not authored.
Fixture writes are atomic so a failed run cannot leave a mixture of old and new captures.

## Phasing

- **P0 — Protocol and data discovery.** Capture deletion and creation conversations plus
  successful/refused `advance`, `set`, `skillset`, `load`, `give`, and wear operations.
  Select valid default skills, object vnums, and any class-guild room. Done when every
  hardcoded protocol and example seed value is backed by this install.
- **P1 — Primitives.** Add and unit-test the required immortal command builders. Done when
  construction, quoting, validation, and rejection tests pass.
- **P2 — Reset lifecycle.** Implement existence detection, authenticated deletion,
  post-delete absence proof, creation, and level-1 proof. Done when two consecutive runs
  each demonstrate that the prior player was deleted and a new one was created.
- **P3 — Uplift and verification.** Add the top-level configuration, grants, item
  quantities, dressing, readback, and actual-versus-configured checks. Done when
  consecutive runs produce identical configured state without accumulation.
- **P4 — Fixtures.** Add atomic `--emit-fixtures` output and hand-check captures against
  the telnet log. Done when `player_update.md` has real populated and baseline fixtures.

## Invariants

1. **Replacement, not mutation-in-place.** An existing configured player is deleted and
   proven absent before creation or uplift.
2. **One edit point, no embedded secrets.** Name, password environment-variable name,
   gender, class, uplift, money, skills, items, and equipment live together at the top of
   the script; actual passwords come from the resolved Boukensha directory's `.env`.
3. **Ground truth over memory.** Every hardcoded MUD command and prompt traces to P0.
4. **Fail closed.** Authentication, deletion, creation, grant, transfer, wear, or
   verification ambiguity stops the run with a non-zero exit.
5. **Announce mutations and redact secrets.** Commands are visible; passwords never are.
6. **Captures are verbatim.** Parsers adapt to real MUD bytes, including ANSI.
7. **Dev-only and local by default.** This is a fixture harness, not part of the live agent
   path.

## Out of scope

- Building the parsers/schema described by `player_update.md`.
- Top-ups or grants for the live agent character.
- Direct pfile manipulation, wildcard deletion, or bulk player cleanup.
- Non-player world seeding such as spawning mobs or rooms.
