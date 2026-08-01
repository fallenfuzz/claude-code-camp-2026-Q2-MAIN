# The lexical half of exit name resolution, as a pure function — rooms and
# exits in, presumed links out — so every guard can be tested as a hash without
# a database. See docs/plans/week_3/exit_name_resolution.md.
#
# `DestinationSearch` is reached across the layer on purpose. It is dependency
# free, does no I/O and holds no store reference, and its `normalize` is the one
# rule that decides "Grubby's Bakery" and "grubbys bakery" are the same string
# everywhere in this system. A second normalizer here would be a second
# definition of room-name identity, and the two would drift the first time
# either was corrected.
require_relative "../navigation/destination_search"
require_relative "../room_parser"

module Boukensha
  module Mud
    module Memory
      module ExitResolution
        Search = Navigation::DestinationSearch

        module_function

        # rooms:     Store#rooms
        # exits:     Store#all_exits
        # ambiguous: normalised names already known to identify nothing
        #
        # Returns { [room_id, direction] => room_id_or_nil }, one entry for
        # every unlinked exit carrying a target name — nil meaning "this one
        # resolves to nothing, clear any presumption it holds". Exits that
        # already carry an earned `target_room_id` never appear: a walked
        # traversal always supersedes a name match.
        def resolve(rooms:, exits:, ambiguous: [])
          by_name  = rooms.group_by { |r| Search.normalize(r[:name]) }
          poisoned = ambiguous.map { |n| Search.normalize(n) }.to_set
          # Guard three, computed side: a name printed on two or more distinct
          # rooms identifies neither of them. This is derived from the rooms
          # table on every pass rather than only from the persisted set, so the
          # moment a second "Main Street" is discovered every presumption
          # depending on that name stops being made.
          by_name.each { |name, matches| poisoned << name if matches.size > 1 }

          # Guard two: two exits from ONE room naming the same destination. Room
          # 7 of the recorded map has `east → Main Street` and `west → Main
          # Street`, and a rule checking only global uniqueness would link both
          # to whichever room is found first and fuse the two ends of a street
          # into one. That corrupts the graph, which is worse than the sparse
          # graph this change exists to fix.
          collisions = exits.group_by { |e| e[:room_id] }.flat_map do |room_id, group|
            group.map { |e| [room_id, Search.normalize(e[:target_name])] }
                 .tally.select { |(_, name), n| n > 1 && !name.empty? }.keys
          end.to_set

          by_id = rooms.to_h { |r| [r[:id], r] }

          exits.each_with_object({}) do |exit, out|
            next if exit[:target_room_id]

            key  = [exit[:room_id], exit[:direction].to_s]
            name = Search.normalize(exit[:target_name])
            next out[key] = nil if name.empty?

            # The arrival rule, ahead of both ambiguity guards because it is the
            # one case where the evidence is local rather than a global name
            # lookup. See below, and fix_surveying.md §3.4.
            room = by_id[exit[:room_id]]
            if room && arrival_link?(room: room, source: by_id[room[:arrived_from_room_id]],
                                     direction: exit[:direction], target_name: exit[:target_name])
              next out[key] = room[:arrived_from_room_id]
            end

            next out[key] = nil if poisoned.include?(name)
            next out[key] = nil if collisions.include?([exit[:room_id], name])

            match = by_name[name]&.first
            # A room naming itself as the destination of one of its own exits
            # tells the graph nothing BFS does not already know, and a self-edge
            # is the one presumption that can never be settled by walking it.
            out[key] = (match && match[:id] != exit[:room_id]) ? match[:id] : nil
          end
        end

        # The way back, and the one presumption the ambiguity guards do not get a
        # say in.
        #
        # Three rooms in the recorded Midgaard map are called "Wall Road", so the
        # name is poisoned as globally ambiguous and identifies none of them; room
        # #13 has both a north and a south exit carrying it, which is the
        # within-room collision guard. Both guards are right, and between them
        # they left the chain #11 → #12 → #13 → #14 → #15 walkable southward with
        # no northward link at all: BFS from where the run finished reached three
        # rooms out of seventeen, so every destination behind the agent was
        # `unreachable` however well the resolver named it.
        #
        # The evidence for the way back was in the database the whole time.
        # Migration V5 records, per room, which room it was first entered FROM and
        # by which direction, and an exit facing back the way the agent came,
        # labelled with that room's own name, is not a global name lookup at all —
        # it is a statement about one passage the agent walked one move earlier.
        #
        # BOTH conditions are required. The direction alone would assume every
        # passage is two-way, which week 2 rejected and
        # `test_one_way_exits_are_not_reversed` still guards; the name alone is
        # exactly what the guards above correctly refuse.
        #
        # `room[:arrived_from_room_id]` and `arrived_direction` are read off the
        # room rows rather than passed in separately, because `rooms:` is
        # `Store#rooms` and already carries both columns — a second argument
        # holding a copy of them would be a second thing to keep in step.
        def arrival_link?(room:, source:, direction:, target_name:)
          return false unless room && source
          return false unless room[:arrived_from_room_id] == source[:id]
          return false if source[:id] == room[:id]
          return false unless RoomParser::REVERSE[room[:arrived_direction].to_s] == direction.to_s

          name = Search.normalize(target_name)
          !name.empty? && Search.normalize(source[:name]) == name
        end

        # Names that identify more than one room, for seeding the persisted
        # ambiguity set. Kept separate from `resolve` because a caller may want
        # to record the finding as well as act on it.
        def ambiguous_names(rooms:)
          rooms.group_by { |r| Search.normalize(r[:name]) }
               .select { |name, matches| matches.size > 1 && !name.empty? }.keys
        end
      end
    end
  end
end
