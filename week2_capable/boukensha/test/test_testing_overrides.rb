require_relative "helper"
require "boukensha/testing/overrides"

# The §2.4 merge. Every rule here is one a scenario author will hit, and every
# one of them is a way to lose a run silently if it goes the other way.
class TestTestingOverrides < Minitest::Test
  O = Boukensha::Testing::Overrides

  def test_mappings_deep_merge
    base     = { "money" => { "gold" => 5000, "bank" => 10_000 } }
    override = { "money" => { "gold" => 0 } }

    assert_equal({ "money" => { "gold" => 0, "bank" => 10_000 } }, O.deep_merge(base, override))
  end

  def test_sequences_replace
    base     = { "inventory" => [{ "vnum" => 1 }, { "vnum" => 2 }] }
    override = { "inventory" => [{ "vnum" => 9 }] }

    assert_equal([{ "vnum" => 9 }], O.deep_merge(base, override)["inventory"])
  end

  def test_plus_suffix_appends
    base     = { "inventory" => [{ "vnum" => 1 }] }
    override = { "inventory+" => [{ "vnum" => 2 }] }

    assert_equal([{ "vnum" => 1 }, { "vnum" => 2 }], O.deep_merge(base, override)["inventory"])
  end

  def test_append_onto_an_absent_base_is_just_the_addition
    assert_equal([{ "vnum" => 2 }], O.deep_merge({}, { "equipment+" => [{ "vnum" => 2 }] })["equipment"])
  end

  # `bank: ~` removes the field; `bank: 0` sets it to zero. Different claims.
  def test_explicit_null_deletes_a_key
    merged = O.deep_merge({ "money" => { "gold" => 5, "bank" => 10 } }, { "money" => { "bank" => nil } })

    assert_equal({ "gold" => 5 }, merged["money"])
    refute merged["money"].key?("bank")
  end

  def test_zero_is_not_a_deletion
    merged = O.deep_merge({ "money" => { "bank" => 10 } }, { "money" => { "bank" => 0 } })

    assert_equal 0, merged["money"]["bank"]
  end

  def test_absent_key_leaves_the_base_alone
    merged = O.deep_merge({ "level" => 10, "money" => { "gold" => 5 } }, { "level" => 12 })

    assert_equal 12, merged["level"]
    assert_equal({ "gold" => 5 }, merged["money"])
  end

  def test_precedence_across_all_four_layers
    resolved = O.resolve(
      { "money" => { "gold" => 5000, "bank" => 10_000 }, "level" => 10 },  # state file
      { "money" => { "gold" => 0 } },                                       # scenario
      { "level" => 12 },                                                    # plan case
      O.parse_set("money.gold=42")                                          # CLI
    )

    assert_equal 42, resolved["money"]["gold"]
    assert_equal 10_000, resolved["money"]["bank"]
    assert_equal 12, resolved["level"]
  end

  def test_symbol_keys_are_normalized_so_an_override_is_never_silently_dropped
    merged = O.deep_merge({ money: { gold: 1 } }, { "money" => { "gold" => 2 } })

    assert_equal({ "money" => { "gold" => 2 } }, merged)
  end

  def test_parse_set_builds_a_nested_hash_and_coerces_scalars
    assert_equal({ "money" => { "gold" => 0 } }, O.parse_set("money.gold=0"))
    assert_equal({ "level" => 10 }, O.parse_set("level=10"))
    assert_equal({ "flag" => true }, O.parse_set("flag=true"))
    assert_equal({ "name" => "cold map" }, O.parse_set("name=cold map"))
    assert_nil O.parse_set("bank=~")["bank"]
  end

  def test_parse_sets_merges_repeated_flags
    merged = O.parse_sets(["money.gold=1", "money.bank=2", "money.gold=3"])

    assert_equal({ "money" => { "gold" => 3, "bank" => 2 } }, merged)
  end

  def test_malformed_set_names_what_was_wrong
    error = assert_raises(O::Error) { O.parse_set("money.gold") }

    assert_match(/KEY=VALUE/, error.message)
  end
end
