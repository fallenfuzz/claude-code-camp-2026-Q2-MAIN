require_relative "helper"
require "boukensha/testing/state_loader"

# The extraction from `bin/seed_player` has to be provably behaviour-preserving,
# so the central assertion here is that StateLoader builds the SAME config hash
# the script used to assemble from its frozen constants.
class TestTestingStateLoader < Minitest::Test
  SL = Boukensha::Testing::StateLoader

  # Verbatim from the constants `bin/seed_player` carried before this existed.
  LEGACY_UPLIFT = {
    level: 10,
    money: { gold: 5_000, bank: 1_000 },
    stats: { align: 0 },
    skills: { "armor" => 75, "cure light" => 75 },
    inventory: [{ vnum: 3001, keyword: "bottle", quantity: 2 }],
    equipment: [
      { vnum: 3023, keyword: "club", quantity: 1, wear: "wield" },
      { vnum: 3043, keyword: "jacket", quantity: 1, wear: "wear" }
    ]
  }.freeze

  def setup
    @env = ENV.to_h.slice("MUD_PASSWORD_ADMIN", "MUD_PASSWORD_DERRANO")
    ENV["MUD_PASSWORD_ADMIN"]   = "admin-secret"
    ENV["MUD_PASSWORD_DERRANO"] = "player-secret"
  end

  def teardown
    %w[MUD_PASSWORD_ADMIN MUD_PASSWORD_DERRANO].each { |k| ENV.delete(k) }
    @env.each { |k, v| ENV[k] = v }
  end

  def test_builds_the_config_hash_bin_seed_player_used_to_build_from_constants
    config = loader.config_hash

    assert_equal "localhost", config[:host]
    assert_equal 4000, config[:port]
    assert_equal "admin", config[:admin_name]
    assert_equal "admin-secret", config[:admin_password]
    assert_equal "Derrano", config[:player_name]
    assert_equal "player-secret", config[:player_password]
    assert_equal "M", config[:gender]
    assert_equal "C", config[:player_class], "profile.yaml spells the class out; tbaMUD wants a letter"

    # The uplift is the legacy one plus `location`, which is the only thing §3.2
    # added.
    assert_equal LEGACY_UPLIFT, config[:uplift].reject { |k, _| k == :location }
  end

  def test_host_and_port_come_from_the_mud_mcp_server_block
    config = loader(mud: { "MUD_HOST" => "mud.example", "MUD_PORT" => "4444" }).config_hash

    assert_equal "mud.example", config[:host]
    assert_equal 4444, config[:port], "a string from YAML must not reach the seeder as a string"
  end

  def test_location_is_carried_through_as_an_integer
    assert_equal 3001, loader.config_hash[:uplift][:location]
  end

  def test_a_state_with_no_location_omits_it_rather_than_sending_nil
    config = loader(state: legacy_state.reject { |k, _| k == "location" }).config_hash

    refute config[:uplift].key?(:location)
  end

  # The seeder type-checks every one of these, and a YAML scalar that looks like
  # a number is exactly the failure this conversion exists to prevent.
  def test_yaml_strings_are_coerced_to_the_integers_the_seeder_validates
    state = legacy_state.merge("level" => "10", "money" => { "gold" => "5000" })

    uplift = loader(state: state).config_hash[:uplift]

    assert_equal 10, uplift[:level]
    assert_equal 5000, uplift[:money][:gold]
  end

  def test_skill_names_stay_verbatim_because_the_mud_spelling_is_the_contract
    assert_equal 75, loader.config_hash[:uplift][:skills]["cure light"]
  end

  def test_a_missing_password_names_the_variable_it_wanted
    ENV.delete("MUD_PASSWORD_DERRANO")

    error = assert_raises(SL::Error) { loader }

    assert_match(/MUD_PASSWORD_DERRANO/, error.message)
  end

  def test_an_unknown_class_lists_the_ones_that_exist
    error = assert_raises(SL::Error) { loader(profile: cleric_profile.merge("class" => "bard")) }

    assert_match(/bard/, error.message)
    assert_match(/cleric/, error.message)
  end

  def test_an_item_missing_a_keyword_says_which_item
    state = legacy_state.merge("inventory" => [{ "vnum" => 3001, "quantity" => 1 }])

    error = assert_raises(SL::Error) { loader(state: state) }

    assert_match(/keyword/, error.message)
  end

  # apply! delegates to CharacterSeeder and nothing else — injected here so the
  # seam is asserted without a MUD.
  def test_apply_hands_the_config_to_the_seeder_and_returns_it
    seen = nil
    fake = Class.new do
      define_method(:initialize) { |config, output: nil| seen = config }
      define_method(:run) { self }
    end

    result = loader(seeder_class: fake).apply!

    assert_equal "Derrano", seen[:player_name]
    assert_instance_of fake, result
  end

  private

  def loader(state: legacy_state, profile: nil, mud: {}, seeder_class: nil)
    SL.new(state: state, profile: profile || cleric_profile, mud: mud,
           output: StringIO.new, seeder_class: seeder_class)
  end

  def cleric_profile
    { "name" => "Derrano", "password_env" => "MUD_PASSWORD_DERRANO", "gender" => "m", "class" => "cleric" }
  end

  # The same state the constants encoded, as YAML would deliver it.
  def legacy_state
    {
      "location" => 3001,
      "level" => 10,
      "money" => { "gold" => 5000, "bank" => 1000 },
      "stats" => { "align" => 0 },
      "skills" => { "armor" => 75, "cure light" => 75 },
      "inventory" => [{ "vnum" => 3001, "keyword" => "bottle", "quantity" => 2 }],
      "equipment" => [
        { "vnum" => 3023, "keyword" => "club", "quantity" => 1, "wear" => "wield" },
        { "vnum" => 3043, "keyword" => "jacket", "quantity" => 1, "wear" => "wear" }
      ]
    }
  end
end
