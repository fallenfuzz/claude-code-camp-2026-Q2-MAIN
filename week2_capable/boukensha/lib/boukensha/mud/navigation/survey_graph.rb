require "set"
require_relative "route_planner"
require_relative "destination_search"

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

        # The surveyor's guess about what is behind an unwalked exit, or nil. The
        # planner cannot derive this — it can see the exit's name and nothing
        # else — which is precisely why it is annotated rather than computed.
        def hint(frontier) = @hints[[frontier[:room_id], frontier[:direction]]]

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
        def lexical_clue?(frontier, term)
          return false if term.to_s.strip.empty?

          wanted = DestinationSearch.tokens(term)
          return false if wanted.empty?

          text = "#{frontier[:target_name]} #{room_name(frontier[:room_id])}"
          (DestinationSearch.tokens(text) & wanted).any?
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

        def build_frontiers
          paths = frontier_paths
          @exits.select { |e| RoutePlanner.frontier?(e) }
                .select { |e| @distances.key?(e[:room_id]) && in_scope?(e[:room_id]) }
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
