require_relative "helper"
require "json"

# Mud::RoomParser: text in, struct out.
#
# Every test below is a string and an assertion. That is the whole point of the
# split — the parser used to be half of a tool that owned a MUD dispatcher, so
# testing "does it read the exits line" meant building a fake round-tripper
# first. It has no `call_tool:` to fake any more.
class TestRoomParser < Minitest::Test
  P = Boukensha::Mud::RoomParser

  TRANSCRIPTS = JSON.parse(
    File.read(File.expand_path("fixtures/mud_transcripts.json", __dir__))
  ).freeze

  def t(key) = TRANSCRIPTS.fetch(key)

  # --- look ------------------------------------------------------------------

  def test_parses_name_description_and_prompt_stats_from_real_look_output
    room = P.parse_look(t("look_temple"))

    assert_equal "The Temple Of Midgaard", room.name
    assert_includes room.description, "southern end of the temple hall"
    assert_includes room.description, "ancient wall paintings"
    # Prose is collapsed to one line and stops at the exits line.
    refute_includes room.description, "[ Exits:"
    refute_includes room.description, "teller machine"
    assert_equal [20, 100, 85], [room.hp, room.mana, room.move]
  end

  # The autoexit line is free on every look and every movement result, which is
  # what makes the weak fingerprint free.
  def test_parses_exit_directions_from_the_autoexit_line
    assert_equal %w[north east south west down], P.parse_look(t("look_temple")).exit_dirs
    assert_equal %w[north east south west], P.parse_look(t("look_common_square")).exit_dirs
  end

  def test_abbreviated_directions_are_expanded_to_the_long_form
    # Everything downstream — room_exits.direction, the fingerprint, the turn
    # policy — speaks the long form, so normalising here is what keeps
    # `check(exits)`'s "north" and the autoexit line's "n" the same key.
    assert_equal %w[north northeast southwest up], P.parse_exit_dirs("[ Exits: n ne sw u ]")
  end

  # tbaMUD paints objects green and mobs yellow (act.informative.c). The room
  # NAME is also yellow, but it is the first line, so position disambiguates.
  def test_splits_mobs_from_objects_by_colour_not_by_guessing
    room = P.parse_look(t("look_temple"))

    assert_empty room.mob_lines
    assert_equal ["An automatic teller machine has been installed in the wall here."],
                 room.object_lines.keys
    assert_equal 0, room.uncoloured
  end

  # The parser REPORTS that it could not tell; it does not warn and it does not
  # decide what to do about it. With world-level entities a mis-kinded row is
  # wrong in every room at once, so the count is what lets Store refuse the write.
  def test_uncoloured_entity_lines_are_counted_not_swallowed
    plain = t("look_common_square").gsub(/\e\[[0-9;]*m/, "")
    room  = P.parse_look(plain)

    assert_equal 3, room.uncoloured
    assert_empty room.object_lines, "with no colour there is no way to know an object from a mob"
  end

  # Three identical fidos are one appraisal, not three.
  def test_identical_entity_lines_are_deduped_with_a_count
    room = P.parse_look(t("look_common_square"))

    assert_equal 1, room.mob_lines.size
    assert_equal 3, room.mob_lines.values.first
  end

  # --- complete? — the whitelist §6.2 substitutes on ------------------------

  def test_a_real_room_is_complete
    assert P.parse_look(t("look_temple")).complete?
    assert P.parse_look(t("look_common_square")).complete?
  end

  # Anything the parser did not confidently recognise must reach the model
  # verbatim. A missed substitution costs ~100 tokens; a swallowed failure costs
  # an agent that retries a wall forever.
  def test_movement_refusals_are_never_complete
    [
      "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > ",
      "The door is closed.\r\n\r\n20H 100M 81V > ",
      "You are too exhausted.\r\n\r\n20H 100M 81V > ",
      "Some entirely novel refusal nobody has seen.\r\n\r\n20H 100M 81V > ",
      ""
    ].each do |text|
      refute P.parse_look(text).complete?, "should not treat #{text.inspect} as a room"
    end
  end

  # --- exits -----------------------------------------------------------------

  # The autoexit line gives directions only; destinations come from
  # check(exits), which is why a new room pays for a third round trip.
  def test_parses_exit_destinations
    exits = P.parse_exits(t("exits_temple"))

    assert_equal({ "north" => "By The Temple Altar",
                   "east" => "The Midgaard Donation Room",
                   "south" => "The Temple Square",
                   "west" => "The Reading Room",
                   "down" => "The Temple Square" }, exits)
  end

  # --- examine ---------------------------------------------------------------

  def test_parses_health_and_equipment_from_examine
    assert_equal "excellent condition", P.parse_examine(t("examine_fido"))[:health]

    guard = P.parse_examine(t("examine_cityguard"))
    assert_equal "excellent condition", guard[:health]
    assert_includes guard[:equipment].join(" "), "wielded"
  end

  # --- the prompt line -------------------------------------------------------

  def test_the_prompt_line_rides_on_every_response
    assert_equal({ hp: 20, mana: 100, move: 83 }, P.parse_prompt(t("poll_event")))
    assert_nil P.parse_prompt("no prompt here")
  end

  # The single most important reading the agent can be handed, and an anchored
  # /^\d+H/ drops exactly it: below zero tbaMUD prints "-6H", meaning mortally
  # wounded and dying.
  def test_negative_hp_is_read_not_dropped
    fight = "You're stunned, but will probably regain consciousness again.\r\n" \
            "0H 100M 84V > \r\nThe newbie monster pierces you.\r\n" \
            "You are mortally wounded, and will die soon, if not aided.\r\n-6H 100M 84V > "

    # …and the LAST prompt, not the first: only the final line is the state the
    # agent is actually in.
    assert_equal({ hp: -6, mana: 100, move: 84 }, P.parse_prompt(fight))
  end

  # --- score -----------------------------------------------------------------

  # Every field is matched independently: the prompt line already covers
  # hp/mana/move, so a MUD that words one line differently must not cost us the
  # level reading that `threat_level` depends on.
  def test_score_fields_are_read_independently
    score = <<~TEXT
      You are 17 years old.
      You have 20(24) hit, 100(100) mana and 82(82) movement points.
      You have scored 1250 exp, and have 43 gold coins.
      This ranks you as Dummy the Man (level 3).
    TEXT

    assert_equal({ level: 3, exp: 1250, gold: 43, max_hp: 24 }, P.parse_score(score))
    assert_empty P.parse_score("something else entirely")
  end

  # --- keyword guessing ------------------------------------------------------

  def test_guesses_the_target_keyword_from_the_noun_phrase
    assert_equal "fido", P.guess_keywords("A beastly fido is mucking through the garbage here.").first
    assert_equal "cityguard", P.guess_keywords("A cityguard stands here.").first
    # The right answer is `teller`; `machine` is tried first and the MUD is
    # asked to settle it (see the retry test in test_room_survey.rb).
    assert_equal %w[machine teller automatic],
                 P.guess_keywords("An automatic teller machine has been installed in the wall here.")
  end
end
