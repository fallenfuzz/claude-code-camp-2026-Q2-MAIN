require_relative "plan_route_tool"
require_relative "execute_route_tool"
require_relative "region_tools"
require_relative "survey"
require_relative "../../operation"

module Boukensha
  module Mud
    module Navigation
      # The one movement tool on the player's surface — move_to.md §2.
      #
      # The agent used to have three ways to move, and in the cold case only the
      # worst one was usable: `execute_route` walks a path `plan_route` has
      # already called `known`, and in an unmapped world `plan_route` answers
      # `unknown` with a frontier listing and no path. There were no steps to
      # pass, so the agent fell back to `move` and paid one full model call per
      # room. Session `20260729T182950Z-c79e9b97` is that in full: fourteen
      # iterations, eleven of them a single `move`, 49,819 input tokens against
      # 1,179 output — 97.6% of the turn's spend re-sending context.
      #
      # So the fork is gone. `move_to("the bakery")` plans, and then:
      #
      #   arrived  → return immediately
      #   known    → walk it. No reasoning step; there is nothing to decide.
      #   unknown  → the bounded loop below: ask `Tasks::Navigator` which
      #              frontier, walk it, re-plan, repeat.
      #
      # Two decisions, split by who is competent to make them. WHICH DIRECTION
      # belongs to the navigator, because exit *names* carry meaning and
      # `plan_route` says so in its own output: its ordering "knows nothing
      # about what these names mean — you do." HOW FAR TO WALK IT AND WHEN TO
      # STOP belongs here, because walking, reconciling, polling and classifying
      # are already written and tested.
      #
      # Everything about this class is bounded on purpose. An unbounded loop
      # inside one tool call is precisely how the pre-bootcamp outer layer
      # failed, and a limit that is declared but not enforced is worse than no
      # limit — see §4.3 and the four numbers in DEFAULT_LIMITS.
      class MoveTo
        NAME = "move_to".freeze

        # The settings key its permission slice and its knobs live under:
        # `tools.navigation.allow` and `tools.navigation.limits`. Named for the
        # subsystem rather than the tool because the slice is the WALKER's, and
        # `move_to` is only the surface it is reached through.
        NAVIGATION_SLICE = "navigation".freeze

        # Defaults for `tools.navigation.limits`. None of these should be
        # constants in Ruby and none of them are: "is Haiku good enough to pick
        # a frontier" and "how far is too far" are questions the batch harness
        # answers, and it can only sweep them if they are configuration. These
        # are the starting positions, and the fallback when a deployment says
        # nothing.
        DEFAULT_LIMITS = {
          # The one that prevents the old failure. Without it a single move_to
          # can walk the map, and the player agent has neither visibility into
          # it nor a chance to intervene.
          "max_rooms"                 => 12,
          # Bounds SPEND rather than distance. The two run away independently: a
          # long corridor is many rooms and one decision, a dense town is few
          # rooms and many decisions.
          "max_decisions"             => 6,
          # How stale a direction is allowed to get. Walk the whole way on one
          # decision and you re-derive the chessboard failure of
          # 20260728T190719Z-d2fa7ec6; re-plan every step and you have rebuilt
          # the per-move model call this design exists to remove.
          "max_steps_per_leg"         => 4,
          # A GATE, not a classifier (§5.7). Below this the scope question is
          # not put to the navigator at all. boundaries_revised deliberately
          # refuses to code a threshold — "the judgement is the model's" — and a
          # gate is a different thing from a decision: it suppresses obvious
          # negatives (one room, median zero) without encoding the judgement.
          "min_rooms_for_scope_check" => 3
        }.freeze

        # Values `place` may legally carry that mean "I am not making a claim".
        # §5.3 forbids deriving a place name from a room name — the temple is
        # *in* Midgaard — so a field that demanded an answer every leg would
        # manufacture confident bad labels at one per leg.
        UNCHANGED = ["", "unchanged", "unknown", "none", "null", "-", "?"].freeze

        # store:        Mud::Memory::Store. Read for planning, written through
        #               RegionTools only.
        # call_tool:    the NAVIGATION slice's dispatcher — move and poll, under
        #               `tools.navigation.allow`, with `initiator: "hook"` so
        #               every MUD call this makes is attributable (§6).
        # hooks:        the session's Mud::Hooks, for per-step reconciliation.
        # navigator:    ->(payload_hash) { answer_hash }, or nil. Nil is the
        #               step-4 shape: the known branch works and the unknown
        #               branch hands the frontier listing back to the player,
        #               which is what it does today.
        # cartographer: ->(payload_hash) { answer_hash }, or nil to leave
        #               splitting alone (steps 5 and 6).
        # act_on_place: false leaves `place` unread. The field is in the schema
        #               from step 5 so it can be watched in the logs before it
        #               is allowed to write, because §7.6 makes a wrong boundary
        #               durable.
        # surveyor:     ->(payload_hash) { answer_hash }, or nil to leave survey
        #               mode off. It keeps the claim ledger for `survey:` calls
        #               and is never consulted for destination travel.
        def initialize(store:, call_tool:, hooks:, navigator: nil, cartographer: nil, surveyor: nil,
                       limits: nil, logger: nil, journal: nil, act_on_place: true)
          @store        = store
          @call_tool    = call_tool
          @hooks        = hooks
          @navigator    = navigator
          @cartographer = cartographer
          @surveyor     = surveyor
          @logger       = logger
          @journal      = journal
          @act_on_place = act_on_place
          @limits       = DEFAULT_LIMITS.merge((limits || {}).transform_keys(&:to_s))
        end

        # A limit that cannot be read as an integer falls back to its default
        # rather than raising inside a tool call. A misspelt knob should cost the
        # deployment a warning, never the agent's ability to move.
        def limit(key)
          Integer(@limits[key])
        rescue ArgumentError, TypeError
          Integer(DEFAULT_LIMITS.fetch(key))
        end

        # The tool body. Returns the text the player sees.
        #
        # `scope:` closes a dead end the surface change would otherwise create.
        # `plan_route` answers `region_exhausted` when every unexplored exit
        # still reachable from here leaves the region, and boundaries_revised
        # §2 is explicit that this is "a question rather than a wall" — so the
        # answer prints the widening call to make. With `plan_route` off the
        # player's surface there would be nothing the player could do with that
        # remedy, and `find_hermit_mapped` — a case entirely about widening
        # deliberately, because a hermit by definition lives away from people —
        # would become unpassable.
        #
        # Widening stays the PLAYER's judgement rather than becoming automatic.
        # A subsystem that silently widened on every exhausted region would mean
        # scope never constrained anything, which is the property boundaries_revised
        # built it for.
        # `survey:` is the second objective mode, and it is a parameter on this
        # tool rather than a tool of its own — movement_revisited/README.md is
        # explicit about why. A separate `survey_region` tool would recreate the
        # fork this design exists to remove: the agent would drift back to
        # treating `move_to` as raw movement, exactly as it drifted back to
        # `move` when `plan_route` and `execute_route` sat beside it.
        #
        # The two modes share the whole walking engine and differ only in the
        # objective and the termination test. Destination mode stops when the
        # current room matches a name. Survey mode stops when the claim ledger
        # has no settleable open claim. The navigator is not called during a
        # survey, and the surveyor is not called during travel.
        def call(destination: nil, survey: nil, scope: "region")
          question = survey.to_s.strip
          return run_survey(question, scope) unless question.empty?

          query = destination.to_s.strip
          return "[move_to] error: give either a destination to travel to or a survey question" if query.empty?

          @scope        = %w[region world].include?(scope.to_s) ? scope.to_s : "region"
          @query        = query
          @legs         = []
          @rooms_walked = 0
          @decisions    = 0
          @status       = nil     # what ended the loop
          @detail       = nil     # a sentence about why, when there is one
          @plan_text    = nil     # plan_route's own words, when they are the answer

          span("#{NAME} #{query}") { run }
          render
        end

        private

        # Survey mode is built per call rather than held as state, because a
        # survey's own state is the ledger and the ledger lives in the store.
        # Two surveys of the same region a session apart are the same
        # investigation continued, and nothing in this object needs to know that.
        def run_survey(question, scope)
          unless @surveyor
            return "[move_to] survey — no surveyor is configured in this deployment, " \
                   "so surveying is unavailable. Travel to a named place instead."
          end

          Survey.new(store: @store, call_tool: @call_tool, hooks: @hooks, surveyor: @surveyor,
                     cartographer: @cartographer, limits: @limits, logger: @logger, journal: @journal)
                .call(question: question, scope: scope)
        end

        # The loop. Every exit from it sets @status, so `render` never has to
        # guess what happened.
        def run
          loop do
            plan, region, error = PlanRouteTool.resolve(store: @store, destination: @query, scope: @scope)
            if error
              @status = "error"
              @detail = error
              return
            end

            case plan.status
            when "arrived"
              @status = "arrived"
              return
            when "known"
              return unless walk_known(plan)
            when "explore", "unknown"
              return unless walk_frontier(plan, region)
            else
              # position_unknown, unreachable, exhausted, region_exhausted —
              # all four are answers, and plan_route's own rendering of them
              # already carries the remedy (region_exhausted prints the `scope:
              # "world"` call to make). Repeating that here in different words
              # would be a second, worse copy of it.
              @status    = plan.status
              @plan_text = PlanRouteTool.render(plan, @store, region, @scope, widen_with: NAME)
              return
            end
          end
        end

        # ---------- the known branch (§2, delivery step 4) -----------------
        #
        # No navigator call. `plan_route` has produced a path over rooms the
        # agent has already stood in, and there is nothing about it to decide.
        # Returns true to keep looping (which normally re-plans straight into
        # `arrived`), false when the loop is over.
        def walk_known(plan)
          steps = plan.steps.map { |s| s[:direction].to_s }
          if steps.empty?
            # `known` with no steps should be `arrived`; treat it as such rather
            # than spinning on a plan that asks for no moves.
            @status = "arrived"
            return false
          end

          budget = rooms_left
          if budget <= 0
            stop_on_budget("max_rooms")
            return false
          end

          leg(steps.first(budget), decision: nil)
        end

        # ---------- the unknown branch (§2, delivery step 5) ---------------

        def walk_frontier(plan, region)
          candidates = candidates_for(plan)
          if candidates.empty?
            # plan_route says there is a frontier and the listing says there is
            # not. Hand back its own words rather than inventing a direction.
            @status    = plan.status
            @plan_text = PlanRouteTool.render(plan, @store, region, @scope, widen_with: NAME)
            return false
          end

          unless @navigator
            # Step 4's shape, and the honest one for a deployment with no
            # navigator configured: the listing is the answer, exactly as
            # plan_route renders it today.
            @status    = plan.status
            @plan_text = PlanRouteTool.render(plan, @store, region, @scope, widen_with: NAME)
            return false
          end

          if @decisions >= limit("max_decisions")
            stop_on_budget("max_decisions")
            return false
          end
          if rooms_left <= 0
            stop_on_budget("max_rooms")
            return false
          end

          answer = decide(plan, region, candidates)
          @decisions += 1
          return false unless answer

          chosen, fallback = choose(answer["direction"], candidates, plan)
          unless chosen
            @status = "no_direction"
            @detail = "the navigator did not name a usable direction"
            return false
          end

          # Region judgement runs BEFORE the walk, because both halves of it are
          # claims about where the agent is standing NOW. Naming a region after
          # walking out of it would attach the label to the wrong place.
          #
          # Re-read between the two: `name_region` MERGES when the label already
          # exists, so the region the split then reasons about may be a different
          # row than the one the payload was built from — and asking
          # `region_descendants` for a merged-away id answers with nothing, which
          # would silently close the scope gate rather than report a problem.
          apply_place(answer, region)
          region = @store.region_for_room(here_id) || region
          consider_split(answer, region)

          steps = Array(chosen[:walk]).map(&:to_s) + [chosen[:direction].to_s]
          steps = steps.first([limit("max_steps_per_leg"), rooms_left].min)
          leg(steps, decision: {
            direction: chosen[:direction], reason: answer["reason"].to_s,
            leads_to: chosen[:leads_to], fallback: fallback
          })
        end

        # One navigator turn, journalled whatever it answers. A wrong turn that
        # is not journalled goes from eleven visible `move` calls to one opaque
        # "walked 9 rooms, found nothing" and becomes undebuggable (§6).
        def decide(plan, region, candidates)
          payload = navigator_payload(plan, region, candidates)
          answer  = @navigator.call(payload)
          unless answer.is_a?(Hash)
            # An unparseable answer is not an exception — `Reasoners.parse`
            # deliberately returns nil rather than raising, because raising would
            # abort a walk that has already moved the character. It still has to
            # end the loop with a reason: a stop with no reason renders as a
            # blank headline, which tells the player nothing.
            @status = "navigator_failed"
            @detail = "the navigator's answer could not be read as JSON"
            return nil
          end

          journal("decision", destination: @query, leg: @legs.size + 1,
                              direction: answer["direction"], reason: answer["reason"],
                              place: answer["place"], scope_suspect: answer["scope_suspect"],
                              candidates: candidates.size)
          answer
        rescue StandardError => e
          Boukensha.error_log.record(e, component: NAME, boundary: "navigator")
          @status = "navigator_failed"
          @detail = e.message
          nil
        end

        # What the navigator is given. ~600 tokens, built fresh per decision,
        # with no tool-schema prefix and no accumulating transcript — which is
        # the whole economic argument for it being a task and not the player.
        def navigator_payload(plan, region, candidates)
          payload = {
            "destination" => @query,
            "here" => room_label(plan.start_room),
            "region" => region ? region_shape(region, plan.start_room) : nil,
            "candidates" => candidates.map do |c|
              {
                "direction" => c[:direction],
                "leads_to" => c[:leads_to] || "(unnamed)",
                "from" => c[:from_name],
                "moves_away" => c[:distance],
                "walk" => c[:walk]
              }.compact
            end,
            "walked_so_far" => @legs.flat_map { |l| l[:completed].map { |s| s[:room_name] } }
          }.compact
          payload["clue"] = plan.evidence if plan.evidence
          # §5.7's gate. Below the threshold the fields are not on the payload at
          # all, so the common case never carries the question and the navigator
          # is never invited to answer one it has no evidence for.
          payload["scope_question"] = SCOPE_QUESTION if scope_gate_open?(region)
          payload
        end

        SCOPE_QUESTION = <<~TEXT.strip
          Does the `region` line still describe one place you would call "here",
          or has it grown to cover somewhere distinct? Answer `scope_suspect`
          with a boolean and `scope_reason` with one sentence. Read the
          distances, not the count: a dozen unexplored exits at a median of one
          move is a dense little town and is scope working correctly, while
          sixteen at a median of six with half of them six to twelve moves away
          is scope that has stopped meaning "here".
        TEXT

        # The frontier exits, flattened out of plan_route's banded listing with
        # the walk to each source room kept alongside — so a frontier chosen off
        # this list is one the subsystem can actually reach.
        def candidates_for(plan)
          plan.unexplored.flat_map do |group|
            group[:exits].map do |e|
              { direction: e[:direction].to_s, leads_to: e[:target_name],
                from_room_id: group[:room_id], from_name: group[:room_name],
                distance: group[:distance], walk: Array(group[:path]).map(&:to_s) }
            end
          end
        end

        # A direction the navigator named, resolved against the candidate list.
        #
        # Two candidates can share a direction when they hang off different
        # rooms, so the tie is broken by distance: the nearer source room wins.
        # That is a rule rather than a preference — an arbitrary pick among
        # equals is the thing §7.3 asks not to do.
        #
        # Returns [candidate, fallback_reason]. A `fallback_reason` means the
        # navigator's answer was not usable and the choice below was made by
        # this code, which the journal then records as such — a decision made by
        # arithmetic must never appear in the log as a decision made by
        # judgement.
        def choose(direction, candidates, plan)
          d = direction.to_s.strip.downcase
          matches = candidates.select { |c| c[:direction].downcase == d }
          return [matches.min_by { |c| c[:distance] }, nil] if matches.any?

          # §7.3: a room reached by movement text without a survey has no target
          # names, and the navigator degrades to guessing. The defined fallback
          # is plan_route's own top-ranked frontier — the one it would have
          # recommended — and never an arbitrary entry off the list.
          best = plan.frontier && candidates.find do |c|
            c[:from_room_id] == plan.frontier[:room_id] &&
              c[:direction] == plan.frontier[:direction].to_s
          end
          best ||= candidates.min_by { |c| [c[:leads_to].to_s.empty? ? 1 : 0, c[:distance]] }
          [best, "navigator answered #{direction.inspect}, which is not on the candidate list"]
        end

        # ---------- regions (§5) -------------------------------------------

        # §5.3. The subsystem applies the rename; the model does not reach for a
        # tool. A field the answer must contain cannot be skipped the way a tool
        # it may call can be, and `name_region` has been on the player's surface
        # and uncalled for exactly as long as it has existed.
        #
        # Fired only against an UNCONFIRMED region. A confirmed label is a
        # declaration somebody earned, and a per-leg field is not evidence
        # enough to overwrite one.
        def apply_place(answer, region)
          return unless @act_on_place
          return unless region
          return if region[:confirmed].to_i == 1

          place = answer["place"].to_s.strip
          return if UNCHANGED.include?(place.downcase)

          result = RegionTools.name_region(store: @store, region: place)
          journal("region_named", place: place, was: region[:label],
                                  reason: answer["reason"], result: result)
        rescue StandardError => e
          Boukensha.error_log.record(e, component: NAME, boundary: "apply_place")
        end

        # §5.4 / §5.5. Detection came from the navigator, off the shape line it
        # already had in front of it. Placement is a different job needing
        # different data, so it goes to the cartographer with the region's whole
        # room graph — and the cartographer can decline, which is the property
        # that keeps the first uneasy leg from manufacturing a permanent
        # boundary.
        def consider_split(answer, region)
          return unless @cartographer && region
          return unless scope_gate_open?(region)
          return unless truthy?(answer["scope_suspect"])

          decision = @cartographer.call(cartographer_payload(region, answer))
          return unless decision.is_a?(Hash)

          room_id = decision["split_at_room_id"]
          if truthy?(decision["split"]) == false || room_id.nil?
            journal("region_split_declined", region: region[:label], reason: decision["reason"],
                                             detected_by: answer["scope_reason"])
            return
          end

          room_id = Integer(room_id)
          unless region_room_ids(region).include?(room_id)
            journal("region_split_rejected", region: region[:label], room_id: room_id,
                                             reason: "room ##{room_id} is not in #{region[:label]}")
            return
          end

          # §5.6. The boundary is the edge the room was FIRST entered by, read
          # from `rooms.arrived_from_room_id` / `arrived_direction` — persisted
          # per room at discovery, so the placement is exact however many legs
          # ago it was walked.
          result = RegionTools.split_region(
            store: @store, region: decision["label"].to_s, within: decision["within"],
            reason: decision["reason"].to_s, at_room_id: room_id
          )
          journal("region_split", region: decision["label"], at_room_id: room_id,
                                  reason: decision["reason"], detected_by: answer["scope_reason"],
                                  result: result)
        rescue StandardError => e
          Boukensha.error_log.record(e, component: NAME, boundary: "consider_split")
          journal("region_split_failed", region: region && region[:label], error: e.message)
        end

        # The graph placement needs and a leg decision does not: every room in
        # the region with its name, its stored arrival edge, and which of them
        # still hold unexplored exits.
        def cartographer_payload(region, answer)
          ids       = region_room_ids(region)
          distances = RoutePlanner.distances(exits: @store.all_exits, from: here_id)
          frontiers = @store.all_exits.select { |e| e[:target_room_id].nil? && ids.include?(e[:room_id]) }
                            .group_by { |e| e[:room_id] }

          {
            "region" => region_shape(region, here_id),
            "current_room" => room_label(here_id),
            "detected_because" => answer["scope_reason"].to_s,
            "rooms" => ids.sort.map do |id|
              room = @store.room(id) or next nil
              {
                "id" => id,
                "name" => room[:name],
                "first_entered_from" => room[:arrived_from_room_id],
                "first_entered_by" => room[:arrived_direction],
                "moves_from_here" => distances[id],
                "unexplored_exits" => (frontiers[id] || []).map { |e| e[:direction] }
              }.compact
            end.compact,
            "edges" => @store.all_exits.select { |e| ids.include?(e[:room_id]) && e[:target_room_id] }
                              .map { |e| { "from" => e[:room_id], "direction" => e[:direction], "to" => e[:target_room_id] } }
          }
        end

        # §5.7. One room and a median of zero is not a scope problem, and asking
        # about it every leg would put the question on the payload in the case
        # where it can only ever be answered no.
        def scope_gate_open?(region)
          return false unless region

          region_room_ids(region).size >= limit("min_rooms_for_scope_check")
        end

        def region_room_ids(region)
          ids = @store.region_descendants(region[:id])
          @store.room_regions.select { |_, m| ids.include?(m[:region_id]) }.keys
        end

        def region_shape(region, from)
          RegionShape.line(store: @store, region: region,
                           distances: RoutePlanner.distances(exits: @store.all_exits, from: from))
        end

        # ---------- walking -------------------------------------------------

        # One leg: a span of its own, the walk, and the record of it. The span is
        # what lets `mud_monitor` nest a nine-room walk rather than scattering
        # nine unexplained commands through the model's narrative (§6).
        #
        # Returns true when the loop should continue.
        def leg(steps, decision:)
          n = @legs.size + 1
          result = span("#{NAME} leg #{n}") do
            ExecuteRouteTool.walk(steps: steps, call_tool: @call_tool, hooks: @hooks)
          end

          @legs << result.merge(decision: decision, requested: steps)
          @rooms_walked += result[:completed].size

          if result[:stopped]
            # An interruption is not a failure of the route. Return where we got
            # to and what interrupted, exactly as `execute_route` already does,
            # and let the player decide — that is the whole reason a fight
            # starting mid-walk is worth one round trip to report.
            @status = "interrupted"
            return false
          end

          # Always re-plan, even with the room budget spent. The budget check
          # lives at the top of each branch, so the loop's own `plan_route`
          # answers first — and if the last step of this leg happened to land on
          # the destination, "arrived" is the honest answer where "stopped on
          # budget" would be a false one. The re-plan is pure SQLite.
          true
        end

        def rooms_left = limit("max_rooms") - @rooms_walked

        def stop_on_budget(which)
          @status = "budget"
          @detail = "#{which} (#{limit(which)}) reached"
        end

        # ---------- rendering -----------------------------------------------

        # What the player reads. It has to carry three things a collapsed call
        # would otherwise destroy: where the agent ended up, every direction
        # chosen and WHY, and whether the call stopped because it was finished,
        # because it was interrupted, or because it ran out of budget. The three
        # are different instructions to whatever reads them next.
        def render
          return @detail if @status == "error"

          lines = ["[move_to] #{@query} — #{headline}"]
          # Not for `interrupted`: the leg line below already carries the exact
          # sentence the classifier stopped on, and saying it twice reads as two
          # separate events.
          lines << @detail if @detail && !%w[arrived interrupted].include?(@status)
          @legs.each_with_index { |l, i| lines.concat(leg_lines(i, l)) }
          lines << "walked #{@rooms_walked} room#{'s' unless @rooms_walked == 1} " \
                   "in #{@legs.size} leg#{'s' unless @legs.size == 1}" \
                   "#{", #{@decisions} decision#{'s' unless @decisions == 1}" if @decisions.positive?}"
          lines << "here: #{room_label(here_id)}"
          lines << @plan_text if @plan_text
          lines.compact.join("\n")
        end

        def headline
          case @status
          when "arrived"          then "arrived"
          when "budget"           then "stopped on budget"
          when "interrupted"      then "interrupted"
          when "no_direction"     then "stopped"
          when "navigator_failed" then "stopped — the navigator did not answer"
          else @status.to_s
          end
        end

        def leg_lines(i, leg)
          out = ["leg #{i + 1}: #{leg[:completed].map { |c| c[:direction] }.join(' → ')}" \
                 "#{" → #{leg[:completed].last[:room_name]}" if leg[:completed].any?}"]
          d = leg[:decision]
          if d
            out << "  chose #{d[:direction]}#{" (#{d[:leads_to]})" if d[:leads_to]}: #{d[:reason]}"
            out << "  fallback: #{d[:fallback]}" if d[:fallback]
          end
          out << "  stopped: #{leg[:stopped]}" if leg[:stopped]
          out
        end

        def here_id = @store.player[:current_room_id]

        def room_label(id)
          room = id && @store.room(id)
          room ? "#{room[:name]} (##{room[:id]})" : "position unknown"
        end

        # ---------- plumbing ------------------------------------------------

        # Falls back to a logger-less span so the ambient stack — and therefore
        # the journal's `operation_id` — behaves identically whether or not
        # anything is writing the brackets down.
        def span(name, &block)
          return @logger.operation(name, &block) if @logger

          Boukensha::Operation.open(name, &block)
        end

        # Every region declaration this subsystem makes on the model's behalf is
        # journalled with what produced it. A boundary that appears with no
        # recorded justification is indistinguishable from a bug in the
        # derivation (§6).
        def journal(op, **fields)
          @journal&.event(stream: NAME, op: op, **fields.compact)
        end

        def truthy?(value)
          return value if value == true || value == false
          return nil if value.nil?

          %w[true yes 1].include?(value.to_s.strip.downcase)
        end
      end
    end
  end
end
