require "digest"

module Boukensha
  module Mud
    module Memory
      # "Have I been here before?" — the question the MUD refuses to answer.
      #
      # Two fingerprints, because their inputs cost different amounts:
      #
      #   weak   = sha256(name | normalized description | sorted exit dirs)
      #   strong = sha256(weak | sorted "dir>target_name" pairs)
      #
      # `weak` is FREE. Every `look`, and every movement result, carries the
      # name, the prose and `[ Exits: n e s w ]`. Computable on arrival at zero
      # round trips, which is what makes the revisit fast path possible at all.
      #
      # `strong` COSTS a `check(exits)` — the call that turns `n e s w` into
      # `north - By The Temple Altar`. We already spend it once per new room, so
      # it is free for rooms we surveyed and simply unavailable for a room we
      # have only glanced at from a movement result.
      #
      # `strong` is dramatically more discriminating, because the destination
      # NAMES of a room's neighbours are exactly what differs between two rooms
      # that look identical. Two `Dark Alley`s with the same prose and the same
      # n/s exits separate the moment you learn one leads to `Market Square` and
      # the other to `The Slums`.
      #
      # Neither is an identity. Identity is `rooms.id` (§4.2) — see the schema's
      # note on why neither column is UNIQUE.
      module Fingerprint
        module_function

        def weak(name:, description:, exit_dirs:)
          Digest::SHA256.hexdigest(
            [normalize(name), normalize(description), Array(exit_dirs).map(&:to_s).sort.join(",")].join("|")
          )
        end

        # `exit_targets` is { "north" => "By The Temple Altar", ... }. Sorted by
        # direction so the hash does not depend on the order tbaMUD happened to
        # print them in.
        def strong(weak_fingerprint, exit_targets)
          pairs = (exit_targets || {}).map { |dir, target| "#{dir.to_s.downcase}>#{normalize(target)}" }.sort
          Digest::SHA256.hexdigest([weak_fingerprint, pairs.join(",")].join("|"))
        end

        # Room prose is wrapped by the MUD at whatever width the client
        # negotiated, so the line breaks are a property of the connection, not
        # of the room. Collapse them, and case with them.
        def normalize(text)
          text.to_s.downcase.gsub(/\s+/, " ").strip
        end
      end
    end
  end
end
