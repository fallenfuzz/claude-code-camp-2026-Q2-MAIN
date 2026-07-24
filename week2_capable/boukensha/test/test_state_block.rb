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
      exits: n→The Temple Square ✓ | e→Main Street ? | u ?
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

    assert_includes line, "n→The Temple Square ✓"
    assert_includes line, "e→Main Street ?"
    assert_includes line, "u ?", "a direction with no name yet is still a frontier"
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

  def test_long_directions_abbreviate_predictably
    assert_equal %w[n s e w u d ne nw se sw],
                 %w[north south east west up down northeast northwest southeast southwest].map { |d| S.short(d) }
  end
end
