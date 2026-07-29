require_relative "helper"

# Navigation::DestinationSearch — pure lexical ranking, plan_route.md §4.
class TestNavigationDestinationSearch < Minitest::Test
  D = Boukensha::Mud::Navigation::DestinationSearch

  def room(id, name:, description: "", look_candidates: nil)
    { id: id, name: name, description: description,
      look_candidates: look_candidates && look_candidates.to_json }
  end

  def test_exact_room_name_match
    rooms = [room(1, name: "Grubby's Bakery"), room(2, name: "Market Square")]
    hits = D.search("Grubby's Bakery", rooms: rooms)
    assert_equal 1, hits.first[:room_id]
    assert_equal D::TIER_EXACT_NAME, hits.first[:tier]
  end

  def test_case_insensitive_and_punctuation_insensitive
    rooms = [room(1, name: "Grubby's Bakery")]
    hits = D.search("grubbys bakery", rooms: rooms)
    assert_equal D::TIER_EXACT_NAME, hits.first[:tier]
  end

  def test_partial_name_match_is_a_phrase_hit
    rooms = [room(1, name: "The Reading Room"), room(2, name: "Market Square")]
    hits = D.search("reading", rooms: rooms)
    assert_equal 1, hits.first[:room_id]
    assert_equal D::TIER_NAME_PHRASE, hits.first[:tier]
  end

  def test_multi_token_query_matches_by_token_overlap_without_a_substring_hit
    rooms = [room(1, name: "The Reading Room"), room(2, name: "Market Square")]
    hits = D.search("reading nook", rooms: rooms)
    assert_equal 1, hits.first[:room_id]
    assert_equal D::TIER_NAME_TOKEN, hits.first[:tier]
  end

  # The regression that made `move_to` unusable. tbaMUD names most of its rooms
  # "The …", so token overlap on "the" alone matched whatever room the agent was
  # standing in — and `plan_route` answered `arrived` for "the bakery" in the
  # temple. Session 20260729T231114Z-c569ab91 spent all twelve of its iterations
  # on that.
  def test_a_function_word_alone_is_not_a_match
    rooms = [room(1, name: "The Temple Of Midgaard", description: "A large temple.")]

    assert_empty D.search("the bakery", rooms: rooms)
    assert_empty D.search("the", rooms: rooms)
    assert_empty D.search("a bakery", rooms: rooms)
  end

  # …and the content word still matches through the same path.
  def test_a_content_word_alongside_a_function_word_still_matches
    rooms = [room(1, name: "The Temple Of Midgaard"), room(2, name: "Market Square")]
    hits = D.search("the temple", rooms: rooms)

    assert_equal 1, hits.first[:room_id]
  end

  def test_match_through_description
    rooms = [room(1, name: "Side Street", description: "A quiet street near the bakery.")]
    hits = D.search("bakery", rooms: rooms)
    assert_equal 1, hits.first[:room_id]
    assert_equal D::TIER_DESCRIPTION, hits.first[:tier]
  end

  def test_match_through_look_candidate
    rooms = [room(1, name: "Side Street", look_candidates: ["a bread cart"])]
    hits = D.search("bread", rooms: rooms)
    assert_equal 1, hits.first[:room_id]
    assert_equal D::TIER_DESCRIPTION, hits.first[:tier]
  end

  def test_match_through_entity
    rooms = [room(1, name: "Market Square")]
    entities = { 1 => [{ descr: "a baker kneading dough", keyword: "baker", kind: "mob" }] }
    hits = D.search("baker", rooms: rooms, entities_by_room: entities)
    assert_equal 1, hits.first[:room_id]
    assert_equal D::TIER_ENTITY, hits.first[:tier]
  end

  def test_match_through_exit_target_name
    rooms = [room(1, name: "Main Street")]
    exits = { 1 => [{ target_name: "Grubby's Bakery", target_room_id: nil }] }
    hits = D.search("bakery", rooms: rooms, exits_by_room: exits)
    assert_equal 1, hits.first[:room_id]
    assert_equal D::TIER_EXIT_TARGET_NAME, hits.first[:tier]
  end

  def test_stale_entity_evidence_is_labelled_as_remembered_not_current
    # DestinationSearch only asserts a room MATCHED; it never claims presence.
    # Presence is StateBlock's `here:` line, sourced live — never sightings.
    rooms = [room(1, name: "Market Square")]
    entities = { 1 => [{ descr: "a cityguard", keyword: "guard", kind: "mob" }] }
    hit = D.search("guard", rooms: rooms, entities_by_room: entities).first
    assert_equal "a cityguard", hit[:evidence]
    refute hit.key?(:present), "search evidence must not assert current presence"
  end

  def test_deterministic_tie_ordering
    rooms = [room(3, name: "Main Street"), room(1, name: "Main Street"), room(2, name: "Main Street")]
    hits = D.search("Main Street", rooms: rooms)
    assert_equal [1, 2, 3], hits.map { |h| h[:room_id] }
  end

  def test_ambiguous_query_returns_multiple_alternatives
    rooms = [room(1, name: "Wall Road"), room(2, name: "Wall Road"), room(3, name: "Market Square")]
    hits = D.search("Wall Road", rooms: rooms)
    assert_equal [1, 2], hits.map { |h| h[:room_id] }
  end

  def test_no_query_match_returns_empty
    rooms = [room(1, name: "Market Square")]
    assert_empty D.search("dragon's lair", rooms: rooms)
  end

  def test_blank_query_matches_nothing
    rooms = [room(1, name: "Market Square")]
    assert_empty D.search("", rooms: rooms)
    assert_empty D.search("   ", rooms: rooms)
  end
end
