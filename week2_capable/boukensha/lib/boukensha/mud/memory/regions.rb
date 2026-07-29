module Boukensha
  module Mud
    module Memory
      # Which region each room belongs to — boundaries_revised.md §2.
      #
      # Every room the agent has stood in belongs to a region, from the first
      # turn, and there is no unassigned state. Membership derives from three
      # rules and nothing else:
      #
      #   1. A room takes the region of the room it was FIRST entered from.
      #      Free, no tool call, happens on every arrival.
      #   2. A declaration is a ROOT that overrides inheritance for that room,
      #      and everything downstream re-derives — so declaring late still
      #      fixes the rooms reached *through* the declared room.
      #   3. A room reached with no arrival edge — after `flee`, a teleport, or
      #      a cold session start — keeps its region if it already has one, and
      #      otherwise seeds a provisional region named after the seed room
      #      verbatim and marked unconfirmed.
      #
      # There is no classifier here, and there is deliberately no word list of
      # any kind: nothing in this file reads a room name, a description, a
      # terrain, or a movement cost. It walks first-arrival edges and copies
      # labels. Every judgement about what a place IS was made by the model,
      # somewhere else, and recorded as a declaration.
      #
      # Determinism obligations match RoutePlanner's, because both are read by
      # an agent that has to be able to repeat its own reasoning: room id
      # orders everything, no SQL row order is relied on without an ORDER BY,
      # and the walk is a forest by construction (a room's arrival parent is
      # always an OLDER room, set once at discovery) with a visited guard
      # anyway.
      module Regions
        # A machine-made label. The brackets are the whole message: this is
        # provenance rather than a claim, and it disappears the moment the
        # agent answers the question the `unconfirmed` tag is asking.
        def self.provisional_label(room_name) = "⟨from #{room_name}⟩"

        PROVISIONAL = /\A⟨from .+⟩(?: #\d+)?\z/.freeze

        def self.provisional_label?(label) = PROVISIONAL.match?(label.to_s)

        # rooms:      [{ id:, name:, arrived_from_room_id:, arrived_direction: }]
        # regions:    [{ id:, seed_room_id: }]
        # boundaries: [{ to_room_id:, region_id: }]
        #
        # Returns [memberships, seeds]:
        #   memberships — [{ room_id:, region_id:, basis: }] for every room
        #                 that resolves, in room id order
        #   seeds       — [{ room_id:, label: }] for root rooms that have no
        #                 region yet and need a provisional one minted
        #
        # Deriving the seeds rather than writing them is what keeps this
        # function pure: the caller mints the rows, then calls again, and the
        # second pass has nothing left to seed.
        def self.derive(rooms:, regions:, boundaries:)
          by_id  = rooms.each_with_object({}) { |r, h| h[r[:id]] = r }
          roots  = root_map(regions, boundaries)
          labels = rooms.each_with_object({}) { |r, h| h[r[:id]] = provisional_label(r[:name]) }

          seeds = by_id.keys.sort
                       .select { |id| by_id[id][:arrived_from_room_id].nil? && !roots.key?(id) }
                       .map { |id| { room_id: id, label: unique_label(labels[id], id, labels.values) } }

          memo = {}
          memberships = by_id.keys.sort.filter_map do |id|
            region_id, basis = resolve(id, by_id, roots, memo)
            region_id && { room_id: id, region_id: region_id, basis: basis }
          end

          [memberships, seeds]
        end

        # A room is a root if a boundary starts a region AT it, or if it is a
        # region's seed room. Both are declarations; the boundary wins on the
        # room it names, because it is the more specific of the two.
        def self.root_map(regions, boundaries)
          roots = {}
          regions.sort_by { |r| r[:id] }.each do |r|
            roots[r[:seed_room_id]] = r[:id] if r[:seed_room_id]
          end
          boundaries.sort_by { |b| b[:id].to_i }.each do |b|
            roots[b[:to_room_id]] = b[:region_id]
          end
          roots
        end

        # Walk up first-arrival edges to the nearest root ancestor. Memoized,
        # so a few hundred rooms cost a few hundred steps rather than the
        # depth-squared a naive walk would.
        #
        # A room whose chain reaches no root at all resolves to nothing and is
        # simply left out of the membership table. That cannot happen once the
        # caller has minted the seeds this same pass reported — and if it does,
        # a missing row is a visible bug, where a guessed row would be an
        # invisible one.
        def self.resolve(room_id, by_id, roots, memo)
          chain = []
          cur   = room_id
          seen  = {}
          answer = nil

          while cur && !seen[cur]
            if memo.key?(cur)
              answer = memo[cur]
              break
            end
            if roots.key?(cur)
              answer = [roots[cur], cur == room_id ? "declared" : "inherited"]
              memo[cur] = [roots[cur], "declared"]
              break
            end
            seen[cur] = true
            chain << cur
            cur = by_id.dig(cur, :arrived_from_room_id)
          end

          region_id = answer && answer.first
          chain.each { |id| memo[id] = [region_id, "inherited"] } if region_id
          return [nil, nil] unless region_id

          [region_id, chain.empty? ? answer.last : "inherited"]
        end

        # Two rooms can share a name, and `regions.label` is UNIQUE. The id
        # suffix is added only on a real collision, so the common case reads
        # exactly as §2 prints it.
        def self.unique_label(label, room_id, all_labels)
          all_labels.count(label) > 1 ? "#{label} ##{room_id}" : label
        end

        private_class_method :root_map, :resolve, :unique_label
      end
    end
  end
end
