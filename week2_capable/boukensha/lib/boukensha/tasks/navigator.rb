require_relative "base"
require_relative "scoped_prompt"

module Boukensha
  module Tasks
    # One frontier decision, inside one `move_to` call — move_to.md §2.
    #
    # It is a task rather than something the player agent does for itself
    # because of the separability test in `tool_call_opitmize.md` §HN3: does the
    # sub-decision need the player's goals and history, or only its own subject
    # matter? Choosing which unexplored exit heads towards a bakery needs the
    # destination string and the candidate names. It does not need the preceding
    # eleven room descriptions or the instruction to say good morning. So it
    # runs in its own `Context`, on its own ~600-token payload, and its spend
    # lands nowhere near the player's turn budget.
    #
    # `max_iterations: 1` in settings.yaml is what keeps it a judgement rather
    # than a second agent: it has no tools and nothing to iterate on, exactly
    # like the judge.
    #
    # It answers with fields rather than calling tools, and §5.2 is the whole
    # argument for that. `name_region` and `split_region` have been on the
    # player's surface for a release and have never once been called; a hook or
    # a firmer prompt would be the same advisory nudge in a smaller context. A
    # field the answer must contain cannot be skipped the way a tool it may call
    # can be.
    class Navigator < Base
      include ScopedPrompt

      def self.task_name = "navigator"
    end
  end
end
