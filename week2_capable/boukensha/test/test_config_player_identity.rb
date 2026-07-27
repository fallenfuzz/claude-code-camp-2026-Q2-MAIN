require_relative "helper"

class TestConfigPlayerIdentity < Minitest::Test
  def config_for(player_yaml)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "profile.yaml"), "player:\n#{player_yaml}")
      old_root = ENV["BOUKENSHA_DIR"]
      old_profile = ENV["BOUKENSHA_PROFILE_DIR"]
      ENV["BOUKENSHA_DIR"] = dir
      ENV["BOUKENSHA_PROFILE_DIR"] = dir
      yield Boukensha::Config.new, File.join(dir, "profile.yaml")
    ensure
      old_root.nil? ? ENV.delete("BOUKENSHA_DIR") : ENV["BOUKENSHA_DIR"] = old_root
      old_profile.nil? ? ENV.delete("BOUKENSHA_PROFILE_DIR") : ENV["BOUKENSHA_PROFILE_DIR"] = old_profile
    end
  end

  def config_error_for(player_yaml)
    error = nil
    path = nil
    config_for(player_yaml) { |_config, profile_path| path = profile_path }
  rescue ArgumentError => caught
    error = caught
    path ||= caught.message[/\A([^:]+profile\.yaml)/, 1]
    [error, path]
  end

  def test_every_allowed_identity_loads_with_unrelated_player_keys
    Boukensha::Config::PLAYER_GENDERS.product(Boukensha::Config::PLAYER_CLASSES).each do |gender, klass|
      config_for("  name: Hero\n  persona: cautious\n  gender: #{gender}\n  class: #{klass}\n") do |config|
        assert_equal({ gender: gender, player_class: klass }, config.player_identity)
        assert_equal "Hero", config.profile_dig(:player, :name)
      end
    end
  end

  def test_missing_invalid_case_typo_and_non_string_values_are_actionable
    [
      [ "  class: warrior\n", "player.gender", "nil", "m, f, n" ],
      [ "  gender: m\n", "player.class", "nil", "magic_user, cleric, thief, warrior" ],
      [ "  gender: M\n  class: warrior\n", "player.gender", "\"M\"", "m, f, n" ],
      [ "  gender: m\n  class: Warrior\n", "player.class", "\"Warrior\"", "magic_user" ],
      [ "  gender: m\n  class: warriro\n", "player.class", "\"warriro\"", "warrior" ],
      [ "  gender: 1\n  class: warrior\n", "player.gender", "1", "m, f, n" ]
    ].each do |yaml, field, received, allowed|
      error, path = config_error_for(yaml)
      refute_nil error
      assert_includes error.message, path
      assert_includes error.message, field
      assert_includes error.message, received
      assert_includes error.message, allowed
    end
  end

  def test_player_must_be_a_mapping
    error, path = config_error_for("  - warrior\n")
    assert_includes error.message, path
    assert_includes error.message, "player must be a mapping"
  end
end
