require_relative "claim_planner"
require_relative "claim_ledger"
require_relative "survey_graph"
require_relative "execute_route_tool"
require_relative "region_tools"
require_relative "egress"
require_relative "../../operation"

module Boukensha
  module Mud
    module Navigation
      # Survey-mode `move_to` — docs/plans/week_3/movement_revisited/
      # surveyor_architecture.md.
      #
      # `move_to(destination:)` is destination-shaped: every successful call is
      # trying to make a room match a name. Asking it to "walk around town and
      # work out what is here" forced the player to invent successive destination
      # names, because there was no coverage objective and no completion
      # condition — and the recorded Midgaard run is what that produces, six of
      # twelve moves spent inside one inn because each individual choice was
      # defensible when the only stated goal was to find somewhere.
      #
      # This is the other mode, and it shares the whole walking engine: the same
      # breadth-first search over the remembered graph, the same bounded legs,
      # the same per-step reconciliation through `Mud::Hooks`, the same
      # interruption polling. What differs is the objective and the termination
      # test. A survey maintains a ledger of falsifiable claims, the planner
      # scores frontiers by what the open claims would learn from each, and the
      # survey ends when no open claim has a decisive test left within budget.
      #
      # Neither strategy nor completion is chosen by anyone here. Strategy is
      # whichever scoring functions the open claims contribute; completion is a
      # computation over the same ledger. The surveyor never names a frontier.
      class Survey
        DEFAULT_LIMITS = {
          # A survey walks further than a trip to the bakery, and the room budget
          # is the only thing standing between "map the town" and "map the world".
          "survey_max_rooms"        => 30,
          "survey_max_legs"         => 14,
          # Surveyor calls, not legs. The two run away independently: a dense
          # interior consumes legs and tells the surveyor nothing it could act
          # on, which is exactly the case the conditional call cadence exists for.
          "survey_max_reasoner_calls" => 8,
          "max_steps_per_leg"       => 4,
          "max_open_claims"         => 6,
          "survey_saturation_rooms" => 6,
          # Steps that did not land. A survey meets more of these than a trip to
          # a named place does, because it is deliberately walking at the edge
          # of what is mapped, so the allowance is larger than travel's two —
          # and it has to be non-zero at all, since about one move in twenty is
          # refused in ordinary play and a survey that abandoned a thirty-room
          # budget over one shut door could never achieve coverage on a map
          # with a shut door in it.
          "survey_max_setbacks"     => 4,
          # The same recovery budget travel gets, and a survey needs it more: it
          # walks at the edge of the map on purpose, which is where the unlit rooms
          # and the one-way drops are (blind_step_recovery.md §5.5).
          "max_blind_steps"         => 6
        }.freeze

        def initialize(store:, call_tool:, hooks:, surveyor:, cartographer: nil,
                       limits: nil, logger: nil, journal: nil)
          @store        = store
          @call_tool    = call_tool
          @hooks        = hooks
          @surveyor     = surveyor
          @cartographer = cartographer
          @logger       = logger
          @journal      = journal
          @limits       = DEFAULT_LIMITS.merge((limits || {}).transform_keys(&:to_s))
        end

        def limit(key)
          Integer(@limits[key])
        rescue ArgumentError, TypeError
          Integer(DEFAULT_LIMITS.fetch(key))
        end

        # question: the player's objective in its own words.
        # scope:    "region" confines the survey to the place it is standing in,
        #           "world" lifts that. Same meaning it has for travel.
        def call(question:, scope: "region")
          @question     = question.to_s.strip
          @scope        = %w[region world].include?(scope.to_s) ? scope.to_s : "region"
          @legs         = []
          @rooms_walked = 0
          @calls        = 0
          @setbacks     = 0
          @status       = nil
          @detail       = nil

          return "[move_to] error: a survey needs a question" if @question.empty?

          here         = @store.player[:current_room_id]
          # The anchor §13's conduct measure counts from, journalled on `answered`
          # exactly as travel journals it. A survey is where most of a cold run's
          # walking happens, so a measure that could only see travel calls would
          # miss the legs that matter most.
          @origin_room = here
          if here.nil?
            @status = "position_unknown"
            @detail = "your location has not been established yet; take one safe action first"
            answered
            return render
          end

          @region    = @store.region_for_room(here)
          @region_id = @region && @region[:id]
          @planner   = ClaimPlanner.new(store: @store, region_id: @region_id,
                                        limits: @limits, journal: @journal)

          span("move_to survey #{@question}") { run }
          answered
          render
        end

        private

        def run
          # Seeding is the one place a surveyor failure is fatal. Once a ledger
          # exists the planner can keep scoring against it with no reasoner at
          # all, which is a real robustness gain over the superseded design where
          # a mid-survey failure removed the only component able to choose.
          return unless seed_ledger

          settled_now = []
          loop do
            graph = build_graph
            settled_now = @planner.evaluate!(graph)
            @planner.unpark_if_room!

            claims = @planner.open_claims
            if claims.empty?
              @status = "surveyed"
              @detail = "every claim in the ledger has been settled"
              return
            end
            if graph.frontiers.empty?
              # Frontiers exist but all lie outside the surveyed region — or, as
              # of staying_in_town.md §10.2, the surveyor has said they leave the
              # place. Either way it is a question rather than a wall, exactly as
              # it is for travel, so the answer carries the call that would
              # proceed anyway. A survey that has walked a whole town and stopped
              # without saying what would continue it invites the same call again.
              if out_of_scope_frontiers?(graph)
                @status = "region_exhausted"
                @detail = "every remaining lead leaves #{@region ? @region[:label] : 'here'}; " \
                          "move_to(survey: #{@question.inspect}, scope: \"world\") goes anyway"
              else
                @status = "exhausted"
              end
              return
            end
            unless @planner.settleable?(graph, rooms_left, claims: claims)
              @status = "surveyed"
              @detail = "no open claim has a decisive test left within the remaining budget"
              return
            end
            if rooms_left <= 0
              return stop_on_budget("survey_max_rooms")
            end
            if @legs.size >= limit("survey_max_legs")
              return stop_on_budget("survey_max_legs")
            end

            decision = @planner.choose(graph, claims: claims)
            return @status = "exhausted" unless decision

            steps = Array(decision.frontier[:path]) + [decision.frontier[:direction]]
            steps = steps.first([limit("max_steps_per_leg"), rooms_left].min)
            before = @store.rooms.size
            return unless leg(steps, decision)

            discovered = @store.rooms.size - before
            @planner.charge!(decision.claim, @rooms_walked_this_leg)

            # The surveyor does not run after every leg. A leg that discovered no
            # new room and settled no claim tells it nothing it could act on, so
            # the planner carries on against the ledger it already has — which is
            # what bounds reasoner cost the way `max_decisions` bounds navigator
            # calls today, and in practice means dense interiors are nearly free.
            revise_ledger if discovered.positive? || settled_now.any?
            consider_split
          end
        end

        # ---------- the surveyor -------------------------------------------

        # The first call receives only the objective and the current room, and is
        # asked to convert the question into seed claims. When a previous survey
        # of this region left a ledger behind, it receives that instead and will
        # usually propose nothing at all — which is the entire point of
        # persisting claims, and why a second survey of Midgaard costs nine rooms
        # where the first cost twenty-six.
        def seed_ledger
          existing = @planner.open_claims
          if existing.any? && @surveyor.nil?
            journal("survey_resumed", claims: existing.size)
            return true
          end

          unless @surveyor
            @status = "surveyor_failed"
            @detail = "no surveyor is configured, so there is no ledger to score against"
            return false
          end

          answer = ask_surveyor(seed_payload(existing))
          if answer.nil? && existing.empty?
            @status = "surveyor_failed"
            @detail = @detail || "the surveyor did not produce an opening ledger"
            return false
          end

          apply(answer)
          @planner.enforce_open_cap!
          if @planner.open_claims.empty?
            @status = "surveyor_failed"
            @detail = "the surveyor opened no claim that could be scored against the map"
            return false
          end
          true
        end

        def revise_ledger
          return unless @surveyor
          return if @calls >= limit("survey_max_reasoner_calls")

          answer = ask_surveyor(revision_payload)
          apply(answer) if answer
        end

        def ask_surveyor(payload)
          @calls += 1
          answer = @surveyor.call(payload)
          unless answer.is_a?(Hash)
            @detail ||= "the surveyor's answer could not be read as JSON"
            journal("surveyor_unreadable", call: @calls)
            return nil
          end
          answer
        rescue StandardError => e
          Boukensha.error_log.record(e, component: "move_to", boundary: "surveyor")
          @detail ||= e.message
          nil
        end

        def apply(answer)
          ledger = ClaimLedger.new(store: @store, region_id: @region_id,
                                   objective: @question, journal: @journal).apply!(answer)
          journal("ledger_revised", opened: ledger.opened.size, revised: ledger.revised.size,
                                    rejected: ledger.rejected.size, call: @calls)
          @planner.enforce_open_cap!
          ledger
        end

        def seed_payload(existing)
          {
            "objective" => { "question" => @question, "scope" => @region && @region[:label] },
            "here" => room_label(here_id),
            "budget" => budget_line,
            "ledger" => existing.map { |c| claim_summary(c) },
            "new_evidence" => [room_evidence(here_id)].compact,
            "predicates" => Predicates::NAMES
          }
        end

        # The ledger plus what has been seen since the previous call — never the
        # full chronological transcript. That is what makes the conditional
        # cadence work: the surveyor only ever needs to reason about what changed.
        def revision_payload
          {
            "objective" => { "question" => @question, "scope" => @region && @region[:label] },
            "here" => room_label(here_id),
            "budget" => budget_line,
            "ledger" => @planner.ledger.map { |c| claim_summary(c) },
            "new_evidence" => new_evidence,
            "open_frontiers" => open_frontiers,
            "predicates" => Predicates::NAMES
          }
        end

        def claim_summary(claim)
          {
            "ref" => claim[:ref], "statement" => claim[:statement], "predicate" => claim[:predicate],
            "subject" => claim[:subject], "status" => claim[:status],
            "confidence" => claim[:confidence], "priority" => claim[:priority],
            "args" => claim[:args], "rooms_spent" => claim[:rooms_spent],
            "room_budget" => claim[:room_budget], "settled_reason" => claim[:settled_reason]
          }.compact
        end

        # Rooms arrived in since the surveyor last ran, with their exits. Room
        # descriptions are truncated rather than sent whole, and the set is what
        # is NEW rather than everything walked, because the conditional call
        # cadence only works if each call is small: the surveyor never needs the
        # chronological transcript, only what changed.
        def new_evidence
          @evidence_seen ||= {}
          @legs.flat_map { |l| l[:completed] }.map { |c| c[:room_id] }.compact.uniq
               .reject { |id| @evidence_seen[id] }
               .each { |id| @evidence_seen[id] = true }
               .filter_map { |id| room_evidence(id) }
        end

        def room_evidence(room_id)
          room = room_id && @store.room(room_id) or return nil

          {
            "room_id" => room[:id], "name" => room[:name],
            "description" => room[:description].to_s[0, 400],
            "exits" => @store.exits_for(room[:id]).map do |e|
              { "direction" => e[:direction], "leads_to" => e[:target_name],
                "walked" => !e[:target_room_id].nil? }.compact
            end
          }
        end

        # The unexplored exits the surveyor may annotate with expected-class
        # hints. It is already reading these names, so the annotation is free —
        # and it puts the one genuinely semantic guess in the survey, what lies
        # behind an unwalked exit, in the component that should be guessing.
        # The assessment already on record travels with each frontier, so a
        # surveyor is not asked the same question twice and can see which doors an
        # earlier session — or a walk that came back with nothing — has already
        # written off. `unknown` is sent as nothing at all rather than as the word,
        # because "nobody has said" and "somebody said unknown" are the same state
        # and printing a value invites the model to echo it.
        def open_frontiers
          graph = build_graph
          graph.frontiers.first(12).map do |f|
            assessed = graph.assessability(f)
            recorded = graph.egress(f)
            { "room_id" => f[:room_id], "direction" => f[:direction],
              "from" => f[:room_name], "leads_to" => f[:target_name], "moves_away" => f[:distance],
              "assessability" => (assessed unless assessed == Assessment::UNKNOWN),
              # Same rule as `assessability`: a default is sent as nothing at all
              # rather than as the word, because "nobody has said" and "somebody
              # said interior" are the same state and printing a value invites the
              # model to echo it. Under region scope a `leaves` frontier is not in
              # this list at all, so what this shows back is a `boundary` the
              # surveyor already named.
              "egress" => (recorded unless recorded == Egress::INTERIOR),
              "hazard" => graph.hazard(f) }.compact
          end
        end

        def budget_line
          { "rooms_spent" => @rooms_walked, "rooms_remaining" => rooms_left,
            "legs_remaining" => limit("survey_max_legs") - @legs.size }
        end

        # ---------- the map -------------------------------------------------

        def build_graph
          SurveyGraph.build(store: @store, here: here_id, region_id: @region_id,
                            scope_room_ids: scope_room_ids)
        end

        # Survey scope confines the frontier set the way it confines exploration
        # for travel. A survey of Midgaard that wandered into the fields would
        # answer a different question from the one it was asked.
        def scope_room_ids
          return nil if @scope == "world" || @region.nil?

          ids = @store.region_descendants(@region_id)
          @store.room_regions.select { |_, m| ids.include?(m[:region_id]) }.keys
        end

        # Are there leads left that this scope will not let the survey take?
        #
        # It answers by counting what is reachable WITHOUT the scope filter and
        # relying on the caller having already found `graph.frontiers` empty: if
        # any reachable frontier survives here, it is one the scope removed. That
        # covers `leaves` frontiers with no extra clause, because `SurveyGraph`
        # drops them from the same set for the same reason — and it is what turns
        # a survey that has walked a whole town into a report saying every
        # remaining lead leaves Midgaard, in words the player can act on, rather
        # than into a stall.
        def out_of_scope_frontiers?(_graph)
          return false unless scope_room_ids

          distances = RoutePlanner.distances(exits: @store.all_exits, from: here_id)
          @store.all_exits.any? { |e| RoutePlanner.frontier?(e) && distances.key?(e[:room_id]) }
        end

        # The cartographer runs only behind a CONFIRMED `region_distinct` claim,
        # which is what keeps a frontier-scoring decision from directly mutating
        # persistent region structure. Scope suspicion stopped being a side
        # channel the moment it became an ordinary claim: it accumulates evidence
        # over several legs, competes for attention on priority, and can be
        # refuted rather than only ever escalating.
        def consider_split
          return unless @cartographer && @region

          claim = @store.claims(region_id: @region_id, status: "confirmed")
                        .find { |c| c[:predicate] == "region_distinct" && c[:args]["split_at"].nil? }
          return unless claim

          decision = @cartographer.call(cartographer_payload(claim))
          return unless decision.is_a?(Hash)

          room_id = decision["split_at_room_id"]
          if room_id.nil?
            journal("region_split_declined", claim: claim[:ref], reason: decision["reason"])
            return @store.update_claim!(claim[:id], args: claim[:args].merge("split_at" => false))
          end

          result = RegionTools.split_region(
            store: @store, region: decision["label"].to_s, within: decision["within"],
            reason: decision["reason"].to_s, at_room_id: Integer(room_id)
          )
          @store.update_claim!(claim[:id], args: claim[:args].merge("split_at" => Integer(room_id)))
          journal("region_split", claim: claim[:ref], at_room_id: room_id, result: result)
        rescue StandardError => e
          Boukensha.error_log.record(e, component: "move_to", boundary: "survey_split")
        end

        def cartographer_payload(claim)
          graph = build_graph
          {
            "current_room" => room_label(here_id),
            "detected_because" => claim[:statement],
            "rooms" => (scope_room_ids || @store.rooms.map { |r| r[:id] }).sort.filter_map do |id|
              room = @store.room(id) or next nil
              { "id" => id, "name" => room[:name], "first_entered_from" => room[:arrived_from_room_id],
                "first_entered_by" => room[:arrived_direction], "moves_from_here" => graph.distances[id] }.compact
            end,
            "edges" => RoutePlanner.traversable(@store.all_exits).map do |e|
              { "from" => e[:room_id], "direction" => e[:direction], "to" => RoutePlanner.target_of(e) }
            end
          }
        end

        # ---------- walking --------------------------------------------------

        def leg(steps, decision)
          n = @legs.size + 1
          before_room = here_id
          result = span("move_to survey leg #{n}") do
            ExecuteRouteTool.walk(steps: steps, call_tool: @call_tool, hooks: @hooks,
                                  blind_steps: limit("max_blind_steps"))
          end

          @legs << result.merge(requested: steps, claim: decision.claim && decision.claim[:ref],
                                reason: decision.claim && decision.claim[:statement])
          @rooms_walked_this_leg = result[:completed].size
          @rooms_walked += @rooms_walked_this_leg

          return handle_stop(result) if result[:stopped]
          return false if egress_backstop(result, before_room)

          true
        end

        # The same backstop travel has — staying_in_town.md §10.4 — and the
        # survey is the mode it names the uncovered cases for: a hint that was
        # absent is a surveyor that was never asked about an exit, or was asked
        # and said nothing. Under region scope the planner never offers a
        # frontier the surveyor called `leaves`, so this only ever catches a
        # crossing that nothing predicted, and it catches it one room late.
        #
        # Off under `scope: "world"`, where the player asked to range and a
        # crossing is the point rather than the failure.
        def egress_backstop(result, before_room)
          return false unless @scope == "region" && @origin_room

          inside = Guard.scope_rooms(@store, @origin_room)
          edge   = Guard.first_departure(result[:completed], before_room, inside)
          return false unless edge

          left = @store.region_for_room(edge[:from])
          if Guard.declare!(store: @store, edge: edge, region: left,
                            reason: "a survey leg landed outside the place this call began in")
            journal("egress_recorded", from_room_id: edge[:from], to_room_id: edge[:to],
                                       direction: edge[:direction], region: left[:label], scope: @scope)
          end
          @status = "left_region"
          @detail = "a leg landed outside #{left ? left[:label] : 'the place this survey began in'}; " \
                    "move_to(destination: #{@store.room(edge[:from])&.[](:name).inspect}) walks back"
          true
        end

        # The survey's half of `MoveTo#handle_stop`, and the place the recorded
        # failure actually cost coverage: this returned false for every kind of
        # stop, so one refused step on leg 5 ended a survey holding four open
        # claims, twenty-six unspent rooms and nine unspent legs.
        #
        # A step that did not land is charged to the claim that asked for it —
        # the caller does that on the way past — and the loop then re-scores the
        # ledger against a graph that no longer offers the frontier just proved
        # unwalkable, so the next choice is a different one by construction.
        def handle_stop(result)
          case result[:stopped_kind]
          # A recovered position is a corrected map, which is what this arm
          # re-plans against. It is what keeps a survey that fell down a well from
          # ending on leg five with twenty-six rooms of budget unspent.
          when :refused, :unreadable, :recovered
            @setbacks += 1
            return true if @setbacks < limit("survey_max_setbacks")

            @status = "budget"
            @detail = "survey_max_setbacks (#{limit('survey_max_setbacks')}) reached: #{result[:stopped]}"
            false
          when :position_lost, :recovery_exhausted, :stuck
            @status = result[:stopped_kind].to_s
            @detail = result[:stopped]
            false
          else
            @status = "interrupted"
            @detail = result[:stopped]
            false
          end
        end

        def rooms_left = limit("survey_max_rooms") - @rooms_walked

        def stop_on_budget(which)
          @status = "budget"
          @detail = "#{which} (#{limit(which)}) reached"
          nil
        end

        # A survey is a `move_to` call like any other, so it journals the same
        # `answered` line the destination mode does and lands in the same
        # `no_progress_calls` projection. `destination` is the question, because
        # what the repeat count is watching for is the same objective asked twice
        # with nothing having changed in between.
        def answered
          journal("answered", destination: @question, status: @status.to_s,
                              rooms_walked: @rooms_walked, legs: @legs.size,
                              surveyor_calls: @calls, mode: "survey",
                              from_room_id: @origin_room)
        end

        # ---------- the report -----------------------------------------------

        # The final report IS the ledger. Every line is falsifiable, every line
        # names its evidence, and the incomplete ones say precisely what would
        # finish them — which is the property that makes the next session cheap.
        # Coverage numbers appear as context rather than as the answer, because a
        # count of rooms walked was never the thing anyone asked about.
        def render
          lines = ["[move_to] survey of #{@region ? @region[:label] : 'here'} — #{headline}"]
          lines << @detail if @detail
          lines << ""
          lines.concat(findings)
          lines << ""
          lines << "walked #{@rooms_walked} room#{'s' unless @rooms_walked == 1} in #{@legs.size} " \
                   "leg#{'s' unless @legs.size == 1}, #{@calls} surveyor call#{'s' unless @calls == 1}"
          lines << "here: #{room_label(here_id)}"
          lines.compact.join("\n")
        end

        def headline
          case @status
          when "surveyed"         then "surveyed"
          when "budget"           then "stopped on budget"
          when "interrupted"      then "interrupted"
          when "exhausted"        then "no reachable frontier remains"
          when "region_exhausted" then "every remaining frontier leaves this region"
          when "left_region"      then "stopped — this walked out of the place being surveyed"
          when "surveyor_failed"  then "stopped — the surveyor did not answer"
          when "position_unknown" then "position unknown"
          when "position_lost"    then "stopped — where you are is no longer known"
          else @status.to_s
          end
        end

        VERDICTS = { "confirmed" => "CONFIRMED", "refuted" => "REFUTED", "unresolved" => "UNRESOLVED",
                     "parked" => "PARKED", "open" => "OPEN" }.freeze

        def findings
          claims = @planner ? @planner.ledger : []
          return ["Findings", "  (nothing was established)"] if claims.empty?

          evidence = @store.claim_evidence_by_claim(region_id: @region_id)
          # Settled claims first, and among them the ones that were answered —
          # a reader wants the findings before the loose ends.
          order = { "confirmed" => 0, "refuted" => 1, "unresolved" => 2, "open" => 3, "parked" => 4 }
          ["Findings"] + claims.sort_by { |c| [order.fetch(c[:status], 9), -c[:priority].to_f, c[:id]] }
                               .flat_map { |c| finding_lines(c, evidence[c[:id]] || []) }
        end

        def finding_lines(claim, evidence)
          out = ["  #{VERDICTS.fetch(claim[:status], claim[:status].to_s.upcase).ljust(10)} #{claim[:statement]}"]
          out << "             #{claim[:settled_reason]}" if claim[:settled_reason]
          supporting = evidence.select { |e| e[:polarity] == "support" }
          against    = evidence.select { |e| e[:polarity] == "contradict" }
          out << "             evidence: #{evidence_names(supporting)}" if supporting.any?
          out << "             against:  #{evidence_names(against)}" if against.any?
          # An open claim at the end of a survey is a loose end, and saying what
          # would settle it is what lets the next session resume rather than
          # rediscover.
          out << "             to settle: #{claim[:decisive_when]}" if
            %w[open unresolved parked].include?(claim[:status]) && claim[:decisive_when]
          out
        end

        def evidence_names(rows)
          rows.first(5).map { |e| @store.room(e[:room_id])&.[](:name) || "room ##{e[:room_id]}" }
              .uniq.join(", ")
        end

        # ---------- plumbing ---------------------------------------------------

        def here_id = @store.player[:current_room_id]

        def room_label(id)
          room = id && @store.room(id)
          room ? "#{room[:name]} (##{room[:id]})" : "position unknown"
        end

        def span(name, &block)
          return @logger.operation(name, &block) if @logger

          Boukensha::Operation.open(name, &block)
        end

        def journal(op, **fields)
          @journal&.event(stream: "move_to", op: op, **fields.compact)
        end
      end
    end
  end
end
