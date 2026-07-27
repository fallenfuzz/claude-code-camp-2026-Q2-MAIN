-- A knowledge.sqlite3 as the agent writes it.
--
-- SQL, not a committed .sqlite3 binary: a binary fixture cannot be reviewed in
-- a diff and rots silently the first time boukensha's schema moves. The DDL
-- below is a verbatim copy of Boukensha::Mud::Memory::Schema V1 + V2 + V3 (comments
-- stripped, and with the migrations folded into the player_state CREATE, which is
-- the shape a migrated file ends up in) — if a test starts failing because a
-- column moved, THAT is the signal, and this file is where the drift is
-- recorded. seed_v1.sql is the frozen pre-V2 copy, kept so the reader can be
-- proven to still serve an older agent's file.
--
-- The rows are chosen for edge cases, not realism:
--   room 1  surveyed, confirmed, look_candidates populated, has entities
--   room 2  surveyed, confirmed, look_candidates = []
--   room 3  NOT surveyed — surveyed_at IS NULL
--   room 4  provisional confidence
--   room 5  look_candidates is malformed JSON (must degrade to [], not raise)
--   exits   a mix of linked and frontier (target_room_id IS NULL)
--   entity 4  has a threat verdict but NO threat_level (unmeasured level),
--             and equipment, which is a JSON array string like look_candidates
--   encounters  one row — the live DB has zero, so this is otherwise untested
--   player_state   the full V3 sheet, including profile-sourced identity
--   player_skills  a learned one, an unlearned one, and one with no grade at
--             all — proficiency is a WORD in this build, never a percent
--   player_items   both locations, a stacked row, and an equipped row whose
--             slot is filled but whose item the MUD never named

CREATE TABLE rooms (
  id               INTEGER PRIMARY KEY,
  weak_fingerprint   TEXT NOT NULL,
  strong_fingerprint TEXT,
  confidence         TEXT NOT NULL DEFAULT 'confirmed'
                       CHECK (confidence IN ('confirmed','provisional')),
  name             TEXT NOT NULL,
  description      TEXT NOT NULL,
  look_candidates  TEXT,
  first_seen_at    TEXT NOT NULL,
  last_seen_at     TEXT NOT NULL,
  visit_count      INTEGER NOT NULL DEFAULT 1,
  surveyed_at      TEXT
);
CREATE INDEX idx_rooms_weak ON rooms(weak_fingerprint);
CREATE INDEX idx_rooms_name ON rooms(name);

CREATE TABLE room_exits (
  room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  direction      TEXT NOT NULL,
  target_name    TEXT,
  target_room_id INTEGER REFERENCES rooms(id),
  traversals     INTEGER NOT NULL DEFAULT 0,
  last_seen_at   TEXT NOT NULL,
  PRIMARY KEY (room_id, direction)
);
CREATE INDEX idx_exits_frontier ON room_exits(target_room_id) WHERE target_room_id IS NULL;

CREATE TABLE entities (
  id            INTEGER PRIMARY KEY,
  kind          TEXT NOT NULL CHECK (kind IN ('mob','object')),
  descr         TEXT NOT NULL,
  keyword       TEXT,
  equipment     TEXT,
  threat        TEXT,
  threat_level  INTEGER,
  seen_count    INTEGER NOT NULL DEFAULT 1,
  first_seen_at TEXT NOT NULL,
  last_seen_at  TEXT NOT NULL,
  UNIQUE (kind, descr)
);

CREATE TABLE entity_sightings (
  entity_id      INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  room_id        INTEGER NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  count          INTEGER NOT NULL DEFAULT 1,
  sighting_count INTEGER NOT NULL DEFAULT 1,
  first_seen_at  TEXT NOT NULL,
  last_seen_at   TEXT NOT NULL,
  PRIMARY KEY (entity_id, room_id)
);
CREATE INDEX idx_sightings_room ON entity_sightings(room_id);

CREATE TABLE player_state (
  id              INTEGER PRIMARY KEY CHECK (id = 1),
  current_room_id INTEGER REFERENCES rooms(id),
  prev_room_id    INTEGER REFERENCES rooms(id),
  last_direction  TEXT,
  hp INTEGER, max_hp INTEGER,
  mana INTEGER, move INTEGER,
  level INTEGER, gold INTEGER, exp INTEGER,
  position        TEXT,
  session_id      TEXT,
  updated_at      TEXT NOT NULL,
  max_mana         INTEGER,
  max_move         INTEGER,
  exp_to_next      INTEGER,
  armor_class      TEXT,
  alignment        INTEGER,
  age_years        INTEGER,
  title            TEXT,
  player_class     TEXT CHECK (player_class IN ('magic_user','cleric','thief','warrior')),
  gender           TEXT CHECK (gender IN ('m','f','n')),
  gold_bank        INTEGER,
  conditions       TEXT,
  practices_left   INTEGER,
  items_updated_at TEXT
);

CREATE TABLE player_skills (
  name          TEXT PRIMARY KEY,
  proficiency   TEXT,
  learned       INTEGER NOT NULL DEFAULT 0,
  kind          TEXT,
  learned_level INTEGER,
  first_seen_at TEXT NOT NULL,
  last_seen_at  TEXT NOT NULL
);

CREATE TABLE player_items (
  id         INTEGER PRIMARY KEY,
  location   TEXT NOT NULL CHECK (location IN ('inventory','equipped')),
  worn_on    TEXT,
  keyword    TEXT,
  descr      TEXT NOT NULL,
  quantity   INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_items_location ON player_items(location);

CREATE TABLE encounters (
  id            INTEGER PRIMARY KEY,
  room_id       INTEGER REFERENCES rooms(id),
  entity_id     INTEGER REFERENCES entities(id),
  player_level  INTEGER,
  outcome       TEXT CHECK (outcome IN ('won','fled','died','abandoned')),
  hp_before INTEGER, hp_after INTEGER,
  at            TEXT NOT NULL
);
CREATE INDEX idx_encounters_entity ON encounters(entity_id);

PRAGMA user_version = 3;

INSERT INTO rooms (id, weak_fingerprint, strong_fingerprint, confidence, name, description,
                   look_candidates, first_seen_at, last_seen_at, visit_count, surveyed_at) VALUES
  (1, 'weak0001', 'strong0001', 'confirmed', 'The Temple Of Midgaard',
   'You are in the southern end of the temple hall in the Temple of Midgaard.',
   '["wall","paintings","giants"]', '2026-07-23T22:55:40Z', '2026-07-23T22:55:40Z', 3, '2026-07-23T22:55:40Z'),
  (2, 'weak0002', 'strong0002', 'confirmed', 'The Temple Square',
   'You are standing on the temple square.',
   '[]', '2026-07-23T22:55:42Z', '2026-07-23T22:55:42Z', 1, '2026-07-23T22:55:42Z'),
  (3, 'weak0003', NULL, 'confirmed', 'Market Square',
   'You are standing on the market square, the famous Square of Midgaard.',
   NULL, '2026-07-23T22:55:43Z', '2026-07-23T22:55:43Z', 1, NULL),
  (4, 'weak0004', NULL, 'provisional', 'A Dark Alley',
   'The alley is too dark to make out much of anything.',
   '[]', '2026-07-23T22:55:44Z', '2026-07-23T22:55:44Z', 1, NULL),
  (5, 'weak0005', 'strong0005', 'confirmed', 'The Common Square',
   'The common square, people pass you, talking to each other.',
   '{not json', '2026-07-23T22:55:45Z', '2026-07-23T22:55:45Z', 2, '2026-07-23T22:55:45Z');

INSERT INTO room_exits (room_id, direction, target_name, target_room_id, traversals, last_seen_at) VALUES
  (1, 'south', 'The Temple Square',          2,    1, '2026-07-23T22:55:42Z'),
  (1, 'north', 'By The Temple Altar',        NULL, 0, '2026-07-23T22:55:40Z'),
  (1, 'east',  'The Midgaard Donation Room', NULL, 0, '2026-07-23T22:55:40Z'),
  (2, 'north', 'The Temple Of Midgaard',     1,    1, '2026-07-23T22:55:42Z'),
  (2, 'south', 'Market Square',              3,    1, '2026-07-23T22:55:43Z'),
  (3, 'west',  NULL,                         NULL, 0, '2026-07-23T22:55:43Z'),
  (4, 'up',    'The Common Square',          5,    2, '2026-07-23T22:55:45Z'),
  (5, 'down',  'A Dark Alley',               NULL, 0, '2026-07-23T22:55:45Z');

INSERT INTO entities (id, kind, descr, keyword, equipment, threat, threat_level,
                      seen_count, first_seen_at, last_seen_at) VALUES
  (1, 'mob', 'A cityguard stands here.', 'cityguard', NULL, 'Are you mad!?', 1,
   6, '2026-07-23T22:55:40Z', '2026-07-23T22:55:45Z'),
  (2, 'mob', 'A beastly fido is mucking through the garbage.', 'fido', NULL, 'The perfect match!', 1,
   4, '2026-07-23T22:55:41Z', '2026-07-23T22:55:44Z'),
  (3, 'object', 'An automatic teller machine has been installed in the wall.', 'machine', NULL, NULL, NULL,
   1, '2026-07-23T22:55:43Z', '2026-07-23T22:55:43Z'),
  (4, 'mob', 'The Mayor is standing here.', 'mayor', '["a gold ring <worn on finger>"]', 'You ARE mad!', NULL,
   2, '2026-07-23T22:55:44Z', '2026-07-23T22:55:44Z');

INSERT INTO entity_sightings (entity_id, room_id, count, sighting_count, first_seen_at, last_seen_at) VALUES
  (1, 1, 1, 4, '2026-07-23T22:55:40Z', '2026-07-23T22:55:45Z'),
  (1, 3, 2, 2, '2026-07-23T22:55:43Z', '2026-07-23T22:55:43Z'),
  (2, 1, 1, 3, '2026-07-23T22:55:41Z', '2026-07-23T22:55:44Z'),
  (3, 3, 1, 1, '2026-07-23T22:55:43Z', '2026-07-23T22:55:43Z'),
  (4, 1, 1, 2, '2026-07-23T22:55:44Z', '2026-07-23T22:55:44Z');

INSERT INTO player_state (id, current_room_id, prev_room_id, last_direction,
                          hp, max_hp, mana, move, level, gold, exp, position,
                          session_id, updated_at,
                          max_mana, max_move, exp_to_next, armor_class, alignment, age_years,
                          title, player_class, gender, gold_bank, conditions, practices_left,
                          items_updated_at) VALUES
  (1, 5, 4, 'up', 18, 20, 100, 72, 2, 15, 900, 'Standing',
   '20260723T225532Z-7ed8c53a', '2026-07-23T22:56:01Z',
   162, 94, 1099, '94/10', 0, 17,
   'Derrano the Minister', 'cleric', 'm', NULL, 'hungry,thirsty', 30,
   -- Deliberately OLDER than updated_at: the bag is a snapshot the agent has
   -- not refreshed since, and the UI has to say so rather than imply freshness.
   '2026-07-23T22:55:58Z');

INSERT INTO player_skills (name, proficiency, learned, kind, learned_level, first_seen_at, last_seen_at) VALUES
  ('armor',      'good',        1, 'spell', 2,    '2026-07-23T22:55:50Z', '2026-07-23T22:55:58Z'),
  ('bless',      'not learned', 0, 'spell', NULL, '2026-07-23T22:55:50Z', '2026-07-23T22:55:58Z'),
  ('cure light', 'good',        1, 'spell', 1,    '2026-07-23T22:55:50Z', '2026-07-23T22:55:58Z'),
  -- Known, but the listing carried no grade for it: proficiency is NULL, which
  -- is "not read", not "no ability".
  ('sneak',      NULL,          1, 'skill', NULL, '2026-07-23T22:55:52Z', '2026-07-23T22:55:58Z');

INSERT INTO player_items (id, location, worn_on, keyword, descr, quantity, updated_at) VALUES
  (1, 'inventory', NULL,           'bottle', 'a bottle',          2, '2026-07-23T22:55:58Z'),
  (2, 'inventory', NULL,           'lantern', 'a hooded lantern', 1, '2026-07-23T22:55:58Z'),
  (3, 'equipped',  'worn on body', 'jacket', 'a leather jacket',  1, '2026-07-23T22:55:58Z'),
  (4, 'equipped',  'wielded',      'club',   'a wooden club',     1, '2026-07-23T22:55:58Z'),
  -- A filled slot the MUD named nothing for. descr is NOT NULL, so the reader
  -- gets an empty-ish row rather than a missing slot: "something is worn here"
  -- is itself a reading.
  (5, 'equipped',  'worn on finger', NULL,   '',                  1, '2026-07-23T22:55:58Z');

INSERT INTO encounters (id, room_id, entity_id, player_level, outcome, hp_before, hp_after, at) VALUES
  (1, 1, 2, 1, 'fled', 20, 9, '2026-07-23T22:55:50Z');
