require_relative "hooks"
require_relative "room_parser"

module Boukensha
  module Mud
    # A minimal-weight verdict on what a poll returned, for `execute_route` to
    # decide whether to stop a batched walk early. move_around.md §5's finding:
    # every event the model is shown today arrives with the same weight —
    # "you are hungry" and "the creepy crawler is attacking you" are both just
    # `just now: ...` — and nothing tells a route-follower that one of them
    # should abort the route.
    #
    # Deliberately simple, per the user's own decision: reuse the regexes
    # `Mud::Hooks` already owns (DEATH/VICTORY/FLED/DEPARTURE/LEVEL_UP) rather
    # than duplicate them, plus one new combat-hit pattern. No state, no
    # HP-diffing — that would re-implement what Hooks already tracks.
    module EventClassifier
      # A blow landing on or by the player. Not tbaMUD engine source (not
      # vendored in this repo — the standing rule is to read it, not guess
      # CircleMUD behaviour) but the actual captured poll lines in
      # move_around.md §5: "The creepy crawler misses a wild punch at you." /
      # "You barely pierce the creepy crawler."
      COMBAT_HIT = /\b(?:misses?|hits?|bites?|claws?|punches?|slashes?|pierces?)\b.*\byou\b|
                    \byou\b.*\b(?:miss(?:es)?|hit|bite|claw|punch|slash|pierce)/ix.freeze

      # Worth aborting a batched route for — a fight, a death, a flee.
      INTERRUPTING = [Hooks::DEATH, Hooks::VICTORY, Hooks::FLED, COMBAT_HIT].freeze

      # Worth knowing about, not worth stopping for.
      NOTABLE = [Hooks::ARRIVAL, Hooks::DEPARTURE, Hooks::LEVEL_UP].freeze

      class << self
        # Returns [:interrupting, :notable, :informational, :none], plus the
        # matched line (nil for :none). Takes the MOST SEVERE tier over every
        # line in `text` — one interrupting line among ten informational ones
        # still means stop.
        def classify(text)
          lines = event_lines(text)
          return [:none, nil] if lines.empty?

          hit = lines.find { |l| INTERRUPTING.any? { |re| l =~ re } }
          return [:interrupting, hit] if hit

          hit = lines.find { |l| NOTABLE.any? { |re| l =~ re } }
          return [:notable, hit] if hit

          [:informational, lines.first]
        end

        def interrupting?(text) = classify(text).first == :interrupting

        private

        def event_lines(text)
          RoomParser.lines(text).reject { |l| l =~ RoomParser::PROMPT_LINE }
        end
      end
    end
  end
end
