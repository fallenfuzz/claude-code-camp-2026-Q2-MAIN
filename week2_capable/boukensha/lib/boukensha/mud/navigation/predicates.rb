require "set"
require_relative "destination_search"

module Boukensha
  module Mud
    module Navigation
      # The closed predicate vocabulary — docs/plans/week_3/movement_revisited/claims.md.
      #
      # The surveyor may write any statement it likes, but it must classify that
      # statement under one of these, and a claim whose statement cannot be
      # expressed as a predicate over the room graph is rejected before it enters
      # the ledger. That rejection is the whole reason the vocabulary is closed:
      # it is what makes "the town is prosperous" fail at validation instead of
      # sitting in the ledger forever, unsettleable and unfalsifiable.
      #
      # Each predicate defines two functions and they are deliberately the same
      # two for all nine:
      #
      #   settle(claim, graph) -> [status, reason] or nil
      #       Has the decisive condition fired? Evaluated against the graph, so
      #       it is a computation and never a judgement call.
      #
      #   score(claim, frontier, graph) -> 0.0..1.0
      #       How much would walking this frontier serve this claim?
      #
      # Strategy is the second function, and nothing chooses it. A ledger holding
      # an open `circuit_closes` produces perimeter following because that is
      # what its scoring function prefers; a ledger holding an open `composition`
      # produces spread sampling for the same reason; and the behaviour changes
      # by itself as claims are settled and retired. This is what dissolves the
      # question strategies.md left open about who picks a strategy.
      module Predicates
        # `composition` needs a rule for when a survey has seen enough KINDS of
        # place, and this is it: rooms spent since the class list last grew.
        # claims.md flags the number as needing calibration against real
        # sessions, and setting it badly reproduces the arbitrariness of the
        # `min_rooms` floor this design exists to remove — so it is a limit in
        # settings.yaml, sweepable by the batch harness, and never a constant.
        DEFAULT_SATURATION_ROOMS = 6

        # Nine names, and a claim carrying anything else is rejected.
        NAMES = %w[composition exists count_at_least extent_bounded circuit_closes
                   bounds region_distinct connects spans].freeze

        module_function

        def known?(name) = NAMES.include?(name.to_s)

        # Has this claim's decisive condition fired? Returns [status, reason] or
        # nil. Called before scoring on every pass, so a claim never contributes
        # to a movement decision after the evidence that settles it has arrived.
        def settle(claim, graph, limits: {})
          name = claim[:predicate].to_s
          return nil unless known?(name)

          send(:"settle_#{name}", claim, graph, limits)
        end

        def score(claim, frontier, graph)
          name = claim[:predicate].to_s
          return 0.0 unless known?(name)

          send(:"score_#{name}", claim, frontier, graph).to_f.clamp(0.0, 1.0)
        end

        # ---------- composition ------------------------------------------------
        # "Midgaard's offerings span a describable set of classes."
        #
        # Class labels live in the claim's own `args` and not on rooms, which is
        # the point claims.md argues at length: the vocabulary arrives with the
        # objective, so a survey asking what a town offers seeds commercial,
        # civic and religious classes while one asking whether it is defensible
        # seeds walls, gates and chokepoints. A global room ontology would have
        # to be the union of every question anyone might ever ask.

        def settle_composition(claim, graph, limits)
          wanted   = Array(claim[:args]["classes"])
          observed = Array(claim[:args]["classes_observed"])
          outstanding = wanted - observed
          return ["confirmed", "every named class has a confirmed instance"] if wanted.any? && outstanding.empty?

          saturation = (limits["survey_saturation_rooms"] || DEFAULT_SATURATION_ROOMS).to_i
          since = claim[:rooms_spent].to_i - claim[:args].fetch("last_class_at_rooms", 0).to_i
          if observed.size >= 2 && since >= saturation
            return ["confirmed",
                    "no new class of place in #{since} rooms; observed #{observed.join(', ')}"]
          end

          nil
        end

        def score_composition(claim, frontier, graph)
          observed = Array(claim[:args]["classes_observed"])
          wanted   = Array(claim[:args]["classes"])
          expected = graph.hint(frontier)

          if expected
            return 1.0 if (wanted - observed).include?(expected)
            return 0.85 unless observed.include?(expected)

            # Already represented. This is the sentence the navigator had no way
            # to say — "we already know what an inn is" — expressed as
            # arithmetic over observed classes rather than as a judgement call.
            return 0.1
          end

          # No hint. Structure carries it, and carries it further than semantics
          # would: a frontier inside a single-entrance cluster is discounted
          # whatever it is called, which is the recorded run's six wasted moves
          # inside the Grunting Boar declined without reading a single name.
          0.5 * graph.cluster_discount(frontier[:room_id])
        end

        # ---------- exists / count_at_least -----------------------------------

        def settle_exists(claim, graph, _limits)
          klass = claim[:args]["class"].to_s
          observed = Array(claim[:args]["classes_observed"])
          return ["confirmed", "an instance of #{klass} was classified"] if observed.include?(klass)
          return ["refuted", "no #{klass} was found and no in-scope frontier remains"] if graph.frontiers.empty?

          nil
        end

        def score_exists(claim, frontier, graph)
          klass = claim[:args]["class"].to_s
          return 1.0 if graph.hint(frontier) == klass
          return 0.0 if graph.hint(frontier) # the surveyor expects something else here

          graph.lexical_clue?(frontier, klass) ? 0.7 : 0.15
        end

        def settle_count_at_least(claim, graph, _limits)
          klass = claim[:args]["class"].to_s
          n     = claim[:args].fetch("n", 1).to_i
          seen  = claim[:args].fetch("observed_count", 0).to_i
          return ["confirmed", "#{seen} distinct #{klass} observed (wanted #{n})"] if seen >= n
          return ["unresolved", "#{seen} of #{n} #{klass} found before frontiers ran out"] if graph.frontiers.empty?

          nil
        end

        # As `exists`, but it does not stop caring after the first instance —
        # which is the entire difference between the two predicates.
        def score_count_at_least(claim, frontier, graph) = score_exists(claim, frontier, graph)

        # ---------- extent_bounded --------------------------------------------
        # "Midgaard is a settlement of walkable, bounded extent."

        def settle_extent_bounded(claim, graph, _limits)
          ceiling = claim[:args]["ceiling"]&.to_i
          if ceiling && graph.room_count > ceiling
            return ["refuted", "#{graph.room_count} rooms in scope exceeds the stated ceiling of #{ceiling}"]
          end
          return ["confirmed", "every in-scope frontier has been drained"] if graph.frontiers.empty?

          nil
        end

        # Nearest-first, which drains the frontier set at the lowest walking
        # cost. Arbitration divides by walk cost as well, so the decay here is
        # gentle on purpose — squaring the preference would make this claim
        # incapable of ever pulling the survey more than one room.
        def score_extent_bounded(_claim, frontier, _graph)
          1.0 / (1 + frontier[:distance].to_i)
        end

        # ---------- circuit_closes ---------------------------------------------
        # "A road runs inside Midgaard's wall and forms a closed circuit."
        #
        # The claim that motivated the whole design, and the clearest case of a
        # predicate BEING a strategy: preferring the unexplored end of the
        # longest feature chain is perimeter following, and nothing had to
        # configure it.

        def settle_circuit_closes(claim, graph, _limits)
          slug = feature_slug(claim)
          return ["unresolved", "no rooms have been tagged into #{slug}"] if graph.feature(slug).empty? &&
                                                                            claim[:rooms_spent].to_i.positive?
          if graph.feature_cycle?(slug)
            return ["confirmed", "the #{slug} chain re-enters itself: #{graph.feature(slug).size} rooms"]
          end

          if graph.feature(slug).any? && frontiers_touching(graph, slug).empty?
            return ["refuted", "the #{slug} chain terminates with no unexplored continuation"]
          end

          nil
        end

        def score_circuit_closes(claim, frontier, graph)
          slug    = feature_slug(claim)
          members = graph.feature(slug)
          return 0.05 if members.empty?

          if members.include?(frontier[:room_id])
            # An END of the chain is where the circuit can still close; its
            # middle has already been walked through.
            graph.feature_chain_ends(slug).include?(frontier[:room_id]) ? 1.0 : 0.4
          elsif (graph.undirected[frontier[:room_id]] || Set.new).intersect?(members)
            0.3
          else
            0.05
          end
        end

        # ---------- connects ---------------------------------------------------
        # "Main Street is a through-road crossing Midgaard east to west."

        def settle_connects(claim, graph, _limits)
          slug    = feature_slug(claim)
          members = graph.feature(slug)
          return nil if members.empty?

          endpoints = Array(claim[:args]["endpoints"])
          if endpoints.size == 2 && endpoints.all? { |name| chain_reaches?(graph, members, name) }
            return ["confirmed", "the #{slug} chain reaches #{endpoints.join(' and ')}"]
          end

          if frontiers_touching(graph, slug).empty?
            return ["refuted", "the #{slug} chain terminates without reaching #{endpoints.join(' and ')}"]
          end

          nil
        end

        def score_connects(claim, frontier, graph) = score_circuit_closes(claim, frontier, graph)

        # ---------- bounds -----------------------------------------------------
        # "Everything outside the wall stops being town."

        def settle_bounds(claim, graph, _limits)
          slug = feature_slug(claim)
          return nil if graph.feature(slug).empty?
          return nil unless frontiers_touching(graph, slug).empty?

          ["unresolved", "every frontier on #{slug} has been walked; what lies beyond it was not classified"]
        end

        def score_bounds(claim, frontier, graph)
          graph.feature(feature_slug(claim)).include?(frontier[:room_id]) ? 1.0 : 0.1
        end

        # ---------- region_distinct --------------------------------------------
        # What used to be the navigator's `scope_suspect` side channel. As an
        # ordinary claim it accumulates evidence over several legs, competes for
        # frontier attention on priority like anything else, and can be REFUTED
        # rather than only ever escalating into a boundary nobody can revoke.

        def settle_region_distinct(claim, graph, _limits)
          subset = subset_rooms(claim, graph)
          return nil if subset.size < 2

          entrances = subset.sum do |id|
            (graph.undirected[id] || Set.new).count { |n| !subset.include?(n) }
          end
          if entrances == 1
            return ["confirmed", "#{subset.size} rooms hang off a single entrance"]
          end
          return nil unless frontiers_into(graph, subset).empty?

          ["refuted", "the #{subset.size} rooms are reachable by #{entrances} separate entrances"]
        end

        def score_region_distinct(claim, frontier, graph)
          subset = subset_rooms(claim, graph)
          return 0.1 if subset.empty?

          subset.include?(frontier[:room_id]) ? 1.0 : 0.05
        end

        # ---------- spans ------------------------------------------------------
        # "The town is on both banks of the river."
        #
        # The weakest of the nine, and honestly so: it needs sides, and sides are
        # what the graph gives up when the feature is removed from it.

        def settle_spans(claim, graph, _limits)
          slug    = feature_slug(claim)
          members = graph.feature(slug)
          return nil if members.empty?

          sides = sides_of(graph, members)
          return ["confirmed", "#{slug} has classified rooms on #{sides.size} sides"] if sides.size >= 2
          return nil unless frontiers_touching(graph, slug).empty?

          ["refuted", "every room reached lies on one side of #{slug}"]
        end

        def score_spans(claim, frontier, graph)
          members = graph.feature(feature_slug(claim))
          return 0.1 if members.empty?
          return 0.2 if members.include?(frontier[:room_id])

          (graph.undirected[frontier[:room_id]] || Set.new).intersect?(members) ? 1.0 : 0.1
        end

        # ---------- shared -----------------------------------------------------

        # "feature:wall_road" is how a subject naming a feature is spelled, so
        # the ledger can hold `subject` as one column whether it names a feature,
        # a class or a place.
        def feature_slug(claim)
          claim[:args]["feature"] || claim[:subject].to_s.sub(/\Afeature:/, "")
        end

        def frontiers_touching(graph, slug)
          members = graph.feature(slug)
          graph.frontiers.select { |f| members.include?(f[:room_id]) }
        end

        def frontiers_into(graph, subset)
          graph.frontiers.select { |f| subset.include?(f[:room_id]) }
        end

        def subset_rooms(claim, graph)
          explicit = Array(claim[:args]["rooms"]).map(&:to_i)
          return Set.new(explicit) if explicit.any?

          graph.feature(claim[:args]["subset"] || feature_slug(claim))
        end

        def chain_reaches?(graph, members, name)
          members.any? { |id| DestinationSearch.normalize(graph.room_name(id)).include?(
            DestinationSearch.normalize(name)
          ) }
        end

        # The components the graph falls into once the feature's own rooms are
        # removed. Two or more means the feature genuinely divides the place,
        # which is what `spans` is asking about.
        def sides_of(graph, members)
          seen  = Set.new
          sides = []
          graph.rooms.map { |r| r[:id] }.reject { |id| members.include?(id) }.each do |start|
            next if seen.include?(start)

            side  = Set.new
            stack = [start]
            until stack.empty?
              id = stack.pop
              next if members.include?(id) || !seen.add?(id)

              side << id
              (graph.undirected[id] || Set.new).each { |n| stack << n unless members.include?(n) || seen.include?(n) }
            end
            sides << side if side.any?
          end
          sides
        end
      end
    end
  end
end
