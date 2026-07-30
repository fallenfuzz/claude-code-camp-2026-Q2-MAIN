require_relative "helper"
require "boukensha/tasks/judge"
require "boukensha/tasks/surveyor"

# Default prompts are DATA the library reads at runtime, and a missing one fails
# silently: `read_file` returns nil, the task runs with no system prompt, and
# the model answers as something else entirely. That is exactly what happened —
# `PROMPTS_DIR` was one level too far up and resolved to a directory that has
# never existed, unnoticed because the only task then in existence overrode its
# prompt and never read the default.
class TestTaskPrompts < Minitest::Test
  PROMPTS = Boukensha::Config::PROMPTS_DIR

  def test_the_bundled_prompts_directory_actually_exists
    assert Dir.exist?(PROMPTS), "PROMPTS_DIR resolves to #{PROMPTS}, which does not exist"
    assert_equal "prompts", File.basename(PROMPTS)
  end

  def test_the_player_default_prompt_resolves
    prompt = Boukensha::Tasks::Player.system_prompt({}, default_prompts_dir: PROMPTS)

    refute_nil prompt, "the player has no bundled default system prompt"
    refute_empty prompt.strip
  end

  # The judge is the first task to rely on a bundled default rather than an
  # override, which is what surfaced the bug above.
  def test_the_judge_default_prompt_resolves_and_is_scoped_by_task_name
    prompt = Boukensha::Tasks::Judge.system_prompt({}, default_prompts_dir: PROMPTS)

    refute_nil prompt, "the judge has no bundled default system prompt"
    assert_match(/verdict/i, prompt)
    assert_match(/JSON/, prompt)
  end

  # The surveyor's prompt has to teach the closed predicate vocabulary, because
  # a claim classified under a predicate the planner does not know is rejected
  # before it reaches the ledger — a surveyor that had never been shown the list
  # would have its whole answer thrown away, silently.
  def test_the_surveyor_default_prompt_resolves_and_carries_the_predicate_vocabulary
    prompt = Boukensha::Tasks::Surveyor.system_prompt({}, default_prompts_dir: PROMPTS)

    refute_nil prompt, "the surveyor has no bundled default system prompt"
    Boukensha::Mud::Navigation::Predicates::NAMES.each do |predicate|
      assert_match(/#{predicate}/, prompt, "the surveyor is never told about `#{predicate}`")
    end
    assert_match(/decisive_when/, prompt)
  end

  # `Base.read_default_prompt` reads `<prompts>/<name>.md` — the PLAYER's file.
  # A judge that silently inherited it would answer as a MUD adventurer.
  def test_the_judge_does_not_fall_back_to_the_players_prompt
    refute_equal Boukensha::Tasks::Player.system_prompt({}, default_prompts_dir: PROMPTS),
                 Boukensha::Tasks::Judge.system_prompt({}, default_prompts_dir: PROMPTS)
  end

  # settings.yaml names a model; the backend is an allowlist with a price row
  # per entry, not a passthrough. A model it has never heard of fails at
  # construction — which is how `claude-sonnet-5` got as far as a live run.
  def test_the_configured_judge_model_is_one_the_backend_knows
    settings = Boukensha.config.tasks("judge")
    skip "no tasks.judge configured in this environment" if settings.nil? || settings.empty?
    skip "judge is not on the anthropic backend" unless settings["provider"].to_s == "anthropic"

    assert_includes Boukensha::Backends::Anthropic::MODELS.keys, settings["model"]
  end
end
