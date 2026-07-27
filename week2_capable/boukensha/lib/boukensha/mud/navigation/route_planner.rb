require_relative "destination_search"
require_relative "../room_parser"

module Boukensha
  module Mud
    module Navigation
      # BFS over the known room graph, plus frontier ranking when the
      # destination is not mapped. See docs/plans/week_2/plan_route.md §5–§6.
      #
      # Every move costs one MUD round trip and none are weighted, so BFS
      # gives the shortest known route without a dependency — Dijkstra would
      # have nothing to do (move_around.md §2). Danger-weighting is a later
      # escalation, gated on `encounters` actually having enough rows to
      # justify it, same as DestinationSearch's FTS5/embeddings escalation.
      module RoutePlanner
        # Every direction a route may ever print, in the MUD's canonical
        # order — derived from RoomParser::DIRECTIONS.values rather than a
        # second independent list, so the state block and a route can never
        # drift onto different spellings (plan_route.md §3.2).
        CANONICAL_DIRECTIONS = RoomParser::DIRECTIONS.values.freeze

        RoutePlan = Data.define(
          :status,             # position_unknown | arrived | known | explore | unknown | unreachable | exhausted
          :query,
          :start_room,
          :destination_room,   # room_id, or nil (explore/unknown/exhausted)
          :steps,               # [{ direction:, from_room_id:, to_room_id: }]
          :frontier,            # { room_id:, direction: } or nil
          :evidence,
          :alternatives         # [{ room_id:, name: }], up to 3
        )

        module_function

        # query:                   free text, e.g. "bakery"
        # current_room_id:         Store#player[:current_room_id], or nil
        # rooms:                   Store#rooms
        # exits:                   Store#all_exits
        # entities_by_room:        Store#entities_by_room
        # frontier_attempt_counts: { [room_id, direction] => failed_count }
        def plan(query:, current_room_id:, rooms:, exits:, entities_by_room: {}, frontier_attempt_counts: {})
          Planner.new(rooms: rooms, exits: exits, entities_by_room: entities_by_room,
                      frontier_attempt_counts: frontier_attempt_counts)
                 .plan(query: query, current_room_id: current_room_id)
        end

        # The algorithm, instantiated per call so the BFS/search results and
        # the room/exit snapshot can live as ivars instead of being re-threaded
        # through every private method as arguments.
        class Planner
          def initialize(rooms:, exits:, entities_by_room: {}, frontier_attempt_counts: {})
            @rooms_by_id      = rooms.each_with_object({}) { |r, h| h[r[:id]] = r }
            @exits_by_room    = exits.group_by { |e| e[:room_id] }
            @linked_by_room   = exits.select { |e| e[:target_room_id] }.group_by { |e| e[:room_id] }
            @frontiers        = exits.reject { |e| e[:target_room_id] }
            @entities_by_room = entities_by_room
            @attempt_counts   = frontier_attempt_counts
          end

          def plan(query:, current_room_id:)
            q = query.to_s.strip
            return empty_plan("position_unknown", q, current_room_id) if current_room_id.nil?

            distances, predecessors = bfs(current_room_id)
            return empty_plan("unknown", q, current_room_id) if q.empty?

            matches = DestinationSearch.search(q, rooms: @rooms_by_id.values,
                                               entities_by_room: @entities_by_room,
                                               exits_by_room: @exits_by_room)
            # plan_route.md §4.3: "known" requires a DECISIVE top score, not
            # just any lexical hit. A name/entity match (tiers 1–4) confidently
            # identifies the room. A generic description/look-candidate
            # mention (tier 5) or an exit's target_name (tier 6) is weaker —
            # exactly the "Market Street mentions shops and food" kind of clue
            # — and belongs to frontier ranking (§6.2 rules 1–3), not to a
            # confident "this room IS the destination" claim. Without this
            # split, any room whose description merely mentions the query
            # would out-rank a genuine unexplored frontier, and rules 2/3 of
            # frontier_rank_key could never fire (their evidence would always
            # already have won here first).
            known_matches = matches.select { |m| m[:tier] <= DestinationSearch::TIER_ENTITY }

            return known_branch(q, current_room_id, known_matches, distances, predecessors) if known_matches.any?

            frontier_branch(q, current_room_id, distances, predecessors)
          end

          private

          # ---------------------------------------------------------------
          # BFS, unit-cost, deterministic: canonical direction order breaks
          # ties among a room's own edges, and predecessor *edges* (not just
          # rooms) reconstruct steps — plan_route.md §5.
          def bfs(start)
            dist = { start => 0 }
            pred = {}
            queue = [start]
            until queue.empty?
              room_id = queue.shift
              outgoing(room_id).each do |edge|
                target = edge[:target_room_id]
                next if dist.key?(target)

                dist[target] = dist[room_id] + 1
                pred[target] = edge
                queue << target
              end
            end
            [dist, pred]
          end

          def outgoing(room_id)
            (@linked_by_room[room_id] || []).sort_by { |e| direction_index(e[:direction]) }
          end

          def path_to(room_id, predecessors)
            steps = []
            cur = room_id
            while (edge = predecessors[cur])
              steps.unshift({ direction: edge[:direction], from_room_id: edge[:room_id], to_room_id: cur })
              cur = edge[:room_id] # room_exits rows key off room_id -> direction: the edge's own source
            end
            steps
          end

          def direction_index(direction)
            i = CANONICAL_DIRECTIONS.index(direction.to_s)
            i.nil? ? CANONICAL_DIRECTIONS.size : i
          end

          # ---------------------------------------------------------------
          # A destination the agent has actually stood in — plan_route.md §4/§5.
          def known_branch(q, current_room_id, matches, distances, predecessors)
            top_tier = matches.first[:tier]
            top      = matches.select { |m| m[:tier] == top_tier }
            primary  = pick_primary(top, distances)
            alternatives = build_alternatives(top, primary)

            if primary[:room_id] == current_room_id
              return RoutePlan.new(status: "arrived", query: q, start_room: current_room_id,
                                    destination_room: current_room_id, steps: [], frontier: nil,
                                    evidence: primary[:evidence], alternatives: alternatives)
            end

            if distances.key?(primary[:room_id])
              RoutePlan.new(status: "known", query: q, start_room: current_room_id,
                            destination_room: primary[:room_id], steps: path_to(primary[:room_id], predecessors),
                            frontier: nil, evidence: primary[:evidence], alternatives: alternatives)
            else
              RoutePlan.new(status: "unreachable", query: q, start_room: current_room_id,
                            destination_room: primary[:room_id], steps: [], frontier: nil,
                            evidence: primary[:evidence], alternatives: alternatives)
            end
          end

          # Ties broken by shortest known distance, then room id — the same
          # rule decides both "which candidate is the answer" and what counts
          # as an alternative (plan_route.md §4.2's tie-break).
          def pick_primary(top, distances)
            top.min_by { |m| [distances[m[:room_id]] || Float::INFINITY, m[:room_id]] }
          end

          def build_alternatives(top, primary)
            others = top.reject { |m| m[:room_id] == primary[:room_id] }
            return [] if others.empty?

            others.first(3).map { |m| { room_id: m[:room_id], name: @rooms_by_id.dig(m[:room_id], :name) } }
          end

          # ---------------------------------------------------------------
          # No decisive known match — rank exploration frontiers, §6.2.
          def frontier_branch(q, current_room_id, distances, predecessors)
            reachable = @frontiers.select { |f| distances.key?(f[:room_id]) }
            return empty_plan("exhausted", q, current_room_id) if reachable.empty?

            room_matches = q.empty? ? [] : DestinationSearch.search(q, rooms: @rooms_by_id.values,
                                                                     entities_by_room: @entities_by_room,
                                                                     exits_by_room: @exits_by_room)
            room_tier = room_matches.each_with_object({}) { |m, h| h[m[:room_id]] ||= m[:tier] }

            best = reachable.min_by { |f| frontier_rank_key(f, q, distances, room_tier) }
            evidence = frontier_evidence(best, q, room_tier)

            status = evidence ? "explore" : "unknown"
            RoutePlan.new(status: status, query: q, start_room: current_room_id, destination_room: nil,
                          steps: path_to(best[:room_id], predecessors),
                          frontier: { room_id: best[:room_id], direction: best[:direction] },
                          evidence: evidence, alternatives: [])
          end

          # Lexicographic: (1) exact/phrase clue in the frontier's own
          # target_name, (2) the frontier's source room's own match tier
          # (covers both "best matching room" and "any room with matching
          # evidence" as one continuum — a lower tier IS a better match),
          # (3) nearest by BFS distance, (4) fewest prior failed attempts,
          # (5) canonical direction order, (6) source room id.
          def frontier_rank_key(frontier, q, distances, room_tier)
            [
              target_name_clue?(frontier, q) ? 0 : 1,
              room_tier[frontier[:room_id]] || Float::INFINITY,
              distances[frontier[:room_id]] || Float::INFINITY,
              @attempt_counts[[frontier[:room_id], frontier[:direction]]] || 0,
              direction_index(frontier[:direction]),
              frontier[:room_id]
            ]
          end

          def target_name_clue?(frontier, q)
            return false if q.empty? || frontier[:target_name].to_s.empty?

            norm = DestinationSearch.normalize(frontier[:target_name])
            norm == q || norm.include?(q) ||
              (DestinationSearch.tokens(frontier[:target_name]) & DestinationSearch.tokens(q)).any?
          end

          def frontier_evidence(frontier, q, room_tier)
            return "#{frontier[:target_name]} (exit name)" if target_name_clue?(frontier, q)

            tier = room_tier[frontier[:room_id]]
            return nil unless tier

            room = @rooms_by_id[frontier[:room_id]]
            "#{room[:name]} (##{room[:id]}) matches the query"
          end

          def empty_plan(status, q, current_room_id)
            RoutePlan.new(status: status, query: q, start_room: current_room_id, destination_room: nil,
                          steps: [], frontier: nil, evidence: nil, alternatives: [])
          end
        end
        private_constant :Planner
      end
    end
  end
end
