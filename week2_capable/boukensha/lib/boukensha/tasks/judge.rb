require_relative "base"

module Boukensha
  module Tasks
    # Tier 2 of the test harness: reads a trace digest of one case and answers
    # whether the agent did what the scenario's rubric asked for.
    #
    # Configured under `tasks.judge` in settings.yaml exactly like every other
    # task, so swapping the judge's provider or model is config-only — which
    # matters, because §11's open question ("a judge weaker than the player is
    # not credible; a judge as strong as the player is most of the run's cost")
    # is settled by measurement, not by an edit here.
    class Judge < Base
      def self.task_name = "judge"

      class << self
        private

        # `Base.read_default_prompt` reads `<prompts>/<name>.md`, which is the
        # PLAYER's system prompt — correct when the player was the only task
        # with a bundled prompt, and quietly wrong the moment a second one
        # exists. A judge that silently inherited the player's prompt would
        # answer as a MUD adventurer, so this scopes the lookup by task name.
        def read_default_prompt(prompt_name, default_prompts_dir: nil)
          return nil unless default_prompts_dir

          read_file(File.join(default_prompts_dir, task_name, "#{prompt_name}.md"))
        end
      end
    end
  end
end
