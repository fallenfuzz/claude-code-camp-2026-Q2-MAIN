require_relative "helper"

# Navigation::PlanRouteTool — the native tool surface over a real Store.
# Zero MUD I/O: the store is the only thing this tool touches.
class TestPlanRouteTool < Minitest::Test
  M = Boukensha::Mud::Memory
  T = Boukensha::Mud::Navigation::PlanRouteTool

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
  end

  def make_room(name)
    desc = "desc of #{name}"
    weak = M::Fingerprint.weak(name: name, description: desc, exit_dirs: %w[north])
    @store.create_room(name: name, description: desc, weak_fingerprint: weak)
  end

  def test_position_unknown_before_any_room_is_established
    result = T.call(store: @store, destination: "bakery")
    assert_match(/position unknown/, result)
  end

  def test_blank_destination_is_rejected
    result = T.call(store: @store, destination: "   ")
    assert_match(/error: destination is required/, result)
  end

  def test_known_route_renders_path_and_room_chain
    a = make_room("Market Square")
    b = make_room("Grubby's Bakery")
    @store.link_exit!(a, "east", b)
    @store.update_player!(current_room_id: a)

    result = T.call(store: @store, destination: "bakery")
    assert_match(/\[route\] bakery — known/, result)
    assert_match(/to: Grubby's Bakery \(##{b}\)/, result)
    assert_match(/path: east/, result)
    assert_match(/1 move: Market Square → Grubby's Bakery/, result)
  end

  def test_arrived_when_current_room_is_the_destination
    a = make_room("Grubby's Bakery")
    @store.update_player!(current_room_id: a)

    result = T.call(store: @store, destination: "bakery")
    assert_match(/\[route\] bakery — arrived/, result)
  end

  # plan_route.md §3: "plan_route performs zero MCP calls." Its signature
  # takes a store and a destination string — nothing that could dispatch a
  # tool — so there is no seam through which it could reach the MUD.
  def test_signature_has_no_mud_dispatch_seam
    assert_equal %i[store destination], T.method(:call).parameters.map { |(_, name)| name }
  end
end
