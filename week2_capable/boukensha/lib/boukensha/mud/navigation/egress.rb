require_relative "route_planner"

module Boukensha
  module Mud
    module Navigation
      # Does this exit leave the place being surveyed? See
      # docs/plans/week_3/movement_revisited/staying_in_town.md §9 and §10.1.
      #
      # It is a fourth question about an unwalked exit and not a fourth value of
      # an existing one, because the three already on record answer something
      # else and answer it correctly about a field outside a town. Run
      # 20260731T171650Z-09259cd5 is the argument: its surveyor wrote "open
      # countryside north of the temple, beyond the town boundary" and
      # "outside the Midgaard survey scope" into `note` six times, and then
      # answered `assessability: assessable` — which is true, it can see a field
      # and knows what a field is — and `hazard: none`, which is also true,
      # because a meadow is not dangerous. Both answers were right and neither
      # was the one that mattered, so the planner scored those five exits as the
      # most attractive on the map and the survey walked fifteen rooms of
      # countryside.
      #
      # As with `Assessment`, no value here is ever derived from the wording of a
      # MUD string. There is deliberately no rule that recognises a gate, a wall
      # or the word "outside": a hard-coded list of what a boundary looks like
      # would be wrong in the next zone and would put a semantic judgement in the
      # one layer this design keeps free of them. The judgement belongs to the
      # reasoner that can read a name; what code owes it is somewhere to put the
      # answer and an arithmetic that respects it.
      module Egress
        # The exit stays inside the place being surveyed.
        INTERIOR = "interior".freeze
        # The exit IS the edge — a gate, a bridgehead, a wall stair. It stays in
        # scope, because a claim about what bounds a place is settled by standing
        # on the bound, and because `Inside The East Gate Of Midgaard` is a town
        # room worth having.
        BOUNDARY = "boundary".freeze
        # The far side is somewhere else.
        LEAVES   = "leaves".freeze

        VALUES = [INTERIOR, BOUNDARY, LEAVES].freeze

        module_function

        # Silence reads as `interior`, which is what makes this opt-in: a cold
        # map carrying no hints at all produces exactly the frontier ordering and
        # exactly the walk it produced before this existed. That is the opposite
        # of `Assessment`'s default, and deliberately so — an unanswered
        # assessability defers a door, where an unanswered egress must not
        # silently fence the agent into the room it is standing in.
        def egress(value)
          v = value.to_s.strip.downcase
          VALUES.include?(v) ? v : INTERIOR
        end

        # The one question every consumer actually asks. `boundary` is not a
        # departure and neither is silence, so this is true for exactly one of
        # the four states.
        def leaves?(value) = egress(value) == LEAVES
      end

      # The backstop both objective modes share — staying_in_town.md §10.4.
      #
      # `MoveTo` and `Survey` each drive their own loop and each own their own
      # terminal statuses, so what is shared is the arithmetic and the write, not
      # the control flow. Three functions, and the reason they live together is
      # that a second copy of "which side of the wall is this room on" is the one
      # thing this whole change cannot afford: the measure in §13 and the guard in
      # §10.4 have to agree, or a run can fail a gate for a crossing the walker
      # did not think it made.
      #
      # It should almost never fire. The veto refuses the step before it is sent
      # and the claim planner never offers the frontier, and this exists for what
      # neither covers — a hint that was absent, a navigator that answered `false`
      # about a gate it misread, a room reached without an arrival edge. What
      # makes it able to fire at all is that a crossing recorded once stays
      # recorded: the first walk through a gate is not caught, because nothing had
      # yet said the gate was a gate, and every later walk through it is.
      module Guard
        module_function

        # The rooms on this call's side of the wall. No region label enters it —
        # §8 shows a region's parent records which region it was carved out of
        # rather than which place contains it, so an internal transition into a
        # quarter, the wall road, the temple or the far bank crosses a `split` and
        # is not a departure, while only a recorded `egress` cuts the graph.
        def scope_rooms(store, origin)
          RoutePlanner.reachable_within(exits: store.all_exits, from: origin,
                                        blocked: store.egress_edges)
        end

        # The first step of a leg that landed outside `inside`, walked forward
        # from the room the leg began in — so the edge reported is the one
        # actually crossed rather than wherever the leg happened to finish. That
        # distinction is §7's complaint about the judge answered in arithmetic: a
        # judge grading boundary-crossing from call arguments kept naming the
        # wrong call, because every crossing in the recorded run happened inside a
        # leg whose arguments look innocuous.
        def first_departure(completed, before_room, inside)
          from = before_room
          Array(completed).each do |step|
            to = step[:room_id]
            return { from: from, to: to, direction: step[:direction].to_s } if to && !inside.include?(to)

            from = to || from
          end
          nil
        end

        # `region_id` is the region being LEFT, and the row is deliberately not a
        # declaration about that region's extent: `Store#recompute_regions!` keeps
        # egress rows out of the derivation, because `Regions.derive` reads a
        # boundary's `to_room_id` as a root that starts a region there and the
        # field beyond the gate does not start the town.
        def declare!(store:, edge:, region:, reason:)
          return false unless region && edge

          store.declare_boundary!(from_room_id: edge[:from], to_room_id: edge[:to],
                                  direction: edge[:direction], region_id: region[:id],
                                  reason: reason, kind: Memory::Store::BOUNDARY_EGRESS)
          true
        end
      end
    end
  end
end
