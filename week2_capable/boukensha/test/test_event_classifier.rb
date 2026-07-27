require_relative "helper"

# Mud::EventClassifier — the simple regex tiering execute_route uses to decide
# whether a poll result is worth aborting a batched route for. Every line
# below is verbatim from a real captured poll in move_around.md §5.
class TestEventClassifier < Minitest::Test
  E = Boukensha::Mud::EventClassifier

  def test_combat_lines_are_interrupting
    tier, line = E.classify("The creepy crawler misses a wild punch at you.\r\n20H 100M 81V > ")
    assert_equal :interrupting, tier
    assert_match(/creepy crawler/, line)
  end

  def test_the_players_own_hit_is_interrupting
    tier, = E.classify("You barely pierce the creepy crawler.\r\n20H 100M 81V > ")
    assert_equal :interrupting, tier
  end

  def test_death_is_interrupting
    tier, = E.classify("You have been KILLED!!\r\n\r\nYou are dead!  Sorry...\r\n")
    assert_equal :interrupting, tier
  end

  def test_victory_is_interrupting
    tier, = E.classify("The creepy crawler is dead! R.I.P.\r\n20H 100M 81V > ")
    assert_equal :interrupting, tier
  end

  def test_fleeing_is_interrupting
    tier, = E.classify("You flee head over heels!\r\n20H 100M 81V > ")
    assert_equal :interrupting, tier
  end

  def test_npc_chatter_is_informational
    tier, = E.classify("A kind soul says, 'get some clothes on! Here, I will help.'\r\n")
    assert_equal :informational, tier
  end

  def test_hunger_and_thirst_are_informational
    assert_equal :informational, E.classify("You are hungry.\r\n").first
    assert_equal :informational, E.classify("You are thirsty.\r\n").first
  end

  def test_nightfall_is_informational
    tier, = E.classify("The sun slowly disappears in the west.\r\n")
    assert_equal :informational, tier
  end

  def test_a_departure_is_notable_not_interrupting
    tier, line = E.classify("The cityguard leaves east.\r\n")
    assert_equal :notable, tier
    assert_match(/cityguard/, line)
  end

  def test_an_arrival_is_notable
    tier, = E.classify("A kobold has arrived from the east.\r\n")
    assert_equal :notable, tier
  end

  def test_blank_poll_is_none
    tier, line = E.classify("")
    assert_equal :none, tier
    assert_nil line
  end

  def test_the_prompt_line_alone_is_none
    tier, = E.classify("20H 100M 81V > ")
    assert_equal :none, tier
  end

  def test_most_severe_line_wins_even_when_it_is_not_first
    text = "You are hungry.\r\nThe creepy crawler misses a wild punch at you.\r\n20H 100M 81V > "
    tier, = E.classify(text)
    assert_equal :interrupting, tier
  end

  def test_interrupting_predicate
    assert E.interrupting?("You flee head over heels!\r\n")
    refute E.interrupting?("You are hungry.\r\n")
  end
end
