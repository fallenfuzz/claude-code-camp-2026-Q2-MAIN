require "set"
require_relative "route_planner"
require_relative "destination_search"
require_relative "assessment"
require_relative "egress"

module Boukensha
  module Mud
    module Navigation
      # One immutable read of everything the claim predicates reason over,
      # computed once per scoring pass — docs/plans/week_3/movement_revisited/claims.md.
      #
      # It exists because the predicates ask structural questions that are
      # expensive to answer and cheap to answer once: which frontiers are
      # reachable and how far, which rooms belong to which feature chain, and
      # which rooms sit behind an articulation point. Nine predicates each
      # recomputing that per candidate would turn a scoring pass into a
      # quadratic one, and worse, two of them could disagree.
      #
      # Everything here is arithmetic over the remembered graph. Nothing in this
      # file reads a room description or asks what a name means; that is the
      # surveyor's job, and the division is the point of the design.
      class SurveyGraph
        # How much a frontier is discounted for sitting behind an articulation
        # point — a room the whole cluster hangs off, like room 3 of the recorded
        # Midgaard map, through which rooms 4, 5 and 6 are the only way in or
        # out. A survey seeking breadth should not spend three legs inside one
        # inn, and this is the signal that says so WITHOUT reading a name.
        #
        # It is a discount and not a veto, because a single-entrance cluster is
        # sometimes exactly what a survey wants — a `region_distinct` claim about
        # a quarter scores those frontiers up, and 0.35 lets it win.
        CLUSTER_DISCOUNT = 0.35

        attr_reader :here, :rooms, :exits, :distances, :frontiers, :hints,
                    :feature_rooms, :scope_room_ids

        # store:           Memory::Store
        # here:            current room id
        # scope_room_ids:  rooms the survey is confined to, or nil for no limit
        def self.build(store:, here:, scope_room_ids: nil, region_id: nil)
          exits = store.all_exits
          new(
            here: here,
            rooms: store.rooms,
            exits: exits,
            distances: RoutePlanner.distances(exits: exits, from: here),
            hints: store.frontier_hints,
            feature_rooms: store.feature_rooms(region_id: region_id),
            scope_room_ids: scope_room_ids
          )
        end

        def initialize(here:, rooms:, exits:, distances:, hints: {}, feature_rooms: {}, scope_room_ids: nil)
          @here           = here
          @rooms          = rooms
          @rooms_by_id    = rooms.to_h { |r| [r[:id], r] }
          @exits          = exits
          @distances      = distances
          @hints          = hints
          @feature_rooms  = feature_rooms.transform_values { |ids| Set.new(ids) }
          @scope_room_ids = scope_room_ids && Set.new(scope_room_ids)
          @frontiers      = build_frontiers
        end

        def room(id) = @rooms_by_id[id]

        def room_name(id) = @rooms_by_id.dig(id, :name)

        # Rooms the survey counts as "here". A survey of Midgaard that wandered
        # into the fields would be answering a different question from the one it
        # was asked.
        def in_scope?(room_id)
          @scope_room_ids.nil? || @scope_room_ids.include?(room_id)
        end

        def room_count = @scope_room_ids ? @scope_room_ids.size : @rooms.size

        # Everything the surveyor annotated an unwalked exit with. The planner
        # cannot derive any of it — it can see the exit's name and nothing else —
        # which is precisely why these are answered rather than computed.
        #
        # `hint` is the expected CLASS and is what every predicate that reads a
        # hint reads. The other two are the questions blind_step_recovery.md §5.1
        # adds, asked for by name so that a predicate cannot accidentally compare a
        # class against an assessability.
        def hint(frontier) = hint_row(frontier)[:expected_class]

        def assessability(frontier) = Assessment.assessability(hint_row(frontier)[:assessability])

        def hazard(frontier) = hint_row(frontier)[:hazard]

        # The fourth question — staying_in_town.md §10.1. Silence reads as
        # `interior`, so a map nobody has annotated is unaffected by any of this.
        def egress(frontier) = Egress.egress(hint_row(frontier)[:egress])

        def leaves?(frontier) = Egress.leaves?(hint_row(frontier)[:egress])

        # Worst tier last. Callers walk the best non-empty tier rather than mixing
        # them, which is what keeps a frontier nobody can assess out of the running
        # while an assessable one is still open, without making it unreachable
        # outright (§5.3).
        def assessment_tier(frontier) = Assessment.tier(hint_row(frontier)[:assessability])

        def hazard_rank(frontier) = Assessment.hazard_rank(hint_row(frontier)[:hazard])

        def feature(slug) = @feature_rooms[slug.to_s] || Set.new

        # Rooms of `slug` with fewer than two neighbours also in `slug`: the ENDS
        # of a chain. `circuit_closes` and `connects` both want to push at an end
        # rather than re-walk the middle, and this is what "the unexplored end of
        # the longest feature chain" reduces to once the chain is a set of rooms
        # and a graph.
        def feature_chain_ends(slug)
          members = feature(slug)
          members.select { |id| (undirected[id] || Set.new).count { |n| members.include?(n) } < 2 }.to_set
        end

        # Does the feature's own subgraph contain a cycle? That is
        # `circuit_closes`, exactly: a feature-tagged room reachable from itself
        # through other feature-tagged rooms means the road came back round.
        def feature_cycle?(slug)
          members = feature(slug)
          return false if members.size < 3

          seen   = Set.new
          # A cycle exists in a connected component when it holds more edges than
          # a tree would. Counting components and edges is cheaper and far
          # clearer than a depth-first back-edge hunt, and the answer is the same.
          edges = members.sum { |id| (undirected[id] || Set.new).count { |n| members.include?(n) } } / 2
          components = 0
          members.each do |id|
            next if seen.include?(id)

            components += 1
            stack = [id]
            until stack.empty?
              cur = stack.pop
              next unless seen.add?(cur)

              (undirected[cur] || Set.new).each { |n| stack << n if members.include?(n) && !seen.include?(n) }
            end
          end
          edges > members.size - components
        end

        # Rooms with exactly one way in from where the agent is standing: the
        # inside of a single-entrance cluster. Computed by removing each room in
        # turn and asking what falls out of the component holding `here`, which
        # is an articulation-point search written the way the question is asked.
        def behind_articulation
          @behind_articulation ||= begin
            out = Set.new
            if @here
              @rooms_by_id.each_key do |cut|
                next if cut == @here

                reachable = component_from(@here, without: cut)
                @rooms_by_id.each_key do |id|
                  out << id if id != cut && !reachable.include?(id)
                end
              end
            end
            out
          end
        end

        def cluster_discount(room_id)
          behind_articulation.include?(room_id) ? CLUSTER_DISCOUNT : 1.0
        end

        # Does this frontier's own name, or the name of the room it leaves from,
        # lexically clue `term`? The weakest signal any predicate uses, and it is
        # used only as a tie-break behind a surveyor hint — the recorded map is
        # the standing argument for why: "The Reception" and "The Post Office"
        # share no vocabulary with "The Entrance Hall Of The Grunting Boar Inn",
        # and what relates those rooms is adjacency, not naming.
        # Content words only. Without the `STOPWORDS` subtraction this shared the
        # defect fix_surveying.md §3.1 corrected in `DestinationSearch` and
        # `RoutePlanner`: any class label containing a function word was clued by
        # any exit name containing the same one, so `Too dark to tell.` was a clue
        # about anything with `to` in it.
        def lexical_clue?(frontier, term)
          wanted = DestinationSearch.tokens(term) - DestinationSearch::STOPWORDS
          return false if wanted.empty?

          text = "#{frontier[:target_name]} #{room_name(frontier[:room_id])}"
          ((DestinationSearch.tokens(text) & wanted) - DestinationSearch::STOPWORDS).any?
        end

        # Undirected adjacency over traversable edges. Undirected on purpose and
        # only here: "is this room part of the same chain" and "does this cluster
        # hang off one entrance" are questions about shape, where direction is
        # noise. Routing still uses the directed graph, so nothing about this
        # produces a walk the agent cannot make.
        def undirected
          @undirected ||= RoutePlanner.traversable(@exits).each_with_object({}) do |e, adj|
            to = RoutePlanner.target_of(e)
            (adj[e[:room_id]] ||= Set.new) << to
            (adj[to] ||= Set.new) << e[:room_id]
          end
        end

        private

        EMPTY_HINT = {}.freeze
        private_constant :EMPTY_HINT

        def hint_row(frontier) = @hints[[frontier[:room_id], frontier[:direction]]] || EMPTY_HINT

        # A `leaves` frontier is EXCLUDED under region scope rather than
        # discounted — staying_in_town.md §9 and §10.2, and the difference
        # matters. Deferral would let it be taken once everything better drained,
        # and a room walked past the wall cannot be un-walked: §8 shows the system
        # cannot reconstruct afterwards which side of the wall a room is on, so
        # the result is not a recoverable mistake but a permanently mislabelled
        # fixture. An exit the surveyor has said leaves Midgaard is not a lead of
        # last resort for a survey of Midgaard, and the honest answer to having no
        # in-scope leads is to say so — which `Survey` does, as `region_exhausted`,
        # with the `scope: "world"` call that would proceed anyway.
        #
        # Under `scope: "world"` — `@scope_room_ids` nil — the exclusion does not
        # apply at all, which is what keeps `find_hermit_mapped` and any deliberate
        # expedition working exactly as before.
        #
        # Note which end of the exit each test reads. `in_scope?` filters the
        # SOURCE room, because that is all it can filter: a frontier is by
        # definition an exit whose far side has never been entered, so the target
        # has no id and no region. That is why scope alone could never prevent the
        # step that leaves (§3.4), and why this second test — asked of a name,
        # answered by a reasoner — is the one that can.
        def build_frontiers
          paths = frontier_paths
          @exits.select { |e| RoutePlanner.frontier?(e) }
                .select { |e| @distances.key?(e[:room_id]) && in_scope?(e[:room_id]) }
                .reject { |e| @scope_room_ids && leaves?({ room_id: e[:room_id], direction: e[:direction].to_s }) }
                .map do |e|
                  { room_id: e[:room_id], direction: e[:direction].to_s, target_name: e[:target_name],
                    room_name: room_name(e[:room_id]), distance: @distances[e[:room_id]],
                    path: paths[e[:room_id]] || [] }
                end
                .sort_by { |f| [f[:distance], f[:room_id], f[:direction]] }
        end

        # The walk to each frontier's source room. Rebuilt here rather than taken
        # from `RoutePlanner.plan`, because a survey plans against no destination
        # at all and that entry point requires one.
        def frontier_paths
          return {} unless @here

          linked = RoutePlanner.traversable(@exits).group_by { |e| e[:room_id] }
          paths  = { @here => [] }
          queue  = [@here]
          until queue.empty?
            id = queue.shift
            (linked[id] || []).sort_by { |e| RoutePlanner::CANONICAL_DIRECTIONS.index(e[:direction].to_s) || 99 }
                              .each do |e|
              to = RoutePlanner.target_of(e)
              next if paths.key?(to)

              paths[to] = paths[id] + [e[:direction].to_s]
              queue << to
            end
          end
          paths
        end

        def component_from(start, without:)
          seen  = Set.new
          stack = [start]
          until stack.empty?
            id = stack.pop
            next if id == without || !seen.add?(id)

            (undirected[id] || Set.new).each { |n| stack << n unless n == without || seen.include?(n) }
          end
          seen
        end
      end
    end
  end
end
