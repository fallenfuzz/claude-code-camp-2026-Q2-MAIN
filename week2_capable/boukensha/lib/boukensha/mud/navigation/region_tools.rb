require_relative "../memory/regions"
require_relative "route_planner"

module Boukensha
  module Mud
    module Navigation
      # The two tools that write a region — boundaries_revised.md §2.
      #
      # There are two of them, and the agent has to mean one or the other,
      # because they answer different questions:
      #
      #   name_region   THIS PLACE IS CALLED X. Renames the region you are
      #                 standing in, usually a provisional one, and clears the
      #                 unconfirmed mark. No boundary is created, because no
      #                 boundary moved.
      #   split_region  A DIFFERENT PLACE STARTS IN THIS ROOM. The boundary is
      #                 the edge this room was first entered by, exactly.
      #
      # Zero MUD I/O, exactly like `plan_route`: both take a store and some
      # strings, and there is no seam through which either could reach the MUD.
      # Both refuse when position is unknown, because a declaration is always
      # about the room the agent is standing in and there is nothing honest to
      # write when that room is not established.
      #
      # Every result prints what it actually did — the room count it renamed,
      # the edge it used as a boundary — so §9's two sharp edges are legible in
      # the same turn they are made rather than fifty rooms later.
      module RegionTools
        module_function

        # ---------------------------------------------------------------

        def name_region(store:, region:, within: nil, description: nil)
          label = region.to_s.strip
          return "[region] error: region is required" if label.empty?

          here = store.player[:current_room_id]
          return position_unknown("name_region") unless here

          current = store.region_for_room(here)
          return "[region] error: you are not in a region yet — take one move first" unless current

          existing = store.region_by_label(label)

          if existing && existing[:id] != current[:id]
            store.merge_region!(current[:id], existing[:id])
            target = existing
            merged = current[:label]
          else
            store.update_region!(current[:id], label: label)
            target = store.region(current[:id])
            merged = nil
          end

          parent_id, parent_note = resolve_parent(store, target, within)
          return parent_note if parent_note.is_a?(String) && parent_note.start_with?("[region] error")

          store.update_region!(target[:id], confirmed: true, description: description, parent_id: parent_id)
          render_named(store, store.region(target[:id]), current[:label], merged, parent_note)
        end

        # ---------------------------------------------------------------

        def split_region(store:, region:, within: nil, description: nil, reason: nil)
          label = region.to_s.strip
          return "[region] error: region is required" if label.empty?

          here = store.player[:current_room_id]
          return position_unknown("split_region") unless here

          room = store.room(here)
          from_id   = room && room[:arrived_from_room_id]
          direction = room && room[:arrived_direction]

          # No arrival edge means no boundary. §2's whole claim to exactness is
          # that the line IS the edge the agent walked in on, so inventing one
          # here would give away the only property that makes a split
          # trustworthy. `name_region` is the right tool for a room reached
          # without an edge — it is already a root.
          unless from_id && direction
            return "[region] error: this room has no first-arrival edge (a cold start, a flee, or a " \
                   "teleport landed you here), so there is no edge to make a boundary of. It is already " \
                   "the start of its own region — use name_region to name it."
          end

          existing = store.region_by_label(label)
          before   = store.region_for_room(here)
          region_id =
            if existing
              existing[:id]
            else
              store.create_region!(label: label, confirmed: true, description: description, seed_room_id: here)
            end
          store.update_region!(region_id, confirmed: true, description: description) if existing

          parent_id, parent_note = resolve_parent(store, store.region(region_id), within)
          return parent_note if parent_note.is_a?(String) && parent_note.start_with?("[region] error")

          store.update_region!(region_id, parent_id: parent_id) if parent_id

          store.declare_boundary!(from_room_id: from_id, to_room_id: here, direction: direction,
                                  region_id: region_id, reason: reason)

          render_split(store, store.region(region_id), room, from_id, direction, before)
        end

        # ---------------------------------------------------------------
        # `within:` names the parent by label and CREATES it when it does not
        # exist, which is what makes §5's re-parenting move possible: renaming
        # Midgaard to North Midgaard frees the label, and `within: "Midgaard"`
        # then mints the container the two quarters hang under. A container so
        # created has no seed room and no boundary — it holds regions, not
        # rooms directly.
        def resolve_parent(store, target, within)
          name = within.to_s.strip
          return [nil, nil] if name.empty?
          return [nil, "[region] error: a region cannot be within itself"] if name == target[:label]

          parent = store.region_by_label(name)
          return [store.create_region!(label: name, confirmed: true), "new parent"] unless parent

          # A parent that already sits inside the region being re-parented
          # would make the tree a loop, and every walk over it would have to
          # defend against that forever.
          if store.region_descendants(target[:id]).include?(parent[:id])
            return [nil, "[region] error: #{name.inspect} is already inside #{target[:label].inspect}"]
          end

          [parent[:id], nil]
        end

        def position_unknown(tool)
          "[region] error: #{tool} needs to know which room you are in, and your position has not been " \
            "established yet; take one safe action (e.g. move) first"
        end

        # ---------------------------------------------------------------
        # Rendering. The room count is the loud part on purpose: `53 rooms
        # carry the name` when the agent expected one is §9's second failure
        # mode announcing itself.

        def render_named(store, region, old_label, merged, parent_note)
          lines = ["[region] #{old_label} → #{region[:label]}, confirmed"]
          lines << "merged into the existing #{region[:label]} — #{merged} no longer exists" if merged
          if region[:parent_id]
            lines << "within #{parent_label(store, region)}#{parent_note == 'new parent' ? ' (a new parent)' : ''}"
          end
          lines << carrying_line(store, region)
          lines << "no boundary moved — this renamed the place you were already in"
          lines << shape_line(store, region)
          lines.compact.join("\n")
        end

        def render_split(store, region, room, from_id, direction, before)
          from  = store.room(from_id)
          label = from ? from[:name] : "##{from_id}"
          moved = member_ids(store, region).size
          lines = ["[region] #{region[:label]} — starts here" \
                   "#{region[:parent_id] ? ", within #{parent_label(store, region)}" : ''}"]
          lines << "boundary: #{label} —#{direction}→ #{room[:name]}"
          lines << "          (the edge this room was first entered by; #{label} keeps its region)"
          lines << "#{moved} room#{'s' unless moved == 1} now in #{region[:label]} — this room and everything " \
                   "you first reached through it"
          # The region left behind, then the one just declared: a split is a
          # statement about two places and both counts moved.
          lines << shape_line(store, store.region(before[:id])) if before && before[:id] != region[:id]
          lines << shape_line(store, region)
          lines.compact.join("\n")
        end

        def carrying_line(store, region)
          ids   = member_ids(store, region)
          names = ids.first(3).filter_map { |id| store.room(id)&.[](:name) }
          "#{ids.size} room#{'s' unless ids.size == 1} carry the name: " \
            "#{names.join(', ')}#{ids.size > names.size ? ', …' : ''}"
        end

        def member_ids(store, region)
          store.room_regions.select { |_, m| m[:region_id] == region[:id] }.keys.sort
        end

        def parent_label(store, region)
          store.region(region[:parent_id])&.[](:label) || "?"
        end

        # The same one-line shape `plan_route` prints, so the two tools agree
        # about what a region IS. Nothing branches on any of these numbers.
        def shape_line(store, region)
          return nil unless region

          RegionShape.line(store: store, region: region,
                           distances: RoutePlanner.distances(exits: store.all_exits,
                                                             from: store.player[:current_room_id]))
        end
      end

      # Room count, unexplored exit count, and the nearest / median distance to
      # those exits, on one line — boundaries_revised.md §2 and §5.
      #
      # Both numbers, always, and NOTHING branches on either. §5's argument is
      # that a count threshold would have fired on Journal A′ (12 exits in a
      # dense little town where scope was working perfectly) and been wrong,
      # while the distances are what actually said the scope had stopped
      # narrowing anything. Printing both and deciding nothing is the design.
      module RegionShape
        module_function

        # "Midgaard (66 rooms · 16 unexplored exits · nearest 2 moves, median 8)"
        #
        # `distances` is optional only because a caller may genuinely not have
        # a position to measure from; every caller that has one passes it,
        # since §5's argument turns entirely on the median.
        def line(store:, region:, distances: nil)
          ids   = store.region_descendants(region[:id])
          rooms = store.room_regions.select { |_, m| ids.include?(m[:region_id]) }.keys
          exits = store.all_exits.select { |e| e[:target_room_id].nil? && rooms.include?(e[:room_id]) }
          # Once there is a position to measure from, count only what can
          # actually be reached from it. Otherwise this line says 23 and the
          # listing under it says 11, and the reader has to work out that the
          # difference is an unreachable island — the map really does contain
          # them, and a number nobody can act on is not the shape of where you
          # are standing.
          exits = exits.select { |e| distances.key?(e[:room_id]) } if distances

          bits = ["#{rooms.size} room#{'s' unless rooms.size == 1}",
                  "#{exits.size} unexplored exit#{'s' unless exits.size == 1}"]
          # "0 unexplored exits · no reachable unexplored exit" says the same
          # thing twice; the count has already answered.
          bits << distance_bit(exits, distances) if distances && exits.any?

          parent = store.region(region[:parent_id])
          "#{region[:label]}#{unconfirmed(region)} (#{bits.join(' · ')})" \
            "#{parent ? " — within #{parent[:label]}" : ''}"
        end

        def distance_bit(exits, distances)
          ds = exits.filter_map { |e| distances[e[:room_id]] }.sort
          return "no reachable unexplored exit" if ds.empty?

          "nearest #{ds.first} move#{'s' unless ds.first == 1}, median #{median(ds)}"
        end

        def median(sorted)
          mid = sorted.size / 2
          sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
        end

        # Four words, in the state block and on every region line, asking a
        # question the agent can answer in one call — and gone once it has.
        def unconfirmed(region)
          region[:confirmed].to_i == 1 ? "" : " — unconfirmed"
        end
      end
    end
  end
end
