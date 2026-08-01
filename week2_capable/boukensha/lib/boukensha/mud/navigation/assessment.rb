module Boukensha
  module Mud
    module Navigation
      # What is known about the far side of an exit nobody has walked, as two
      # independent questions. See docs/plans/week_3/movement_revisited/
      # blind_step_recovery.md §5.1.
      #
      # They are two fields rather than one enumeration because a destination can
      # be perfectly legible and still dangerous, and collapsing them is what
      # would turn a rule meant to keep the agent out of wells into a rule that
      # keeps it out of half of Midgaard. "The Dark Alley" is ASSESSABLE and
      # HAZARD_SUSPECTED: the name is readable, it is genuinely a clue, and a
      # claim about a town's rougher quarters can be about it. `Too dark to tell.`
      # is UNASSESSABLE and says nothing about danger at all — entering it is a
      # bet rather than a choice, and the bet is not specifically about being
      # hurt.
      #
      # Neither value is ever derived from the wording of a MUD string. The
      # surveyor answers them, because it reads the room's prose and the exit
      # listing together and is the component whose job is semantic guessing;
      # `Store#note_opaque_exit!` writes UNASSESSABLE retrospectively, because a
      # walk that returned no information has established exactly what the
      # surveyor was being asked to predict.
      module Assessment
        ASSESSABLE   = "assessable".freeze
        UNASSESSABLE = "unassessable".freeze
        # Nobody has been asked, or the surveyor did not answer. Distinct from
        # UNASSESSABLE despite ranking with it: a finding is recorded once and not
        # asked again, whereas the absence of one is re-asked the next time a
        # surveyor sees the frontier.
        UNKNOWN      = "unknown".freeze

        ASSESSABILITY = [ASSESSABLE, UNASSESSABLE, UNKNOWN].freeze

        HAZARD_NONE      = "none".freeze
        HAZARD_SUSPECTED = "suspected".freeze
        HAZARD_KNOWN     = "known".freeze

        HAZARD = [HAZARD_NONE, HAZARD_SUSPECTED, HAZARD_KNOWN].freeze

        # Preference order for choosing WHICH frontier to walk, worst last. The
        # rankers take the best non-empty tier rather than mixing them, so an exit
        # whose destination cannot be assessed is never walked while one that can
        # be is still open — and a map on which nothing has been assessed defers
        # nothing, because every tier above the one holding everything is empty.
        #
        # Silence sits between the two findings deliberately. Defaulting it to
        # ASSESSABLE would be fail-open, and ranking it with UNASSESSABLE would
        # say the agent had looked and concluded something when it had not.
        TIERS = [ASSESSABLE, UNKNOWN, UNASSESSABLE].freeze

        module_function

        def assessability(value)
          v = value.to_s
          ASSESSABILITY.include?(v) ? v : UNKNOWN
        end

        def hazard(value)
          v = value.to_s
          HAZARD.include?(v) ? v : nil
        end

        def tier(value) = TIERS.index(assessability(value)) || TIERS.index(UNKNOWN)

        # Later is worse, so a `known` hazard loses a tie to a `suspected` one and
        # both lose to a clear road. It is only ever a tie-break: a warning the
        # model wrote should inform the model rather than bind it.
        def hazard_rank(value) = HAZARD.index(hazard(value).to_s) || 0
      end
    end
  end
end
