require_relative "predicates"
require_relative "survey_graph"
require_relative "route_planner"

module Boukensha
  module Mud
    module Navigation
      # The deterministic half of claim-driven surveying — docs/plans/week_3/
      # movement_revisited/claims.md and surveyor_architecture.md.
      #
      # It sits where a coverage planner would have sat and computes a different
      # thing. It evaluates every open claim's decisive condition against the
      # room graph, retires the claims that have been settled, and scores every
      # reachable frontier as the priority-weighted sum of what the remaining
      # open claims would learn from it.
      #
      # The most consequential fact about this class is what it takes AWAY from
      # the reasoner. Under the superseded design the surveyor returned a
      # `frontier_id`, which meant a semantic reasoner was making a movement
      # decision on every leg and `MoveTo` was left validating that decision
      # after the fact. Here movement selection is arithmetic over the ledger, so
      # the same ledger and the same graph always produce the same next leg —
      # survey behaviour is reproducible, and a mid-survey reasoner failure costs
      # the ledger's freshness rather than the survey's ability to move at all.
      class ClaimPlanner
        # How many claims may be open at once. Over the cap the lowest-priority
        # ones are PARKED rather than dropped, so their evidence survives to be
        # picked up when budget frees or new evidence arrives. A ledger nobody
        # bounded would end a survey with forty open propositions and no answer
        # to any of them.
        DEFAULT_MAX_OPEN_CLAIMS = 6

        Decision = Struct.new(:frontier, :claim, :score, :ranked, keyword_init: true)

        def initialize(store:, region_id:, limits: {}, journal: nil)
          @store     = store
          @region_id = region_id
          @limits    = (limits || {}).transform_keys(&:to_s)
          @journal   = journal
        end

        def limit(key, default)
          value = @limits[key]
          value.nil? ? default : Integer(value)
        rescue ArgumentError, TypeError
          default
        end

        # Every claim still capable of influencing where the survey walks.
        # `parked` is deliberately excluded from scoring and deliberately kept in
        # the ledger: parking is how a genuinely interesting observation stops
        # derailing a survey without being thrown away.
        def open_claims = @store.claims(region_id: @region_id, status: "open")

        def ledger = @store.claims(region_id: @region_id)

        # Run every open claim's decisive condition against the graph and settle
        # the ones that have fired. Returns the claims that settled, which is
        # also what forces a surveyor call: a claim being answered usually
        # changes what is worth investigating next.
        def evaluate!(graph)
          open_claims.filter_map do |claim|
            verdict = Predicates.settle(claim, graph, limits: @limits)
            next unless verdict

            status, reason = verdict
            @store.settle_claim!(claim[:id], status: status, reason: reason)
            journal("claim_settled", ref: claim[:ref], predicate: claim[:predicate],
                                     status: status, reason: reason)
            claim.merge(status: status, settled_reason: reason)
          end
        end

        # Frontier arbitration: a weighted vote, exactly as claims.md specifies
        # it. Each open claim contributes `priority × predicate_score` to every
        # candidate, the totals are divided by the walking cost of reaching each
        # candidate, and the existing deterministic frontier ranking breaks ties.
        #
        # Returns a Decision, or nil when there is nothing to walk to. `claim` on
        # that Decision is the claim that contributed most to the winner, which
        # is what the leg's room spend is charged against — a claim cannot
        # exhaust its own budget without having been the reason for the walking.
        def choose(graph, claims: nil)
          claims = claims || open_claims
          return nil if graph.frontiers.empty?

          scored = graph.frontiers.map do |frontier|
            contributions = claims.to_h do |claim|
              [claim[:id], claim[:priority].to_f * Predicates.score(claim, frontier, graph)]
            end
            total = contributions.values.sum
            # Walking cost, not distance: a frontier in the room the agent is
            # standing in costs one move, and dividing by a bare distance of zero
            # would make every adjacent frontier infinitely attractive.
            { frontier: frontier, score: total / (1 + frontier[:distance].to_i),
              contributions: contributions }
          end

          # Descending score, then the deterministic tie-break the rest of the
          # subsystem already uses — canonical direction order, then source room
          # id. Ties are common early in a survey, when nothing has been observed
          # and every claim scores every frontier the same, and an arbitrary pick
          # among equals would make the whole run irreproducible.
          ranked = scored.sort_by do |c|
            [-c[:score], c[:frontier][:distance].to_i,
             RoutePlanner::CANONICAL_DIRECTIONS.index(c[:frontier][:direction]) || 99,
             c[:frontier][:room_id]]
          end

          best  = ranked.first
          owner = best[:contributions].max_by { |_, v| v }&.first
          Decision.new(frontier: best[:frontier], score: best[:score], ranked: ranked,
                       claim: claims.find { |c| c[:id] == owner })
        end

        # Completion, and it is computed rather than judged: no open claim has a
        # decisive test reachable within the remaining budget. A claim scoring
        # zero on every frontier has nothing left to learn from walking, and a
        # claim whose nearest useful frontier is further away than the rooms
        # remaining cannot be settled however the survey spends them.
        def settleable?(graph, rooms_remaining, claims: nil)
          claims = claims || open_claims
          claims.any? do |claim|
            graph.frontiers.any? do |frontier|
              Predicates.score(claim, frontier, graph).positive? &&
                frontier[:distance].to_i + 1 <= rooms_remaining
            end
          end
        end

        # A claim's own room budget, spent. Charged to the claim that won the
        # leg, because `circuit_closes` can consume an entire survey if nothing
        # stops it — which is the specific failure `room_budget` exists to bound.
        def charge!(claim, rooms)
          return unless claim && rooms.positive?

          spent = claim[:rooms_spent].to_i + rooms
          @store.update_claim!(claim[:id], rooms_spent: spent)
          return unless claim[:room_budget] && spent >= claim[:room_budget].to_i

          @store.settle_claim!(claim[:id], status: "unresolved",
                                           reason: "claim room budget of #{claim[:room_budget]} spent")
          journal("claim_budget_spent", ref: claim[:ref], rooms: spent)
        end

        # Keep the working set bounded. The lowest-priority claims are parked,
        # never deleted, so the ledger stays readable without the survey
        # forgetting what it noticed.
        def enforce_open_cap!
          open = open_claims
          cap  = limit("max_open_claims", DEFAULT_MAX_OPEN_CLAIMS)
          return if open.size <= cap

          open.sort_by { |c| [-c[:priority].to_f, c[:id]] }.drop(cap).each do |claim|
            @store.update_claim!(claim[:id], status: "parked",
                                             settled_reason: "parked: #{open.size} claims open, cap is #{cap}")
            journal("claim_parked", ref: claim[:ref], priority: claim[:priority])
          end
        end

        # A parked claim comes back when there is room for it. Without this,
        # parking would be a one-way door and the lifecycle in claims.md would be
        # missing its only edge back to `open`.
        def unpark_if_room!
          cap  = limit("max_open_claims", DEFAULT_MAX_OPEN_CLAIMS)
          room = cap - open_claims.size
          return if room <= 0

          @store.claims(region_id: @region_id, status: "parked")
                .sort_by { |c| [-c[:priority].to_f, c[:id]] }.first(room).each do |claim|
            @store.update_claim!(claim[:id], status: "open", settled_reason: nil)
            journal("claim_unparked", ref: claim[:ref], priority: claim[:priority])
          end
        end

        private

        def journal(op, **fields)
          @journal&.event(stream: "survey", op: op, **fields.compact)
        end
      end
    end
  end
end
