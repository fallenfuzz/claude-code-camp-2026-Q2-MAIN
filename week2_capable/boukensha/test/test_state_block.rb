require_relative "helper"

# Mud::StateBlock — what the model is shown about where it is.
#
# The measurement this replaces: the old inspect_room payload was 921 chars ≈
# 230 tokens, PERMANENT (a tool_result, re-sent on every later call, once per
# visit). These assertions are mostly about what is deliberately absent.
class TestStateBlock < Minitest::Test
  S = Boukensha::Mud::StateBlock

  def room(**over)
    { id: 1, name: "Market Square", description: "You are standing on the market square.",
      visit_count: 1, confidence: "confirmed" }.merge(over)
  end

  def exits
    [
      { direction: "north", target_name: "The Temple Square", target_room_id: 2 },
      { direction: "east",  target_name: "Main Street",       target_room_id: nil },
      { direction: "up",    target_name: nil,                 target_room_id: nil }
    ]
  end

  def player
    { hp: 20, max_hp: 20, mana: 100, move: 81, level: 1, gold: 43, position: "standing" }
  end

  def test_renders_the_documented_shape
    out = S.render(room: room(visit_count: 2), exits: exits, player: player,
                   here: [{ desc: "A cityguard stands here.", count: 1, kind: "mob",
                            threat: "you could take him", threat_fresh: true }])

    assert_equal <<~BLOCK.strip, out
      [here] Market Square  (visit 2)
      exits: north→The Temple Square ✓ | east→Main Street ? | up ?
      here: A cityguard stands here. (mob — "you could take him")
      you: 20/20hp 100mana 81mv · lvl 1 · 43 gold · standing
    BLOCK
  end

  # The whole design in one number: ~45 tokens, transient, one copy — against
  # ~230 tokens permanent and re-sent, once per visit.
  def test_the_block_is_small
    out = S.render(room: room(visit_count: 2), exits: exits, player: player,
                   here: [{ desc: "A cityguard stands here.", count: 1, kind: "mob",
                            threat: "you could take him", threat_fresh: true }])

    assert_operator out.length, :<, 260, "the payload it replaces was 921 chars"
  end

  # The prose is the largest field in the record and static. The agent has
  # already read it.
  def test_the_description_is_sent_on_the_first_visit_only
    assert_includes S.render(room: room, exits: exits, first_visit: true), "market square"
    refute_includes S.render(room: room(visit_count: 2), exits: exits), "market square"
  end

  # `✓` vs `?` is the exploration frontier, and information the agent has never
  # had — today it cannot tell "east, which I've mapped" from "east, unknown".
  def test_the_frontier_glyph
    line = S.render(room: room, exits: exits).lines[1]

    assert_includes line, "north→The Temple Square ✓"
    assert_includes line, "east→Main Street ?"
    assert_includes line, "up ?", "a direction with no name yet is still a frontier"
  end

  # A model told the location is ambiguous can act sensibly. A model told a
  # confident lie cannot.
  def test_an_uncertain_room_says_so
    out = S.render(room: room(name: "The Dark Alley", confidence: "provisional"), ambiguity: 2)
    assert_includes out, "[here] The Dark Alley  (uncertain — 2 candidates)"
  end

  def test_no_room_is_admitted_rather_than_guessed
    assert_includes S.render(room: nil, player: player), "(unknown — no room established yet)"
  end

  # ---------- a position never established, and one lost -------------------
  #
  # blind_step_recovery.md §5.6. The two are different situations and the old line
  # said the same thing for both: "yet" reads as a cold start the next automatic
  # `look` will resolve, which is true of a fresh process and false in an unlit
  # room, where looking again can never work. Session 20260731T151434Z-737a23cb
  # read that line twenty-three times.
  def test_a_lost_position_is_not_reported_as_a_cold_start
    out = S.render(room: nil, player: player,
                   lost: { room: room(name: "The Clerics' Inner Sanctum"), direction: "down" })

    assert_includes out, "your position was lost after walking down out of The Clerics' Inner Sanctum"
    refute_includes out, "no room established yet"
  end

  def test_a_lost_position_names_a_call_the_player_can_make
    out = S.render(room: nil, player: player,
                   lost: { room: room(name: "A Junction"), direction: "down",
                           recovery: "recovery_exhausted" })

    assert_includes out, "move_to(destination: \"north\")"
  end

  # …and after `stuck` it names none, because every direction has been refused and
  # inviting another step would be a lie the agent would spend its budget on.
  def test_a_sealed_room_offers_no_remedy
    out = S.render(room: nil, player: player,
                   lost: { room: room(name: "A Junction"), direction: "down", recovery: "stuck" })

    assert_includes out, "walking will not re-establish it"
    refute_includes out, "move_to(destination:"
  end

  # `consider`'s verdict is relative to the player's level. Serving one taken
  # twenty levels ago is precisely the mistake the Strategy section is trying to
  # avoid, so a stale reading is labelled rather than quoted.
  def test_a_stale_threat_is_flagged_not_quoted
    out = S.render(room: room, here: [{ desc: "A minotaur.", count: 1, kind: "mob",
                                        threat: "Death!", threat_fresh: false }])

    assert_includes out, "threat unknown at this level"
    refute_includes out, "Death!"
  end

  def test_a_lost_fight_is_recalled_with_the_level_it_was_lost_at
    out = S.render(room: room, here: [{ desc: "A minotaur.", count: 1, kind: "mob",
                                        encounters: "you died against this at level 3" }])

    assert_includes out, "you died against this at level 3"
  end

  def test_duplicate_entities_are_counted_not_repeated
    out = S.render(room: room, here: [{ desc: "A beastly fido.", count: 3, kind: "mob" }])
    assert_includes out, "A beastly fido. ×3"
  end

  # Events are true for one instant. They ride in the block for exactly the
  # iteration they happened in, and are never written to a table the agent later
  # reads as fact.
  def test_events_appear_only_when_there_are_any
    refute_includes S.render(room: room, events: []).to_s, "just now"
    assert_includes S.render(room: room, events: ["The Mayor has arrived."]), "just now: The Mayor has arrived."
  end

  def test_missing_player_fields_are_simply_absent
    assert_equal "you: 20hp · standing", S.render(room: room, player: { hp: 20, position: "standing" }).lines.last.strip
  end

  def test_look_candidates_are_offered_only_while_the_room_is_unexamined
    assert_includes S.render(room: room, first_visit: true, candidates: %w[statue fountain]),
                    "worth a look: statue, fountain"
    refute_includes S.render(room: room, candidates: nil).to_s, "worth a look"
  end

  # The `d` failure, at the producer. The block used to abbreviate to match the
  # MUD's own `[ Exits: n e s w ]` line; the model read it as a menu and passed
  # `direction: "d"` to a tool whose schema accepts only the long spellings,
  # losing an iteration to `invalid direction: "d"`. One grammar, both sides.
  def test_exit_directions_are_spelled_the_way_move_accepts_them
    full_names = Boukensha::Mud::RoomParser::DIRECTIONS.values
    exits = full_names.map { |d| { direction: d, target_name: "Somewhere", target_room_id: nil } }
    printed = S.render(room: room, exits: exits).lines[1].sub("exits: ", "")
                .split(" | ").map { |part| part.split("→").first }

    assert_equal full_names, printed
    assert_equal full_names, S::DIRECTIONS
  end

  # tbaMUD's `move` enum (mud_manager's Primitives::DIRECTIONS) is the six the
  # stock engine has. Nothing the block prints for them may fall outside it.
  MOVE_ENUM = %w[north east south west up down].freeze

  def test_the_six_engine_directions_render_inside_the_move_enum
    exits = MOVE_ENUM.map { |d| { direction: d, target_name: nil, target_room_id: nil } }
    printed = S.render(room: room, exits: exits).lines[1].sub("exits: ", "")
                .split(" | ").map { |part| part.split(/[ →]/).first }

    assert_equal MOVE_ENUM, printed
  end
end
