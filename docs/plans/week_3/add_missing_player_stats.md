## Add Missing Player Stats

In our SQLite knowledgebase, it should have:

- class
- gender

We should be able to see these values in
`http://localhost:5173/knowledge/player` for mud_monitor.

It should not have race attribute since there is no race for a player in tbaMUD

- race should remove from mud_monitor
- race should not be in our schema

The agent cannot extract this information from `score`: this tbaMUD build does
not print it. Since the player is made by a human, store it in
`boukensha/profiles/<profile>/profile.yaml`.

```yaml
player:
  gender: m
  class: warrior
```

We should only allow valid settings:

- gender: `m` / `f` / `n`
- class: `magic_user` / `cleric` / `thief` / `warrior`

## Technical Solutions

### Decision

Treat class and gender as static character identity sourced from the selected
profile, not as observations parsed from MUD output.

At boukensha startup:

1. `Config` loads and validates the selected profile.
2. The loader opens and migrates that profile's `knowledge.sqlite3`.
3. The loader writes the validated class and gender into the single
   `player_state` row.
4. mud_monitor continues to read only SQLite.

This preserves the existing ownership boundary: boukensha is the only SQLite
writer and mud_monitor is read-only. It also gives the Knowledge UI one data
source instead of making it merge SQLite with `profile.yaml`.

`score` parsing must not be extended for these fields. The existing score
fixture proves the game output does not contain them, so parsing would invent
data or depend on unrelated prose.

### 1. Validate profile identity in `Boukensha::Config`

Update `week2_capable/boukensha/lib/boukensha/config.rb`.

Add frozen allowlists:

```ruby
PLAYER_GENDERS = %w[m f n].freeze
PLAYER_CLASSES = %w[magic_user cleric thief warrior].freeze
```

Expose a `player_identity` reader returning:

```ruby
{ gender: "m", player_class: "warrior" }
```

Validation happens while `profile.yaml` is loaded, so an invalid character
cannot start and cannot be copied into SQLite.

- `player` must be a mapping.
- `player.gender` is required and must be a string in `PLAYER_GENDERS`.
- `player.class` is required and must be a string in `PLAYER_CLASSES`.
- Do not silently normalize case, spaces, hyphens, or aliases. `Warrior`,
  `magic-user`, and `warriro` must fail.
- The `ArgumentError` must name the profile path, field, received value, and
  allowed values.
- Continue accepting the existing player keys such as `name`, `password_env`,
  `persona`, and `display_name`.

Requiring both fields is preferable to storing `NULL`: these facts cannot be
recovered later from the game, and a startup error points to the only place
where the problem can be fixed.

Update the example in `week2_capable/boukensha/README.md` and all repository
test/example profiles that boot boukensha.

### 2. Replace the reserved schema fields with the real contract

Append a V3 migration in
`week2_capable/boukensha/lib/boukensha/mud/memory/schema.rb`. Never edit the
already-applied V1 or V2 migrations.

V2 currently contains nullable `char_class` and `race` placeholders. V3 must
rebuild `player_state` so its final shape:

- removes `race` completely;
- replaces `char_class` with `player_class`;
- adds `gender`;
- constrains `player_class` to
  `magic_user | cleric | thief | warrior`;
- constrains `gender` to `m | f | n`;
- retains every other V2 column, value, primary key, and room foreign key.

Use `player_class` as the SQL, Ruby, and API name instead of bare `class`.
`class` is a language-level method in Ruby and would make hashes, serializers,
and search results needlessly ambiguous. The public YAML key remains the
requested `player.class`.

Use the standard SQLite table-rebuild sequence inside the migration
transaction:

1. Create `player_state_v3` with the complete final DDL.
2. Copy every retained column from `player_state`.
3. Copy `char_class` to `player_class` only when it is valid; otherwise copy
   `NULL`.
4. Drop the old table.
5. Rename `player_state_v3` to `player_state`.

Do not carry `race` through the copy. This is a schema deletion, not merely a
field hidden by the UI.

A fresh database applies V1, V2, then V3. An existing V2 profile upgrades in
place without losing room, vitals, score, inventory, or skill state.

### 3. Synchronize profile identity into SQLite

Update
`week2_capable/boukensha/lib/boukensha/mud/memory/store.rb` with:

```ruby
def set_player_identity!(player_class:, gender:)
  update_player!(player_class:, gender:)
end
```

This uses the existing single-row upsert and timestamp behavior. SQLite
constraints remain a second line of defense if the method is called without
`Config`.

In `week2_capable/boukensha/lib/boukensha_loader.rb`, call
`set_player_identity!` after the Store's journal is attached and before hooks
are installed. Pass `cfg.player_identity`.

This ordering guarantees:

- a new database has a player row before the first `look`;
- the current profile corrects an existing row on every launch;
- a valid profile change is reflected on the next launch;
- mud_monitor does not need profile-file access or a second merge path.

This is configuration hydration, not an agent observation. Do not add it to
`RoomParser`, score capture, or the model tool loop. It may use the Store's
existing journal change capture, so a real profile change remains auditable
while an unchanged launch stays a journal no-op.

### 4. Update the mud_monitor reader and API contract

Update `week2_capable/mud_monitor/api/lib/knowledge/reader.rb`.

- Return `player_class` and `gender` for V3.
- Never return `race` or `char_class`.
- Preserve support for V1 and V2 knowledge files.
- For V1, return both new values as `nil`.
- For V2, map legacy `char_class` to `player_class`, return `gender: nil`, and
  ignore legacy `race`.

The reader currently branches only on whether the “player half” exists.
Introduce an explicit schema-version branch (or a column-presence helper)
before selecting V3-only columns. This prevents querying `gender` against an
older database.

The player JSON returned by `GET /api/v1/knowledge/player` and embedded in the
overview envelope includes:

```json
{
  "player_class": "warrior",
  "gender": "m"
}
```

There must be no `race` property.

### 5. Update the Knowledge player page

Update:

- `week2_capable/mud_monitor/web/src/api/types.ts`
- `week2_capable/mud_monitor/web/src/pages/knowledge/Player.tsx`

In `KnowledgePlayer`, replace `char_class` and `race` with:

```ts
player_class: "magic_user" | "cleric" | "thief" | "warrior" | null;
gender: "m" | "f" | "n" | null;
```

On the Score sheet:

- render `Class` from `player.player_class`;
- render `Gender` from `player.gender`;
- remove the Race row and comments describing class/race as reserved score
  fields.

Display canonical values initially. A small exhaustive formatter may display
`magic_user` as `Magic user`, but the profile, database, and API retain the
canonical token. V1/V2 files render an em dash through the existing
`Fact`/`Unread` behavior.

### 6. Tests

#### Boukensha configuration

Add focused config tests covering:

- every valid gender and class;
- missing `player.gender` or `player.class`;
- invalid values, wrong case, non-string values, and `warriro`;
- existing unrelated profile settings still load;
- errors identify the file, field, value, and allowed values.

#### Schema and Store

Extend `week2_capable/boukensha/test/test_memory_store.rb` to prove:

- a fresh database reaches V3;
- a V2 database migrates without losing existing player or room data;
- `PRAGMA table_info(player_state)` includes `player_class` and `gender`;
- it includes neither `char_class` nor `race`;
- valid values upsert the one player row;
- invalid values fail SQLite `CHECK` constraints;
- a second sync updates values without creating another row.

#### mud_monitor API

Update the SQL fixture to V3 and give its player representative values. Keep
the frozen V1 fixture and add or retain a V2 fixture for compatibility.

Update reader and controller tests to prove:

- V3 returns `player_class` and `gender`;
- serialized JSON contains no `race` or `char_class` keys;
- V2 maps legacy class but does not expose legacy race;
- V1 returns `nil` for the two new fields;
- the player and overview endpoints agree.

#### Web

Run the TypeScript build after updating the contract. If page component tests
are added, assert that Class and Gender render and no Race label appears.

### 7. Verification

```sh
cd week2_capable/boukensha
bundle exec ruby -Itest test/test_memory_store.rb
bundle exec rake test

cd ../mud_monitor/api
bundle exec rails test test/lib/knowledge/reader_test.rb
bundle exec rails test test/controllers/api/v1/knowledge_controller_test.rb
bundle exec rails test

cd ../web
npm run build
```

Then launch boukensha once with a disposable valid profile and open
`http://localhost:5173/knowledge/player`. The page must show the configured
class and gender, must not show Race, and `PRAGMA table_info(player_state)` must
show that the SQLite table has no `race` column.

### Acceptance criteria

- Invalid or missing `player.gender` / `player.class` prevents boukensha from
  starting with an actionable error.
- Valid profile identity is copied to that profile's single SQLite row on
  startup without waiting for a model or MUD call.
- The final schema contains constrained `player_class` and `gender`, and
  contains no `race` or `char_class`.
- No score parser attempts to derive class, gender, or race.
- mud_monitor exposes `player_class` and `gender`, and never exposes `race`.
- `/knowledge/player` displays Class and Gender and has no Race row.
- Existing V1/V2 databases remain readable; V2 upgrades without loss of
  unrelated player or world knowledge.
- Boukensha, mud_monitor API, and mud_monitor web tests/builds pass.
