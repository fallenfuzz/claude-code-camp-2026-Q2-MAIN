require_relative "route_planner"
require_relative "region_tools"

module Boukensha
  module Mud
    module Navigation
      # The native tool surface: validates input, reads one consistent
      # snapshot off the store, hands it to RoutePlanner, and renders the
      # compact text formats from docs/plans/week_2/plan_route.md §3.2.
      #
      # Zero MUD I/O — plan_route never moves the character and never issues a
      # hidden `look`. It performs a handful of SQLite reads and returns.
      module PlanRouteTool
        module_function

        # scope: "region" (default) confines EXPLORATION to the place the agent
        # is standing in and everything within it; "world" lifts that. Travel
        # is never scoped — see RoutePlanner#frontier_branch.
        def call(store:, destination:, scope: "region")
          plan, region, error = resolve(store: store, destination: destination, scope: scope)
          return error if error

          render(plan, store, region, scope)
        end

        # The plan, unrendered. `MoveTo` drives its loop off the RoutePlan's
        # `status`, `steps` and `unexplored` fields and renders the text only
        # when it is giving the answer back to the player — so the two callers
        # share one planning path rather than one of them re-deriving it or
        # parsing the other's prose.
        #
        # Returns [plan, region, nil] or [nil, nil, error_string]: validation is
        # the tool surface's job and both callers want the same message for it.
        def resolve(store:, destination:, scope: "region")
          query = destination.to_s.strip
          return [nil, nil, "[route] error: destination is required"] if query.empty?

          scope = scope.to_s
          unless %w[region world].include?(scope)
            return [nil, nil, "[route] error: scope must be \"region\" or \"world\""]
          end

          here   = store.player[:current_room_id]
          region = here && store.region_for_room(here)
          scope_ids = (scope == "world" || region.nil?) ? nil : store.region_descendants(region[:id])

          plan = RoutePlanner.plan(
            query: query,
            current_room_id: here,
            rooms: store.rooms,
            exits: store.all_exits,
            entities_by_room: store.entities_by_room,
            frontier_attempt_counts: store.frontier_attempt_counts,
            regions_by_room: store.room_regions.transform_values { |m| m[:region_id] },
            scope_region_ids: scope_ids
          )
          [plan, region, nil]
        end

        # `widen_with:` — the name of the tool the READER can actually call to
        # lift the region scope. `region_exhausted` is "a question rather than a
        # wall" (boundaries_revised §2), so its answer prints the widening call
        # as copyable text — and printing `plan_route` to a player that no longer
        # has `plan_route` on its surface (move_to.md §3) would be a remedy for
        # nobody. `MoveTo` passes its own name; every other caller keeps this
        # tool's own.
        def render(plan, store, region = nil, scope = "region", widen_with: "plan_route")
          # The label goes on the listing only when it actually constrained
          # it. Under `scope: "world"` the set spans every region the agent
          # has walked, and heading it "in Midgaard" would be false.
          scoped = scope == "region" ? region : nil
          body =
            case plan.status
            when "position_unknown" then render_position_unknown(plan)
            when "arrived"          then render_arrived(plan, store)
            when "known"            then render_known(plan, store)
            when "explore", "unknown" then render_frontier(plan, store, scoped)
            when "unreachable"      then render_unreachable(plan, store)
            when "exhausted"        then render_exhausted(plan)
            when "region_exhausted" then render_region_exhausted(plan, region, widen_with)
            else "[route] #{plan.query} — #{plan.status}"
            end

          # The shape of the place the agent is in, on one line, on every
          # exploring answer — and nothing anywhere branches on any of these
          # numbers (§2, §5).
          return body unless region && %w[explore unknown region_exhausted].include?(plan.status)

          lines = body.lines.map(&:chomp)
          lines.insert(1, "region: #{RegionShape.line(store: store, region: region,
                                                      distances: RoutePlanner.distances(exits: store.all_exits,
                                                                                        from: plan.start_room))}")
          lines.join("\n")
        end

        def render_position_unknown(plan)
          lines = ["[route] #{plan.query} — position unknown",
                   "reason: your location has not been established yet; take one safe action (e.g. move) first"]
          lines.join("\n")
        end

        def render_arrived(plan, store)
          room = store.room(plan.destination_room)
          lines = ["[route] #{plan.query} — arrived", "here: #{room_label(room)}"]
          lines << alternatives_line(plan) if plan.alternatives.any?
          lines.join("\n")
        end

        def render_known(plan, store)
          room = store.room(plan.destination_room)
          lines = ["[route] #{plan.query} — known", "to: #{room_label(room)}"]
          lines << "path: #{path_line(plan.steps)}"
          lines << chain_line(plan, store)
          lines << alternatives_line(plan) if plan.alternatives.any?
          lines.join("\n")
        end

        # The destination is not mapped. What used to be printed here was ONE
        # frontier with the other N hidden, which is how an agent asked to find
        # a bakery walked out of town without ever being shown that there was a
        # choice to make (boundaries_revised.md §1). The list is now the body of
        # the answer.
        #
        # `explore` keeps its single-lead block, because a clue naming one exit
        # IS a recommendation and withholding it would be its own kind of
        # dishonesty. `unknown` has no lead to offer, so it offers the set and
        # says outright that the ordering is arithmetic.
        def render_frontier(plan, store, region = nil)
          lines = ["[route] #{plan.query} — #{plan.status}"]

          if plan.status == "explore"
            source_room = store.room(plan.frontier[:room_id])
            lines << "clue: #{plan.evidence}"
            lines << "frontier: #{plan.frontier[:direction]} from #{source_room ? source_room[:name] : '?'}"
            lines << "path: #{path_line(plan.steps)}" unless plan.steps.empty?
            lines << "then explore: #{plan.frontier[:direction]} (destination beyond this exit is not mapped)"
          end

          lines.concat(unexplored_lines(plan, region))
          lines << reason_lines(plan) if plan.status == "unknown"
          lines.join("\n")
        end

        # ---------------------------------------------------------------
        # The banded listing. Bands in distance order, whole; a group per room
        # inside a band; the walk to that room in brackets so a frontier the
        # agent picks off this list is one it can actually reach.
        def unexplored_lines(plan, region = nil)
          return [] if plan.unexplored.empty?

          width = plan.unexplored.flat_map { |g| g[:exits].map { |e| e[:direction].to_s.length } }.max
          lines = [unexplored_header(plan, region)]
          plan.unexplored.each do |group|
            lines << "  #{group_header(group)}"
            group[:exits].each do |e|
              lines << "    #{e[:direction].to_s.ljust(width)} → #{e[:target_name] || '(unnamed)'}"
            end
          end
          lines << "  #{withheld_line(plan.withheld)}" if plan.withheld
          lines
        end

        def unexplored_header(plan, region)
          shown = plan.unexplored.sum { |g| g[:exits].size }
          count = plan.withheld ? "#{shown} of #{plan.unexplored_total}, nearest first" : "all #{shown}"
          "unexplored#{region ? ", in #{region[:label]}" : ', anywhere you have walked'} — #{count}:"
        end

        def group_header(group)
          label = case group[:distance]
                  when 0 then "here"
                  when 1 then "1 move"
                  else "#{group[:distance]} moves"
                  end
          path = group[:path].empty? ? "" : "  [#{group[:path].join(' → ')}]"
          "#{label} — #{group[:room_name] || '?'}#{path}"
        end

        def withheld_line(w)
          range = w[:min_distance] == w[:max_distance] ? "#{w[:min_distance]}" : "#{w[:min_distance]}–#{w[:max_distance]}"
          "#{w[:count]} more from #{w[:rooms]} room#{'s' unless w[:rooms] == 1}, #{range} moves away"
        end

        # Said in the same breath as the ordering it describes, which is the
        # whole reason none of this lives in the system prompt (§7).
        def reason_lines(plan)
          ["reason: no remembered room matches #{plan.query.inspect}; ordered by distance, which knows",
           "        nothing about what these names mean — you do"].join("\n")
        end

        def render_unreachable(plan, store)
          room = store.room(plan.destination_room)
          lines = ["[route] #{plan.query} — unreachable", "to: #{room_label(room)}",
                   "reason: destination is remembered, but no known path connects room ##{plan.start_room} to room ##{plan.destination_room}"]
          lines << alternatives_line(plan) if plan.alternatives.any?
          lines.join("\n")
        end

        def render_exhausted(plan)
          ["[route] #{plan.query} — exhausted",
           "reason: no reachable exploration frontier from your current position"].join("\n")
        end

        # A refusal that carries its own remedy. §2 is explicit that this is a
        # question rather than a wall, so the widening call is printed as text
        # the agent can copy, and the count says how much is on the other side
        # of the answer.
        def render_region_exhausted(plan, region, widen_with = "plan_route")
          n = plan.unexplored_total
          ["[route] #{plan.query} — region_exhausted",
           "reason: every unexplored exit still reachable from here leaves " \
           "#{region ? region[:label] : 'this region'}",
           "#{n} unexplored exit#{'s' unless n == 1} remain#{'s' if n == 1} outside it — to include them, call " \
           "#{widen_with}(destination: #{plan.query.inspect}, scope: \"world\")"].join("\n")
        end

        def room_label(room)
          room ? "#{room[:name]} (##{room[:id]})" : "?"
        end

        def path_line(steps)
          steps.map { |s| s[:direction] }.join(" → ")
        end

        def chain_line(plan, store)
          names = [store.room(plan.start_room)&.[](:name)] + plan.steps.map { |s| store.room(s[:to_room_id])&.[](:name) }
          n = plan.steps.size
          "#{n} move#{'s' unless n == 1}: #{names.compact.join(' → ')}"
        end

        def alternatives_line(plan)
          "alternatives: #{plan.alternatives.map { |a| "#{a[:name]} (##{a[:room_id]})" }.join(', ')}"
        end
      end
    end
  end
end
