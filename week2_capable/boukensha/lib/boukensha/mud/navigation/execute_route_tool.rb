require_relative "../event_classifier"
require_relative "../room_parser"

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

        # Every direction, reversed. Used only to walk back out of a room that
        # could not be read, and it is the one place this module assumes exits
        # are symmetric — an assumption week 2 rejected for map building and
        # which is safe here for a different reason: nothing is recorded from
        # the attempt, so a passage that turns out to be one-way costs one move
        # and reports itself instead of writing a wrong edge.
        #
        # The table itself lives with the rest of the direction vocabulary in
        # `RoomParser`, because a second copy of it would be a second definition
        # of which way is back.
        REVERSE = RoomParser::REVERSE

        # The walk, unrendered — `MoveTo` drives its bounded loop off these
        # fields rather than parsing the text below back out again.
        #
        #   { completed: [{ direction:, room_name:, room_id: }, …],
        #     stopped:      "move failed (up)" | nil,
        #     stopped_kind: :refused | :unreadable | :interrupted | :died |
        #                   :recovered | :recovery_exhausted | :stuck |
        #                   :position_lost | nil,
        #     remaining:    ["east", …] }
        #
        # `stopped` is a sentence rather than a code because every caller says
        # it verbatim. `stopped_kind` is the code, and it exists because the
        # cases are different instructions to whatever is driving the walk: a
        # refusal is a disagreement to re-plan around, an `unreadable` step is
        # one we walked into and back out of and must not take again, an
        # interruption and a death belong to the player, and a lost position
        # must not be planned from at all. Collapsing them into one field is
        # what let a refused first step end a thirty-room survey after four
        # rooms.
        # blind_steps: how many moves the recovery in `back_out` may spend after
        # the reverse step fails. Zero keeps the pre-sweep behaviour, which is what
        # a caller with no budget of its own should get.
        def walk(steps:, call_tool:, hooks:, blind_steps: 0)
          steps     = Array(steps).map(&:to_s)
          completed = []

          steps.each_with_index do |direction, i|
            text    = call_tool.call("tbamud__move", { "direction" => direction })
            outcome = hooks.reconcile_move!(direction: direction, text: text)

            unless outcome && outcome[:ok]
              # `i + 1`, not `i`: the direction that was refused is not
              # "remaining", it is answered. A caller that re-walked it would
              # re-walk the wall.
              return stop_for(outcome, completed, steps, i + 1, direction, call_tool, hooks, blind_steps)
            end

            completed << { direction: direction, room_name: outcome[:room_name], room_id: outcome[:room_id] }
            next if i == steps.size - 1 # the next before_model call polls for us

            poll_text   = call_tool.call("tbamud__poll", {})
            tier, line  = EventClassifier.classify(poll_text)
            return stopped(completed, steps, i + 1, line, kind: :interrupted) if tier == :interrupting
          end

          { completed: completed, stopped: nil, stopped_kind: nil, remaining: [] }
        end

        def stop_for(outcome, completed, steps, next_index, direction, call_tool, hooks, blind_steps)
          case outcome && outcome[:kind]
          when :died
            # A death is its own stop, and a distinguishable one: the walk did
            # not fail to move, it moved somewhere that must not be walked on
            # from. `note_death` has already dropped position, so continuing
            # would dead-reckon from a room the agent is no longer in.
            stopped(completed, steps, next_index, "you died", kind: :died)
          when :position_lost
            back_out(completed, steps, next_index, direction, call_tool, hooks, blind_steps,
                     vitals(outcome[:text]))
          else
            stopped(completed, steps, next_index, "move failed (#{direction})", kind: :refused)
          end
        end

        # We walked somewhere neither the movement reply nor a follow-up `look`
        # could identify, so `Hooks` has dropped its position. The one thing
        # still known for certain is the direction just walked, and walking its
        # reverse costs a single MUD round trip and no model call. It either
        # restores a position the rest of the subsystem can plan from — which is
        # the ordinary outcome, since the agent walked in a moment ago — or it
        # establishes that the passage is one-way, which is worth a move to
        # learn and is reported rather than guessed at.
        def back_out(completed, steps, next_index, direction, call_tool, hooks, blind_steps, moves)
          back = REVERSE[direction.to_s]
          lost = "walked #{direction} into a room that cannot be identified"
          if back.nil?
            return sweep(completed, steps, next_index, lost, [], blind_steps, moves, call_tool, hooks)
          end

          step = blind_step(back, call_tool, hooks, moves)
          if step[:recovered]
            return stopped(completed, steps, next_index,
                           "#{direction} leads somewhere that cannot be identified; stepped back " \
                           "#{back} to #{step[:room_name]}", kind: :unreadable)
          end

          # The reverse was refused, so the character is still where the drop left
          # it and `back` is a direction now known not to work — or it moved and the
          # room beyond is unreadable too, in which case nothing is known about
          # where the character is standing and no direction has been ruled out.
          # The reverse step is not charged to the budget. It is the one direction
          # the subsystem has a reason to try — the agent walked in through it a
          # moment ago — and it happens whether or not a sweep is permitted, so the
          # knob means what it says: moves spent AFTER the way back has failed.
          sweep(completed, steps, next_index, "#{lost}, and #{back} did not lead back out",
                step[:moved] ? [] : [back], blind_steps, step[:moves], call_tool, hooks)
        end

        # The bounded recovery of blind_step_recovery.md §5.5, and the four answers
        # it can give. It runs after the reverse step has failed, costs one MUD round
        # trip per direction and no model calls, and writes nothing to the map —
        # `Hooks` cannot resolve a room it cannot read, and an arrival edge whose
        # origin is unknown is never recorded.
        #
        # `tried` is the directions ruled out FROM WHERE THE CHARACTER NOW STANDS,
        # which is why it empties whenever a step moves: a tried-set carried across a
        # move would describe a path rather than a room, and `stuck` would then be a
        # claim about nowhere.
        def sweep(completed, steps, next_index, lost, tried, budget, moves, call_tool, hooks)
          swept = 0
          loop do
            untried = RoomParser::DIRECTIONS.values - tried
            # PROOF, not a guess: every direction was refused and none of them moved
            # the character, so the room is sealed and no further walking can help.
            # Saying it lets a session end on a conclusion rather than on max_tokens.
            if untried.empty?
              hooks.note_recovery!(:stuck)
              return stopped(completed, steps, next_index,
                             "#{lost}; every direction from here was refused", kind: :stuck)
            end
            # Nothing has been proved — the budget simply ran out. A caller reading
            # this may reasonably sweep again, which is the whole reason it is a
            # different status from `stuck`.
            #
            # A caller that allowed no sweep at all gets `position_lost`, which is
            # what that kind has always meant: the reverse step failed and nothing
            # further was attempted. Reporting an exhausted recovery to a caller that
            # never permitted one would be a claim about work nobody did.
            if budget <= 0
              return stopped(completed, steps, next_index, lost, kind: :position_lost) if swept.zero?

              hooks.note_recovery!(:recovery_exhausted)
              return stopped(completed, steps, next_index,
                             "#{lost}; #{swept} direction#{'s' unless swept == 1} tried without " \
                             "reaching a room that can be identified, #{untried.size} untried",
                             kind: :recovery_exhausted)
            end

            direction = untried.first
            budget   -= 1
            swept    += 1
            step      = blind_step(direction, call_tool, hooks, moves)
            if step[:recovered]
              return stopped(completed, steps, next_index,
                             "#{lost}; walked #{direction} into #{step[:room_name]}", kind: :recovered)
            end

            moves = step[:moves]
            tried = step[:moved] ? [] : tried + [direction]
          end
        end

        # One move made with no idea where it starts from. `recovered` is the only
        # thing `Hooks` can tell us — it either read a room or it did not — so
        # `moved` is read off the movement points in the reply instead.
        #
        # That is the same evidence dark_rooms_and_stuck_walks.md §2 used to
        # establish that the recorded descent was an arrival: a successful move costs
        # one movement point and a refusal costs none. It reads the numeric prompt
        # every state block already reads rather than any wording, so it holds for a
        # message this project has never seen. Regeneration between two commands can
        # mask a spent point, and the cost of that misread is one direction wrongly
        # believed to be a wall.
        def blind_step(direction, call_tool, hooks, moves)
          text    = call_tool.call("tbamud__move", { "direction" => direction })
          outcome = hooks.reconcile_move!(direction: direction, text: text)
          after   = vitals(text) || moves

          { recovered: !!(outcome && outcome[:ok]), room_name: outcome && outcome[:room_name],
            moved: !!(moves && after && after < moves), moves: after }
        end

        def vitals(text) = RoomParser.parse_prompt(text.to_s)&.fetch(:move)

        def stopped(completed, steps, next_index, reason, kind: :interrupted)
          { completed: completed, stopped: reason, stopped_kind: kind,
            remaining: Array(steps[next_index..]) }
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
