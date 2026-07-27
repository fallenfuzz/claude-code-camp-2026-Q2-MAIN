require_relative "../event_classifier"

module Boukensha
  module Mud
    module Navigation
      # Walks a sequence of directions already returned by `plan_route`, one
      # MUD move per step, inside a single tool call — the batched-movement
      # extension move_around.md §6/§8 decided to build, gated on the simple
      # regex classifier so a fight starting mid-route is not discovered only
      # on arrival.
      #
      # `plan_route.md` §5 rejected exactly this for v1 ("bypass per-step
      # state refresh"). What keeps that risk from coming true is
      # `Mud::Hooks#reconcile_move!` — each step reconciles position
      # IMMEDIATELY through the same machinery an ordinary single `move`
      # eventually runs through, not a second copy of it.
      module ExecuteRouteTool
        module_function

        # steps:     canonical direction strings, e.g. ["west", "north"] —
        #            exactly what `plan_route`'s `known` result returned.
        # call_tool: ->(name, args_hash) { raw_text } — dispatches under the
        #            PLAYER's own permissions. Hooks' own dispatcher is scoped
        #            to the room-survey slice and cannot call `move` at all,
        #            so this must be the player's, not the hook's.
        # hooks:     the Mud::Hooks instance driving this session, for
        #            per-step reconciliation and event polling.
        def call(steps:, call_tool:, hooks:)
          steps = Array(steps).map(&:to_s)
          return "[route] execute_route: no steps given" if steps.empty?

          completed = []
          steps.each_with_index do |direction, i|
            text    = call_tool.call("tbamud__move", { "direction" => direction })
            outcome = hooks.reconcile_move!(direction: direction, text: text)

            return render_stopped(completed, steps, i + 1, "move failed (#{direction})") unless outcome && outcome[:ok]

            completed << { direction: direction, room_name: outcome[:room_name] }
            next if i == steps.size - 1 # the next before_model call polls for us

            poll_text   = call_tool.call("tbamud__poll", {})
            tier, line  = EventClassifier.classify(poll_text)
            return render_stopped(completed, steps, i + 1, line) if tier == :interrupting
          end

          render_completed(completed)
        end

        def render_completed(completed)
          lines = ["[route] executed #{completed.size}/#{completed.size}"]
          completed.each_with_index { |c, i| lines << step_line(i, c) }
          lines << "arrived: #{completed.last[:room_name]}"
          lines.join("\n")
        end

        def render_stopped(completed, steps, next_index, reason)
          lines = ["[route] executed #{completed.size}/#{steps.size} — stopped"]
          completed.each_with_index { |c, i| lines << step_line(i, c) }
          lines << "stopped: #{reason}"
          remaining = steps[next_index..]
          lines << "remaining: #{remaining.join(' → ')}" if remaining && !remaining.empty?
          lines.join("\n")
        end

        def step_line(i, c)
          "step #{i + 1}: #{c[:direction]} → #{c[:room_name]} (ok)"
        end
      end
    end
  end
end
