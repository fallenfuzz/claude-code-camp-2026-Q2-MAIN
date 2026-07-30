require_relative "base"
require_relative "scoped_prompt"

module Boukensha
  module Tasks
    # What should this survey be trying to establish? — docs/plans/week_3/
    # movement_revisited/surveyor_architecture.md.
    #
    # It owns a ledger of falsifiable claims about the region and nothing else.
    # On each invocation it reads the evidence gathered since it last ran and
    # decides which claims to open, revise, park or retire. It does not extract
    # rooms, calculate routes, execute movement, mutate region boundaries, or —
    # and this is the difference that matters most — select a frontier.
    #
    # The superseded design had it return a `frontier_id` on every leg, which put
    # a reasoner in the movement path. Three things went wrong with that. The
    # reason string carried the actual strategy and was discarded at the end of
    # the call, so nothing accumulated across legs and nothing at all survived
    # the call boundary. Completion depended on a `min_rooms` floor with no
    # principled value, since neither ten nor thirty rooms says anything about
    # whether the player's question was answered. And a mid-survey failure
    # removed the only component able to choose a direction. Because every claim
    # carries a predicate from a closed vocabulary and each predicate defines a
    # deterministic scoring function, the movement decision that follows a call
    # here is arithmetic over the ledger instead.
    #
    # The separability test is the same one the navigator passes: does the
    # sub-decision need the player's goals and history, or only its own subject
    # matter? Deciding that a repeated exit name means a road passes through
    # rather than terminates needs the ledger and the rooms just walked. It does
    # not need the preceding conversation. So it runs in its own `Context`, on
    # its own small payload, and its spend lands nowhere near the player's turn
    # budget.
    class Surveyor < Base
      include ScopedPrompt

      def self.task_name = "surveyor"
    end
  end
end
