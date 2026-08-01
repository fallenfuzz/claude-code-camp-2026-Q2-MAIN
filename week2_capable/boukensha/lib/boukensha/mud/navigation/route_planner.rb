require "set"
require_relative "destination_search"
require_relative "assessment"
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
          :alternatives,        # [{ room_id:, name: }], up to 3
          # boundaries_revised.md §2: the whole unexplored set, not one pick.
          # Groups, in distance bands: [{ distance:, room_id:, room_name:,
          # path: [dir], exits: [{ direction:, target_name: }] }]
          :unexplored,
          # { count:, rooms:, min_distance:, max_distance: }, or nil when the
          # whole set is on screen.
          :withheld,
          :unexplored_total,
          # True when at least one step of `steps` crosses a presumed edge — a
          # destination the MUD named that was matched to a room in memory, but
          # that nothing has walked. The route is worth offering (it is the only
          # thing that gets the agent back out of The Dump) and the caller is
          # entitled to know it rests on a name.
          :presumed
        )

        # How many unexplored exits go on screen before the rest are withheld.
        #
        # SOFT, and the softness is the point: a distance BAND is never cut in
        # half, because "the nearest ones are all here" has to be true for the
        # ordering to mean anything at all. The band that crosses this number
        # is shown whole and the listing stops after it, so the figure bounds
        # the output loosely rather than exactly (boundaries_revised.md §2).
        FRONTIER_SOFT_CAP = 6

        module_function

        # query:                   free text, e.g. "bakery"
        # current_room_id:         Store#player[:current_room_id], or nil
        # rooms:                   Store#rooms
        # exits:                   Store#all_exits
        # entities_by_room:        Store#entities_by_room
        # frontier_attempt_counts: { [room_id, direction] => failed_count }
        # regions_by_room:         { room_id => region_id }
        # scope_region_ids:        region ids exploration is confined to, or
        #                          nil for `scope: "world"`
        # frontier_hints:          Store#frontier_hints — what a survey or an
        #                          unreadable walk concluded about the far side of
        #                          an unwalked exit. Empty is the ordinary case for
        #                          travel and means nothing has been concluded.
        def plan(query:, current_room_id:, rooms:, exits:, entities_by_room: {}, frontier_attempt_counts: {},
                 regions_by_room: {}, scope_region_ids: nil, frontier_hints: {})
          Planner.new(rooms: rooms, exits: exits, entities_by_room: entities_by_room,
                      frontier_attempt_counts: frontier_attempt_counts,
                      regions_by_room: regions_by_room, scope_region_ids: scope_region_ids,
                      frontier_hints: frontier_hints)
                 .plan(query: query, current_room_id: current_room_id)
        end

        # Unit-cost BFS over the linked graph, exposed so anything else that
        # needs "how far is every room from here" — the region shape line, for
        # one — asks the same function the routes do rather than growing a
        # second implementation that can disagree with this one.
        def distances(exits:, from:, presumed: true)
          return {} unless from

          linked = traversable(exits, presumed: presumed).group_by { |e| e[:room_id] }
          dist   = { from => 0 }
          queue  = [from]
          until queue.empty?
            room_id = queue.shift
            (linked[room_id] || []).each do |edge|
              target = target_of(edge)
              next if dist.key?(target)

              dist[target] = dist[room_id] + 1
              queue << target
            end
          end
          dist
        end

        # Which rooms are on the same side of the wall as `from` — staying_in_town.md
        # §10.4 and §13.
        #
        # A room is inside the scope of a call that began in `from` when it can be
        # reached from `from` over known exits without traversing an edge somebody
        # recorded as an egress. That is the whole definition, and everything it
        # deliberately does NOT consult is the point of it: no region label, no
        # region ancestry, no room name. §8 of that document is why — read as
        # containment, the region tree is actively misleading. On the run this was
        # written for, `The Plains` came out a descendant of `The Temple`, its
        # parent moved between two splits twelve iterations apart, the region
        # actually named `Midgaard` held no rooms at all, and five countryside
        # rooms shared a region with the temple interior. An edge the walker
        # recorded at the moment it crossed cannot be moved by a later relabelling.
        #
        # UNDIRECTED, like `SurveyGraph#undirected` and for the same reason: this
        # asks about shape rather than about routing, and a room reached through a
        # one-way drop is still on the side of the wall it landed on. Routing
        # still uses the directed graph, so nothing here produces a walk the agent
        # cannot make.
        #
        # blocked: [[room_a, room_b], …] as unordered pairs — Store#egress_edges.
        def reachable_within(exits:, from:, blocked: [])
          return Set.new unless from

          barrier = blocked.map { |pair| pair.sort }.to_set
          adjacent = Hash.new { |h, k| h[k] = [] }
          traversable(exits).each do |edge|
            to = target_of(edge)
            adjacent[edge[:room_id]] << to
            adjacent[to] << edge[:room_id]
          end

          seen  = Set.new([from])
          queue = [from]
          until queue.empty?
            room_id = queue.shift
            adjacent[room_id].each do |neighbour|
              next if barrier.include?([room_id, neighbour].sort)
              next unless seen.add?(neighbour)

              queue << neighbour
            end
          end
          seen
        end

        # Exits BFS may walk. Earned edges always; presumed ones — an exit whose
        # MUD-reported destination name resolved to a room already in memory —
        # only when the caller wants them, and always ranked after earned edges
        # so a route made entirely of walked steps beats a shorter one leaning on
        # a guess. See docs/plans/week_3/exit_name_resolution.md.
        def traversable(exits, presumed: true)
          exits.select { |e| e[:target_room_id] || (presumed && e[:presumed_target_id]) }
        end

        def target_of(exit) = exit[:target_room_id] || exit[:presumed_target_id]

        def presumed?(exit) = exit[:target_room_id].nil? && !exit[:presumed_target_id].nil?

        # An exit is a FRONTIER only when nobody knows what is behind it AND
        # walking it stands to tell us. An exit the MUD has named as a room the
        # agent has stood in is not exploration, and counting it as one is what
        # inflated the recorded Midgaard map's frontier set by a third with
        # rooms that needed no exploring.
        #
        # An OPAQUE exit fails the second half. It has already been walked and
        # the destination could not be read even with a follow-up `look`, so the
        # move on offer is one whose outcome is known in advance to be no
        # information. Leaving it in the set is what let a survey pick the same
        # trapdoor twice.
        def frontier?(exit)
          exit[:target_room_id].nil? && exit[:presumed_target_id].nil? && !opaque?(exit)
        end

        def opaque?(exit) = exit[:opaque].to_i.positive?

        # The algorithm, instantiated per call so the BFS/search results and
        # the room/exit snapshot can live as ivars instead of being re-threaded
        # through every private method as arguments.
        class Planner
          def initialize(rooms:, exits:, entities_by_room: {}, frontier_attempt_counts: {},
                         regions_by_room: {}, scope_region_ids: nil, frontier_hints: {})
            @rooms_by_id      = rooms.each_with_object({}) { |r, h| h[r[:id]] = r }
            @exits_by_room    = exits.group_by { |e| e[:room_id] }
            @linked_by_room   = RoutePlanner.traversable(exits).group_by { |e| e[:room_id] }
            # Exits with a presumed target are no longer frontier: something
            # already knows what is behind them. Removing them is what deletes
            # the phantom third of the recorded map's frontier set.
            @frontiers        = exits.select { |e| RoutePlanner.frontier?(e) }
            @entities_by_room = entities_by_room
            @attempt_counts   = frontier_attempt_counts
            @region_of        = regions_by_room
            # nil means `scope: "world"` — no constraint at all, as distinct
            # from an empty array, which would constrain to nothing.
            @scope_ids        = scope_region_ids
            @assessments      = frontier_hints || {}
          end

          def plan(query:, current_room_id:)
            q = query.to_s.strip
            return empty_plan("position_unknown", q, current_room_id) if current_room_id.nil?

            distances, predecessors = bfs(current_room_id)
            # Kept as an ivar as well as a local: `region_hops` needs to walk
            # the same tree the steps are reconstructed from, several layers
            # below the call that computed it.
            @predecessors = predecessors
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

            if known_matches.any? && !door_answers_better?(q, known_matches, distances)
              return known_branch(q, current_room_id, known_matches, distances, predecessors)
            end

            frontier_branch(q, current_room_id, distances, predecessors)
          end

          # Two different questions hide inside "where is the place the agent
          # named", and the ranked list above collapses them into one:
          #
          #   Which room that I have stood in is this?  Answered from CONTENT —
          #   name, description, entities — the same kind of evidence
          #   `Memory::Fingerprint` uses to answer "have I been here before".
          #
          #   Which door leads to the place named?  Answered from POSITION, and
          #   the answer is a frontier rather than a destination, because the place
          #   has never been entered and nothing is known about it except where
          #   it is.
          #
          # Collapsing them is what let a room matching on one shared word bury an
          # exit labelled with the query exactly. §3.1 makes that particular
          # collision impossible, and this states the rule directly rather than
          # leaving it as a consequence of where the tier boundaries fall: an
          # exact or phrase match on a room's own NAME still wins, because a place
          # the agent has stood in is better known than a label on a closed door.
          #
          # In scope, because what is being proposed is exploration, and an
          # out-of-scope door is not an answer this branch is allowed to give.
          def door_answers_better?(q, known_matches, distances)
            return false if known_matches.any? { |m| m[:tier] <= DestinationSearch::TIER_NAME_PHRASE }

            norm = DestinationSearch.normalize(q)
            @frontiers.any? do |f|
              distances.key?(f[:room_id]) && in_scope?(f[:room_id]) &&
                DestinationSearch.normalize(f[:target_name]) == norm
            end
          end

          private

          # ---------------------------------------------------------------
          # Shortest known route, deterministic: canonical direction order
          # breaks ties among a room's own edges, and predecessor *edges* (not
          # just rooms) reconstruct steps — plan_route.md §5.
          #
          # It was a plain unit-cost BFS until presumed edges existed. It is now
          # a two-key search, and the keys are lexicographic: how many PRESUMED
          # edges the route crosses first, hops second. That ordering is the
          # whole of exit_name_resolution.md's "ranked strictly after earned
          # ones" — a nine-step route over walked edges beats a two-step route
          # resting on a name the agent has never tested, and among routes of
          # equal presumption the shorter still wins.
          #
          # A scan for the minimum rather than a heap: this runs over rooms the
          # agent has personally stood in, which is dozens, and a dependency-free
          # loop anyone can read is worth more here than an asymptote.
          def bfs(start)
            cost    = { start => [0, 0] }
            pred    = {}
            settled = {}
            loop do
              room_id, here = cost.reject { |id, _| settled[id] }.min_by { |id, c| [c, id] }
              break unless room_id

              settled[room_id] = true
              outgoing(room_id).each do |edge|
                target = RoutePlanner.target_of(edge)
                step   = RoutePlanner.presumed?(edge) ? [here[0] + 1, here[1] + 1] : [here[0], here[1] + 1]
                next if cost[target] && (cost[target] <=> step) <= 0

                cost[target] = step
                pred[target] = edge
              end
            end
            # Every caller of this map means hops when it says distance. The
            # presumption count has done its work by ordering the search and does
            # not belong in an answer about how far away something is.
            [cost.transform_values { |c| c[1] }, pred]
          end

          def outgoing(room_id)
            (@linked_by_room[room_id] || []).sort_by { |e| direction_index(e[:direction]) }
          end

          def path_to(room_id, predecessors)
            steps = []
            cur = room_id
            while (edge = predecessors[cur])
              steps.unshift({ direction: edge[:direction], from_room_id: edge[:room_id], to_room_id: cur,
                              presumed: RoutePlanner.presumed?(edge) })
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
              return plan_row("arrived", q, current_room_id,
                              destination_room: current_room_id,
                              evidence: primary[:evidence], alternatives: alternatives)
            end

            if distances.key?(primary[:room_id])
              plan_row("known", q, current_room_id,
                       destination_room: primary[:room_id],
                       steps: path_to(primary[:room_id], predecessors),
                       evidence: primary[:evidence], alternatives: alternatives)
            else
              # The refusal carries the frontier too. Everything needed for it
              # was computed above and thrown away: this branch used to return
              # `unexplored: []` and `unexplored_total: 0` while holding the BFS
              # distances and the whole frontier set, so the answer stated a fact
              # about a room the agent could not reach and named nothing it could
              # do instead. That is what made it repeatable — the ninth refusal
              # was byte-identical to the first, and there was no reason inside it
              # to expect the tenth to differ (§3.3).
              shown, withheld, total = unexplored_for(distances, predecessors)
              plan_row("unreachable", q, current_room_id,
                       destination_room: primary[:room_id],
                       evidence: primary[:evidence], alternatives: alternatives,
                       unexplored: shown, withheld: withheld, unexplored_total: total)
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
            if reachable.empty?
              # Computed the same way as every other answer's listing rather than
              # hard-coded empty, which is what says out loud that this status
              # means the set IS empty: `exhausted` is precisely "no reachable
              # exploration frontier", so there is nothing for the view to hold
              # and the renderer prints nothing extra.
              shown, withheld, total = unexplored_for(distances, predecessors)
              return plan_row("exhausted", q, current_room_id,
                              unexplored: shown, withheld: withheld, unexplored_total: total)
            end

            # Scope constrains EXPLORATION and never travel: `known_branch` has
            # already returned by this point, so a destination the agent has
            # stood in is routed to across any number of boundaries. What is
            # narrowed here is only where to look for something not on the map.
            in_scope = reachable.select { |f| in_scope?(f[:room_id]) }
            if in_scope.empty?
              # Every remaining door leaves the region. This is a QUESTION, not
              # a wall — it carries the widening call as text and the agent can
              # simply make it (§2). It is also not the mechanism the design is
              # betting on: Journal B′ widens on MEANING, with twelve doors
              # still open in town, and this status only fires when the
              # arithmetic happens to agree.
              return plan_row("region_exhausted", q, current_room_id, unexplored_total: reachable.size)
            end
            reachable = in_scope

            room_matches = q.empty? ? [] : DestinationSearch.search(q, rooms: @rooms_by_id.values,
                                                                     entities_by_room: @entities_by_room,
                                                                     exits_by_room: @exits_by_room)
            room_tier = room_matches.each_with_object({}) { |m, h| h[m[:room_id]] ||= m[:tier] }

            best = pick_frontier(reachable, q, distances, room_tier)
            evidence = frontier_evidence(best, q, room_tier)
            shown, withheld = unexplored_view(reachable, distances, predecessors)

            status = evidence ? "explore" : "unknown"
            plan_row(status, q, current_room_id,
                     steps: path_to(best[:room_id], predecessors),
                     frontier: { room_id: best[:room_id], direction: best[:direction] },
                     evidence: evidence,
                     unexplored: shown, withheld: withheld, unexplored_total: reachable.size)
          end

          # ---------------------------------------------------------------
          # The whole reachable frontier, grouped by (distance, room) and cut
          # only on a band boundary — boundaries_revised.md §2. Returns the
          # groups to show and a summary of the ones held back, and the ONLY
          # judgement in it is arithmetic: nothing here reads a name.
          #
          # `path` rides on each group because a frontier the agent cannot
          # walk to is not a choice it can make, and the whole point of
          # listing more than one is that the choice is the agent's.
          # The listing as the answers that are NOT the explore branch need it:
          # every reachable in-scope frontier, banded, plus the total. Scope is
          # applied here for the same reason it is applied there — what is being
          # offered is somewhere to explore — so an answer given under
          # `scope: "region"` never lists a door out of the region as the remedy.
          def unexplored_for(distances, predecessors)
            reachable = @frontiers.select { |f| distances.key?(f[:room_id]) && in_scope?(f[:room_id]) }
            shown, withheld = unexplored_view(reachable, distances, predecessors)
            [shown, withheld, reachable.size]
          end

          def unexplored_view(reachable, distances, predecessors)
            groups = reachable
                     .group_by { |f| f[:room_id] }
                     .map { |room_id, fs| build_group(room_id, fs, distances, predecessors) }
                     .sort_by { |g| [g[:distance], g[:room_id]] }

            shown = []
            count = 0
            groups.chunk_while { |a, b| a[:distance] == b[:distance] }.each do |band|
              break if !shown.empty? && count >= FRONTIER_SOFT_CAP

              shown.concat(band)
              count += band.sum { |g| g[:exits].size }
            end

            held = groups - shown
            [shown, held.empty? ? nil : withheld_summary(held)]
          end

          def build_group(room_id, frontiers, distances, predecessors)
            {
              distance:  distances[room_id],
              room_id:   room_id,
              room_name: @rooms_by_id.dig(room_id, :name),
              path:      path_to(room_id, predecessors).map { |s| s[:direction] },
              exits:     frontiers.sort_by { |f| direction_index(f[:direction]) }
                                  .map { |f| { direction: f[:direction], target_name: f[:target_name] } }
            }
          end

          def withheld_summary(held)
            distances = held.map { |g| g[:distance] }
            { count: held.sum { |g| g[:exits].size }, rooms: held.size,
              min_distance: distances.min, max_distance: distances.max }
          end

          # Which frontier to recommend, once the ranking above has said how good
          # each one is. The same rule the survey applies in `ClaimPlanner#eligible`
          # — a door whose far side nobody can assess is not walked while a door
          # that can be assessed is still open (blind_step_recovery.md §5.3).
          #
          # A frontier the QUERY names is the travel-mode form of "the objective
          # justifies it", and it competes regardless of assessment, because an
          # agent asking for a place by name and being shown the exit labelled with
          # that name is the whole point of the frontier branch.
          #
          # Travel has no surveyor, so almost every exit here is `unknown` and the
          # tiering is inert — which is deliberate. The exits it does demote are the
          # ones a survey has assessed or a walk has proven unreadable, and for
          # those, travel has a stronger reason to avoid them than a survey does: a
          # route toward a named destination gains nothing from a door that pays no
          # information.
          def pick_frontier(reachable, q, distances, room_tier)
            by_tier = reachable.group_by { |f| Assessment.tier(assessment_of(f)) }
            best    = by_tier.keys.min
            pool    = by_tier[best] +
                      reachable.select { |f| Assessment.tier(assessment_of(f)) > best && target_name_clue?(f, q) }
            pool.min_by { |f| frontier_rank_key(f, q, distances, room_tier) }
          end

          def assessment_of(frontier)
            @assessments.dig([frontier[:room_id], frontier[:direction].to_s], :assessability)
          end

          # Lexicographic: (1) exact/phrase clue in the frontier's own
          # target_name, (2) the frontier's source room's own match tier
          # (covers both "best matching room" and "any room with matching
          # evidence" as one continuum — a lower tier IS a better match),
          # (3) region hops, (4) nearest by BFS distance, (5) fewest prior
          # failed attempts, (6) canonical direction order, (7) source room id.
          #
          # Term 3 is the only one boundaries_revised.md adds, and it sits
          # AHEAD of raw distance deliberately: three moves without leaving
          # town should beat one move out of the gate. No other term changes.
          def frontier_rank_key(frontier, q, distances, room_tier)
            [
              target_name_clue?(frontier, q) ? 0 : 1,
              room_tier[frontier[:room_id]] || Float::INFINITY,
              region_hops(frontier[:room_id], distances),
              distances[frontier[:room_id]] || Float::INFINITY,
              @attempt_counts[[frontier[:room_id], frontier[:direction]]] || 0,
              # Behind every term that carries meaning and ahead of the two that are
              # only there for determinism: a hazard somebody recorded separates two
              # otherwise identical doors and never outweighs a clue or a distance.
              Assessment.hazard_rank(@assessments.dig([frontier[:room_id], frontier[:direction].to_s], :hazard)),
              direction_index(frontier[:direction]),
              frontier[:room_id]
            ]
          end

          # How many region changes the shortest known walk to this room passes
          # through, computed off the BFS tree the route itself is built from.
          #
          # It measures the walk to the frontier's SOURCE room, not what lies
          # beyond the exit, because what lies beyond an unexplored exit is
          # precisely what nobody knows — claiming otherwise would be the sort
          # of guess §7 rules out.
          def region_hops(room_id, distances)
            return 0 unless distances.key?(room_id)

            @hops ||= {}
            @hops[room_id] ||= path_to(room_id, @predecessors)
                               .count { |s| @region_of[s[:from_room_id]] != @region_of[s[:to_room_id]] }
          end

          def in_scope?(room_id)
            return true if @scope_ids.nil?

            @scope_ids.include?(@region_of[room_id])
          end

          # The same content-word rule `DestinationSearch` applies, applied here
          # too. This function was written against the same data with the same
          # bug the search had already been corrected for, and never picked the
          # correction up: raw token overlap made "the" a clue, so for the query
          # "The South Gate" three of the four exits reachable from the concourse
          # tied at the top rank and canonical direction order sent the agent
          # east — past the exit actually named "The South Gate". The stall
          # survived all the way to the ranking function (§3.1).
          #
          # The substring arm goes for the reason the phrase tier lost its: it
          # ignores word boundaries, and an exit named "The Northwest End Of The
          # Concourse" is not a clue about west.
          def target_name_clue?(frontier, q)
            return false if q.empty? || frontier[:target_name].to_s.empty?

            norm = DestinationSearch.normalize(frontier[:target_name])
            return true if norm == q

            shared = (DestinationSearch.tokens(frontier[:target_name]) & DestinationSearch.tokens(q)) -
                     DestinationSearch::STOPWORDS
            shared.any?
          end

          def frontier_evidence(frontier, q, room_tier)
            return "#{frontier[:target_name]} (exit name)" if target_name_clue?(frontier, q)

            tier = room_tier[frontier[:room_id]]
            return nil unless tier

            room = @rooms_by_id[frontier[:room_id]]
            "#{room[:name]} (##{room[:id]}) matches the query"
          end

          def empty_plan(status, q, current_room_id)
            plan_row(status, q, current_room_id)
          end

          # One construction site for a Data with eleven members, so adding a
          # twelfth does not mean editing five call sites and missing one.
          def plan_row(status, q, current_room_id, destination_room: nil, steps: [], frontier: nil,
                       evidence: nil, alternatives: [], unexplored: [], withheld: nil, unexplored_total: 0)
            RoutePlan.new(status: status, query: q, start_room: current_room_id,
                          destination_room: destination_room, steps: steps, frontier: frontier,
                          evidence: evidence, alternatives: alternatives,
                          unexplored: unexplored, withheld: withheld, unexplored_total: unexplored_total,
                          # Derived rather than passed: every construction site
                          # would otherwise have to remember to compute it, and
                          # the one that forgot would silently claim a walked
                          # route it had not earned.
                          presumed: steps.any? { |s| s[:presumed] })
          end
        end
        private_constant :Planner
      end
    end
  end
end
