require_relative "helper"

class TestAdminPrimitives < Minitest::Test
  def test_advance
    command = MudManager::Primitives.advance("Andrew", 10)
    assert_equal "advance Andrew 10", command.raw
    assert_equal({ name: "Andrew", level: 10 }, command.args)
  end

  def test_set_field
    assert_equal "set Andrew gold 5000",
                 MudManager::Primitives.set_field("Andrew", "gold", 5000).raw
  end

  def test_skillset_quotes_multiword_skill
    assert_equal "skillset Andrew 'second attack' 75",
                 MudManager::Primitives.skillset("Andrew", "second attack", 75).raw
  end

  def test_load_obj
    assert_equal "load obj 3020", MudManager::Primitives.load_obj(3020).raw
  end

  def test_rejects_command_injection_and_bad_ranges
    assert_raises(ArgumentError) { MudManager::Primitives.advance("Andrew\nshutdown", 10) }
    assert_raises(ArgumentError) { MudManager::Primitives.advance("Andrew", 0) }
    assert_raises(ArgumentError) { MudManager::Primitives.set_field("Andrew", "gold all", 1) }
    assert_raises(ArgumentError) { MudManager::Primitives.skillset("Andrew", "thief's trick", 50) }
    assert_raises(ArgumentError) { MudManager::Primitives.skillset("Andrew", "kick", 101) }
    assert_raises(ArgumentError) { MudManager::Primitives.load_obj("3020") }
  end
end
