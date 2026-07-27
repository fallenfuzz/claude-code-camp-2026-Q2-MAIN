require_relative "route_planner"

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

        def call(store:, destination:)
          query = destination.to_s.strip
          return "[route] error: destination is required" if query.empty?

          plan = RoutePlanner.plan(
            query: query,
            current_room_id: store.player[:current_room_id],
            rooms: store.rooms,
            exits: store.all_exits,
            entities_by_room: store.entities_by_room,
            frontier_attempt_counts: store.frontier_attempt_counts
          )
          render(plan, store)
        end

        def render(plan, store)
          case plan.status
          when "position_unknown" then render_position_unknown(plan)
          when "arrived"          then render_arrived(plan, store)
          when "known"            then render_known(plan, store)
          when "explore", "unknown" then render_frontier(plan, store)
          when "unreachable"      then render_unreachable(plan, store)
          when "exhausted"        then render_exhausted(plan)
          else "[route] #{plan.query} — #{plan.status}"
          end
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

        def render_frontier(plan, store)
          source_room = store.room(plan.frontier[:room_id])
          lines = ["[route] #{plan.query} — #{plan.status}"]
          lines << (plan.status == "explore" ? "clue: #{plan.evidence}" : "reason: nearest unvisited exit; no remembered room matches #{plan.query.inspect}")
          lines << "frontier: #{plan.frontier[:direction]} from #{source_room ? source_room[:name] : '?'}"
          lines << "path: #{path_line(plan.steps)}" unless plan.steps.empty?
          lines << "then explore: #{plan.frontier[:direction]} (destination beyond this exit is not mapped)"
          lines.join("\n")
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
