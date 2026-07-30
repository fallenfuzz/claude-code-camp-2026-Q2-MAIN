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

          exits.each_with_object({}) do |exit, out|
            next if exit[:target_room_id]

            key  = [exit[:room_id], exit[:direction].to_s]
            name = Search.normalize(exit[:target_name])
            next out[key] = nil if name.empty? || poisoned.include?(name)
            next out[key] = nil if collisions.include?([exit[:room_id], name])

            match = by_name[name]&.first
            # A room naming itself as the destination of one of its own exits
            # tells the graph nothing BFS does not already know, and a self-edge
            # is the one presumption that can never be settled by walking it.
            out[key] = (match && match[:id] != exit[:room_id]) ? match[:id] : nil
          end
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
