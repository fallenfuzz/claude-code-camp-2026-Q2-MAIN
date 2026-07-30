require_relative "helper"

# `Launch.settings_digest` — settings_sweep.md §4, the sharp edge of the whole
# feature.
#
# The field's own job is to let a report refuse to aggregate two configurations
# into one number. An override is applied in MEMORY and does not change
# `settings.yaml`, so a digest over the file's bytes would give every arm of a
# sweep the same value: the field that exists to stop two configurations being
# compared as one would be actively asserting that six of them were the same one,
# which is worse than the field not existing, because a reader who has learned to
# trust it would be misled by it.
class TestSettingsDigest < Minitest::Test
  include McpTestHelper

  SETTINGS = <<~YAML.freeze
    memory:
      turn_policy: false
    tools:
      navigation:
        limits:
          max_rooms: 12
          max_decisions: 6
    tasks:
      navigator:
        provider: anthropic
        model: claude-haiku-4-5
  YAML

  def test_two_arms_with_different_overrides_digest_differently
    config_from(SETTINGS) do |config|
      four = digest(config, "tools" => { "navigation" => { "limits" => { "max_decisions" => 4 } } })
      ten  = digest(config, "tools" => { "navigation" => { "limits" => { "max_decisions" => 10 } } })

      refute_equal four, ten
      refute_equal four, digest(config, nil), "and neither is the unoverridden configuration"
    end
  end

  def test_the_same_overrides_digest_identically
    config_from(SETTINGS) do |config|
      overrides = { "tasks" => { "navigator" => { "model" => "claude-sonnet-4-6" } } }

      assert_equal digest(config, overrides), digest(config, Boukensha::Testing::Overrides.normalize(overrides))
    end
  end

  # An override that restates a value the file already holds IS the file's
  # configuration, and a digest claiming otherwise would split one arm in two.
  def test_an_override_that_changes_nothing_digests_as_the_file_does
    config_from(SETTINGS) do |config|
      assert_equal digest(config, nil),
                   digest(config, "tools" => { "navigation" => { "limits" => { "max_decisions" => 6 } } })
    end
  end

  # Hashing the parse rather than the bytes is strictly more honest in the
  # ordinary case too: a comment edit changed the digest and changed nothing
  # about the run.
  def test_the_digest_is_stable_across_a_comment_only_edit
    commented = "# swept against the batch harness, see move_to.md §9 step 8\n#{SETTINGS}\n\n"

    plain = config_from(SETTINGS) { |config| digest(config, nil) }
    noted = config_from(commented) { |config| digest(config, nil) }

    assert_equal plain, noted
  end

  def test_a_changed_value_still_changes_the_digest
    changed = SETTINGS.sub("max_decisions: 6", "max_decisions: 10")

    refute_equal config_from(SETTINGS) { |config| digest(config, nil) },
                 config_from(changed) { |config| digest(config, nil) }
  end

  # A string and the integer that prints the same are different configurations,
  # so the canonical rendering has to keep them apart.
  def test_a_scalars_type_is_part_of_the_digest
    config_from(SETTINGS) do |config|
      assert_equal "{a=1}", Boukensha::Launch.canonical("a" => 1)
      assert_equal "{a=\"1\"}", Boukensha::Launch.canonical("a" => "1")
    end
  end

  # Mapping order is a property of the file, not of the configuration.
  def test_key_order_does_not_change_the_digest
    reordered = <<~YAML
      tasks:
        navigator:
          model: claude-haiku-4-5
          provider: anthropic
      tools:
        navigation:
          limits:
            max_decisions: 6
            max_rooms: 12
      memory:
        turn_policy: false
    YAML

    assert_equal config_from(SETTINGS) { |config| digest(config, nil) },
                 config_from(reordered) { |config| digest(config, nil) }
  end

  private

  def digest(config, overrides) = Boukensha::Launch.settings_digest(config, overrides: overrides)
end
