require_relative "../event_classifier"

module Boukensha
  module Mud
    module Navigation
      # Walks a sequence of directions, one MUD move per step, inside a single
      # tool call — the batched-movement extension move_around.md §6/§8 decided
      # to build, gated on the simple regex classifier so a fight starting
      # mid-route is not discovered only on arrival.
      #
      # `plan_route.md` §5 rejected exactly this for v1 ("bypass per-step
      # state refresh"). What keeps that risk from coming true is
      # `Mud::Hooks#reconcile_move!` — each step reconciles position
      # IMMEDIATELY through the same machinery an ordinary single `move`
      # eventually runs through, not a second copy of it.
      #
      # It is no longer a tool the player can call. `move_to` owns movement now
      # (move_to.md §3), and this is the walking half of it: given directions,
      # walk them and say exactly what happened. `#call` survives as the
      # rendered form because that rendering is what `move_to` shows the player
      # per leg, and because the tool's own tests are written against it.
      module ExecuteRouteTool
        module_function

        # steps:     canonical direction strings, e.g. ["west", "north"] —
        #            exactly what `plan_route`'s `known` result returned.
        # call_tool: ->(name, args_hash) { raw_text } — dispatches under the
        #            NAVIGATION slice (`tools.navigation.allow`: move and poll).
        #            It used to be the player's own dispatcher, which was the
        #            only reason `tbamud__move` had to stay on the player's
        #            allowlist; move_to.md §3 moved both.
        # hooks:     the Mud::Hooks instance driving this session, for
        #            per-step reconciliation and event polling.
        def call(steps:, call_tool:, hooks:)
          steps = Array(steps).map(&:to_s)
          return "[route] execute_route: no steps given" if steps.empty?

          result = walk(steps: steps, call_tool: call_tool, hooks: hooks)
          return render_stopped(result, steps) if result[:stopped]

          render_completed(result[:completed])
        end

        # The walk, unrendered — `MoveTo` drives its bounded loop off these
        # fields rather than parsing the text below back out again.
        #
        #   { completed: [{ direction:, room_name:, room_id: }, …],
        #     stopped:   "move failed (up)" | nil,
        #     remaining: ["east", …] }
        #
        # `stopped` is a sentence rather than a code because every caller does
        # the same thing with it: says it. What a caller must branch on — did we
        # get there, how far did we get — is `completed` and `remaining`.
        def walk(steps:, call_tool:, hooks:)
          steps     = Array(steps).map(&:to_s)
          completed = []

          steps.each_with_index do |direction, i|
            text    = call_tool.call("tbamud__move", { "direction" => direction })
            outcome = hooks.reconcile_move!(direction: direction, text: text)

            unless outcome && outcome[:ok]
              # A death is its own stop, and a distinguishable one: the walk did
              # not fail to move, it moved somewhere that must not be walked on
              # from. `note_death` has already dropped position, so continuing
              # would dead-reckon from a room the agent is no longer in.
              reason = outcome && outcome[:died] ? "you died" : "move failed (#{direction})"
              # `i + 1`, not `i`: the direction that was refused is not
              # "remaining", it is answered. A caller that re-walked it would
              # re-walk the wall.
              return stopped(completed, steps, i + 1, reason)
            end

            completed << { direction: direction, room_name: outcome[:room_name], room_id: outcome[:room_id] }
            next if i == steps.size - 1 # the next before_model call polls for us

            poll_text   = call_tool.call("tbamud__poll", {})
            tier, line  = EventClassifier.classify(poll_text)
            return stopped(completed, steps, i + 1, line) if tier == :interrupting
          end

          { completed: completed, stopped: nil, remaining: [] }
        end

        def stopped(completed, steps, next_index, reason)
          { completed: completed, stopped: reason, remaining: Array(steps[next_index..]) }
        end

        def render_completed(completed)
          lines = ["[route] executed #{completed.size}/#{completed.size}"]
          completed.each_with_index { |c, i| lines << step_line(i, c) }
          lines << "arrived: #{completed.last[:room_name]}"
          lines.join("\n")
        end

        def render_stopped(result, steps)
          completed = result[:completed]
          lines = ["[route] executed #{completed.size}/#{steps.size} — stopped"]
          completed.each_with_index { |c, i| lines << step_line(i, c) }
          lines << "stopped: #{result[:stopped]}"
          remaining = result[:remaining]
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
