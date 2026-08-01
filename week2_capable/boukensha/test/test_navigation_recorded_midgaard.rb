require_relative "helper"
require "json"

# The deterministic gate for fix_surveying.md §5.
#
# Every other navigation test is a hand-built two- or three-room map, which is
# why every one of them passed while run 20260731T140528Z-34c846bf spent fifteen
# of its twenty-one model calls producing no coverage. This file is that run's
# actual map — seventeen rooms, fifty-three exits, eighteen entity sightings,
# read out of the `knowledge.sqlite3` the session wrote and committed as a
# fixture — so the questions the agent actually asked can be asked again without
# a MUD, a model or a key.
#
# The three assertions here are the ones the plan gates on, and each one is a
# measured fact from replaying the shipped code against this map rather than an
# expectation of how it ought to behave.
class TestNavigationRecordedMidgaard < Minitest::Test
  R = Boukensha::Mud::Navigation::RoutePlanner
  E = Boukensha::Mud::Memory::ExitResolution

  MAP = JSON.parse(
    File.read(File.expand_path("fixtures/midgaard_run_20260731T140528Z.json", __dir__)),
    symbolize_names: true
  ).freeze

  CONCOURSE = 17 # where the run ended, and where it asked nine times for the South Gate

  def rooms = MAP[:rooms]
  def exits = MAP[:exits]

  def entities_by_room
    MAP[:entities].group_by { |e| e[:room_id] }
                  .transform_values { |es| es.map { |e| e.slice(:descr, :keyword, :kind) } }
  end

  def plan(query, from: CONCOURSE, exits: self.exits)
    R.plan(query: query, current_room_id: from, rooms: rooms, exits: exits,
           entities_by_room: entities_by_room)
  end

  # ---------- the map is the one the run wrote ---------------------------

  def test_the_fixture_is_the_recorded_map
    assert_equal 17, rooms.size
    assert_equal "On The Concourse", rooms.find { |r| r[:id] == CONCOURSE }[:name]

    # The row the whole diagnosis turns on: the place the agent kept asking for,
    # printed on its own west exit, unwalked.
    south_gate = exits.find { |e| e[:room_id] == CONCOURSE && e[:direction] == "west" }
    assert_equal "The South Gate", south_gate[:target_name]
    assert_nil south_gate[:target_room_id]
    assert_nil south_gate[:presumed_target_id]
  end

  # ---------- gate 1: the destination resolves to the right place --------

  # The recorded answer was `unreachable`, aimed at Inside The West Gate Of
  # Midgaard (#11) — a different gate on the opposite side of the city, matched
  # on the shared word "gate". Nine identical refusals followed.
  def test_the_south_gate_is_the_exit_one_move_west
    p = plan("The South Gate")

    assert_equal "explore", p.status
    assert_equal({ room_id: CONCOURSE, direction: "west" }, p.frontier)
    assert_match(/The South Gate/, p.evidence)
  end

  # Nothing in the map identifies the South Gate as a room, because the agent had
  # never stood in it. That is the whole point of the frontier answer.
  def test_no_room_claims_to_be_the_south_gate
    hits = Boukensha::Mud::Navigation::DestinationSearch.search(
      "The South Gate", rooms: rooms, entities_by_room: entities_by_room
    )
    decisive = hits.select { |h| h[:tier] <= Boukensha::Mud::Navigation::DestinationSearch::TIER_ENTITY }

    assert_empty decisive, "a room matching decisively is what buried the exit named exactly this"
  end

  # ---------- gate 2: a direction is not a substring ---------------------

  # `call_71277bc55909` asked to move west and was answered `known`, one step
  # NORTH, because "west" is a substring of "The Northwest End Of The Concourse"
  # (#16) and #16 was one hop away. The next call walked back south.
  def test_asking_for_west_does_not_route_north_into_the_northwest_concourse
    p = plan("west")

    refute_equal 16, p.destination_room
    refute_equal "north", p.steps.first && p.steps.first[:direction]
  end

  # ---------- gate 2b: a refusal names somewhere to go -------------------

  # "Wall Road" names three rooms the agent has stood in and none of them is
  # reachable from the concourse, so this answer is `unreachable` even with the
  # resolver corrected — which makes it the case §3.3 is about. The four doors it
  # carries are the four the recorded run computed and discarded, one of them the
  # destination the agent went on to ask for nine times.
  def test_an_unreachable_answer_carries_the_doors_the_planner_already_computed
    p = plan("Wall Road")

    assert_equal "unreachable", p.status
    assert_equal 4, p.unexplored_total
    assert_equal [0, 1, 2], p.unexplored.map { |g| g[:distance] }
    assert_includes p.unexplored.flat_map { |g| g[:exits].map { |e| e[:target_name] } }, "The South Gate"
  end

  # ---------- gate 3: the map stays routable behind the agent ------------

  # Every presumption recomputed from the fixture by the current resolver, which
  # is what makes the two assertions below a gate on `ExitResolution` rather than
  # a re-reading of the column the run happened to write.
  def resolved_exits
    resolution = E.resolve(rooms: rooms, exits: exits, ambiguous: MAP[:ambiguous_exit_names])
    exits.map do |e|
      next e if e[:target_room_id]

      e.merge(presumed_target_id: resolution[[e[:room_id], e[:direction]]])
    end
  end

  def test_the_arrival_edge_links_the_five_exits_the_name_could_not
    added = resolved_exits.zip(exits).filter_map do |now, before|
      next if now[:presumed_target_id] == before[:presumed_target_id]

      [now[:room_id], now[:direction], now[:presumed_target_id]]
    end

    assert_equal [[10, "east", 9], [11, "east", 10], [13, "north", 12],
                  [14, "north", 13], [15, "north", 14]], added
  end

  def test_reachability_from_the_concourse_covers_the_whole_map
    reached = R.distances(exits: resolved_exits, from: CONCOURSE)

    assert_equal (1..17).to_a, reached.keys.sort
    assert_equal 11, reached[1], "The Temple is eleven hops back up the western wall"
  end

  # ---------- the recorded reachability, which step 3 repairs ------------

  # BFS from the concourse reaches three rooms out of seventeen: the walk down
  # the western wall earned one directed edge per move and every northward
  # return edge was refused by the name guards, because three rooms are called
  # "Wall Road". Every destination behind the agent was `unreachable` on the map
  # as recorded, whatever the resolver named.
  def test_the_recorded_map_is_a_one_way_street
    reached = R.distances(exits: exits, from: CONCOURSE)

    assert_equal [15, 16, 17], reached.keys.sort
  end
end
