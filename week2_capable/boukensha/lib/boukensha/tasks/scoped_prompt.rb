module Boukensha
  module Tasks
    # `Base.read_default_prompt` reads `<prompts>/<name>.md`, which is the
    # PLAYER's system prompt. That was correct while the player was the only
    # task with a bundled prompt, and quietly wrong the moment a second one
    # existed: a task that silently inherited the player's prompt would answer
    # as a MUD adventurer rather than as itself.
    #
    # Every task except the player scopes the lookup by task name. This is that
    # one override, extracted so the third and fourth task to need it do not
    # each carry their own copy of it — the judge found the bug, and a fix that
    # has to be remembered per task is a fix that will be forgotten.
    module ScopedPrompt
      def self.included(base)
        base.singleton_class.class_eval do
          private

          def read_default_prompt(prompt_name, default_prompts_dir: nil)
            return nil unless default_prompts_dir

            read_file(File.join(default_prompts_dir, task_name, "#{prompt_name}.md"))
          end
        end
      end
    end
  end
end
