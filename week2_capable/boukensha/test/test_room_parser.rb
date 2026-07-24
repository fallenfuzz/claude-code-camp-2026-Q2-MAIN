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

    assert_equal({ level: 3, exp: 1250, gold: 43,
                   hp: 20, max_hp: 24, mana: 100, max_mana: 100, move: 82, max_move: 82,
                   age_years: 17, title: "Dummy the Man" },
                 P.parse_score(score))
    assert_empty P.parse_score("something else entirely")
  end

  # --- the player sheet, from real captures ----------------------------------
  #
  # Everything below is asserted against bytes this build actually emitted —
  # `bin/seed_player --emit-fixtures` writes them, and re-running it rewrites
  # them. Nothing here is authored from what a stock CircleMUD "should" print,
  # because that is precisely how the old /scored (\d+) exp/ came to silently
  # drop the one number on the line.

  def f(name) = File.read(File.expand_path("fixtures/player/#{name}.txt", __dir__))

  # The bug the expansion exists to fix: this build says "You have 450000 exp",
  # so the old /scored (\d+) exp/ matched nothing and the sheet's own exp never
  # landed in player_state at all.
  def test_score_reads_this_builds_exp_wording_not_circlemuds
    assert_equal 450_000, P.parse_score(f("score"))[:exp]
  end

  # "You need 225000 exp to reach your next level" is the line AFTER the exp
  # line. An unanchored /(\d+) exp/ reads it as the exp total.
  def test_exp_and_exp_to_next_are_not_confused_for_each_other
    score = P.parse_score(f("score"))

    assert_equal 450_000, score[:exp]
    assert_equal 225_000, score[:exp_to_next]
  end

  # The maxes for mana and move exist in `score` and NOWHERE else — the prompt
  # line carries the currents and throws the denominators away. Capturing them
  # is what lets anything downstream draw a bar instead of a bare number.
  def test_score_carries_the_maxes_the_prompt_line_does_not
    score = P.parse_score(f("score"))

    assert_equal [19, 88], [score[:hp], score[:max_hp]]
    assert_equal [100, 162], [score[:mana], score[:max_mana]]
    assert_equal [83, 94], [score[:move], score[:max_move]]
  end

  def test_score_reads_the_rest_of_the_sheet
    score = P.parse_score(f("score"))

    assert_equal 10, score[:level]
    assert_equal 5_000, score[:gold]
    # Verbatim: "94/10" is two numbers and deciding which is which is a guess.
    assert_equal "94/10", score[:armor_class]
    assert_equal 0, score[:alignment]
    assert_equal 17, score[:age_years]
    assert_equal "Derrano the Minister", score[:title]
    assert_equal "standing", score[:position]
  end

  # "You are 17 years old." is a "You are …" line too, and it comes FIRST.
  # Matching positions against a closed list is what keeps it from winning.
  def test_the_age_line_is_not_mistaken_for_the_position
    refute_equal "17 years old", P.parse_score(f("score"))[:position]
  end

  # Derrano is fed and watered, so this build printed no condition lines at all
  # — and an absent reading is nil, never an empty string that would render as
  # a condition the character does not have.
  def test_conditions_are_absent_when_the_mud_prints_none
    refute P.parse_score(f("score")).key?(:conditions)

    hungry = "You are standing.\r\nYou are hungry.\r\nYou are thirsty.\r\n"
    assert_equal "hungry,thirsty", P.parse_score(hungry)[:conditions]
  end

  # --- inventory -------------------------------------------------------------

  # "( 2) a bottle" — the space inside the parens is what this build really
  # prints, and /^\(\d+\)/ misses every stacked item because of it.
  def test_inventory_reads_padded_stack_counts
    assert_equal [{ descr: "a bottle", quantity: 2, keyword: "bottle" }],
                 P.parse_inventory(f("inventory"))
  end

  # An empty pack is "  Nothing." under the header in this build, not the
  # "You are not carrying anything." a stock CircleMUD prints. Either way it is
  # a valid EMPTY SNAPSHOT, which is a different thing from a failed read.
  def test_an_empty_pack_is_an_empty_snapshot_not_a_failure
    assert_equal [], P.parse_inventory(f("inventory_empty"))
    assert_equal [], P.parse_inventory("You are not carrying anything.\r\n19H 100M 83V > ")
  end

  # …and text that is not a listing at all is ALSO [], so the caller cannot
  # distinguish them here. That is why the hook checks for the header itself
  # before replacing the snapshot: a refusal must never wipe the bag.
  def test_unrecognised_text_never_raises
    assert_equal [], P.parse_inventory("Huh?!?")
    assert_equal [], P.parse_equipment("Huh?!?")
    assert_equal [], P.parse_skills("You can't practice here.")
    # `skills` is always present so no caller has to branch on the key; the
    # counter and the kind are compacted away because they were never read.
    assert_equal({ skills: [] }, P.parse_practice("Huh?!?"))
  end

  # --- equipment -------------------------------------------------------------

  def test_equipment_reads_the_slot_and_the_item
    assert_equal [{ worn_on: "worn on body", descr: "a leather jacket", keyword: "jacket" },
                  { worn_on: "wielded", descr: "a wooden club", keyword: "club" }],
                 P.parse_equipment(f("equipment"))
  end

  # A mob's `is using:` block prints the same shape, and the cityguard capture
  # has a slot with nothing after it. "This slot is filled" is itself a
  # reading, so it yields a row with a nil descr rather than no row.
  def test_a_slot_with_no_item_is_still_a_row
    assert_equal [{ worn_on: "wielded", descr: nil, keyword: nil }],
                 P.parse_equipment("You are using:\r\n<wielded>\r\n19H 100M 83V > ")
  end

  # --- skills ----------------------------------------------------------------

  # The plan assumed a percent. This build grades in WORDS, and inventing a
  # 0-100 ranking for "good" would be exactly the remembered-CircleMUD guess
  # the fixtures exist to prevent. Verbatim grade; the only derived field is
  # `learned`, which is the MUD's own "(not learned)".
  def test_proficiency_is_the_words_the_mud_printed_not_an_invented_percent
    skills = P.parse_skills(f("practice_guild"))

    assert_equal({ name: "armor", proficiency: "good", learned: true }, skills.first)
    assert_includes skills, { name: "bless", proficiency: "not learned", learned: false }
    assert_equal 2, skills.count { |s| s[:learned] }
  end

  # Single spaces are part of the name; the column gutter is two or more.
  def test_multi_word_skill_names_survive_the_column_split
    names = P.parse_skills(f("practice_guild")).map { |s| s[:name] }

    assert_includes names, "protection from evil"
    assert_includes names, "cure light"
  end

  # The sessions counter arrives in the same response as the listing and lives
  # nowhere else — `score` does not print it in this build.
  def test_practice_carries_the_sessions_counter_and_the_listing_kind
    practice = P.parse_practice(f("practice_guild"))

    assert_equal 30, practice[:practices_left]
    # "You know of the following spells:" — a cleric. A warrior says "skills".
    assert_equal "spell", practice[:kind]
    assert_equal 17, practice[:skills].length
  end

  # The plan carried a caveat that `practice` might only list at a guildmaster.
  # It does not in this build: the level-1 capture, taken in the newbie start
  # room, is a full listing. Both captures are asserted so a fork that DOES
  # gate it shows up here as a failure rather than as silent nils.
  def test_this_build_lists_skills_anywhere_not_only_at_a_guildmaster
    early = P.parse_practice(f("practice_refuse"))

    assert_equal 3, early[:practices_left]
    assert_equal %w[armor cure\ light], early[:skills].map { |s| s[:name] }
    refute early[:skills].any? { |s| s[:learned] }
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
