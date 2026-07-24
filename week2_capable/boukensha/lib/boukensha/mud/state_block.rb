require_relative "room_parser"

module Boukensha
  module Mud
    # What the model is shown about where it is.
    #
    # This is not the room record. The record is five tables; this is four lines,
    # and the gap between them is the point — the model does not need the room's
    # first_seen_at, its fingerprints, or its prose for the fourth time.
    #
    #   [here] Market Square  (visit 2)
    #   exits: n→The Temple Square ✓ | e→Main Street ✓ | s→The Common Square ✓ | w→Main Street ?
    #   here: a cityguard (mob — "you could take him")
    #   you: 20/20hp 100mana 81mv · lvl 1 · 43 gold · standing
    #
    # Measured against what it replaces: the old `inspect_room` payload was ~230
    # tokens and PERMANENT (a tool_result, re-sent on every later call, once per
    # visit). This is ~45 tokens, transient, and there is only ever one copy.
    module StateBlock
      HEADER = "[here]".freeze

      module_function

      # `room`      — the rooms row (Hash), or nil if we genuinely don't know.
      # `exits`     — room_exits rows, in display order.
      # `here`      — live entity lines: [{ desc:, count:, kind:, threat:, threat_fresh:, encounters: }]
      # `player`    — the player_state row.
      # `events`    — lines from this iteration's poll. Rendered only if non-empty.
      # `first_visit` — send the prose once, and never again.
      # `candidates`  — look_candidates, only while the room is unexamined.
      # `ambiguity`   — how many rooms this could be, when it is more than one.
      def render(room:, exits: [], here: [], player: {}, events: [], first_visit: false,
                 candidates: nil, ambiguity: nil)
        return nil if room.nil? && player.to_h.empty? && events.empty?

        lines = []
        lines << location_line(room, ambiguity)
        lines << "  #{room[:description]}" if first_visit && room && !room[:description].to_s.empty?
        lines << exits_line(exits) if exits && !exits.empty?
        lines << here_line(here)   if here  && !here.empty?
        lines << candidates_line(candidates) if candidates && !candidates.empty?
        lines << you_line(player)  if player && !player.to_h.empty?
        lines << events_line(events) if events && !events.empty?
        lines.compact.join("\n")
      end

      def location_line(room, ambiguity)
        return "#{HEADER} (unknown — no room established yet)" if room.nil?

        parts = ["#{HEADER} #{room[:name]}"]
        visits = room[:visit_count].to_i
        parts << "(visit #{visits})" if visits > 1
        # A model told its location is ambiguous can act sensibly — walk a step
        # and look again. A model told a confident lie cannot.
        parts << "(uncertain — #{ambiguity} candidates)" if ambiguity.to_i > 1
        parts.join("  ")
      end

      # The one glyph that is genuinely new information: `✓` is a destination the
      # agent has stood in, `?` is the exploration frontier. Today it cannot tell
      # "east, which I've mapped" from "east, unknown" at all.
      def exits_line(exits)
        rendered = exits.map do |e|
          dir  = short(e[:direction])
          name = e[:target_name]
          mark = e[:target_room_id] ? "✓" : "?"
          name ? "#{dir}→#{name} #{mark}" : "#{dir} #{mark}"
        end
        "exits: #{rendered.join(' | ')}"
      end

      # From the LIVE parse plus the latest poll — never from entity_sightings.
      # Rendering presence from stored sightings would report the cityguard that
      # "The cityguard leaves east" just removed, which is the single worst
      # failure mode this design can have. The store contributes only judgement:
      # the remembered threat, and only while it was measured at the level the
      # player is still on.
      def here_line(here)
        rendered = here.map do |e|
          bits = []
          bits << e[:kind] if e[:kind]
          bits << "\"#{e[:threat]}\"" if e[:threat] && e[:threat_fresh]
          bits << "threat unknown at this level" if e[:threat] && !e[:threat_fresh]
          bits << e[:encounters] if e[:encounters]
          label = e[:count].to_i > 1 ? "#{e[:desc]} ×#{e[:count]}" : e[:desc]
          bits.empty? ? label : "#{label} (#{bits.join(' — ')})"
        end
        "here: #{rendered.join(' | ')}"
      end

      def candidates_line(candidates)
        "worth a look: #{Array(candidates).join(', ')}"
      end

      # Vitals cluster (they are read together and change together); everything
      # slower-moving is separated out.
      def you_line(p)
        vitals = []
        vitals << (p[:max_hp] ? "#{p[:hp]}/#{p[:max_hp]}hp" : "#{p[:hp]}hp") if p[:hp]
        vitals << "#{p[:mana]}mana" if p[:mana]
        vitals << "#{p[:move]}mv"   if p[:move]

        bits = []
        bits << vitals.join(" ") unless vitals.empty?
        bits << "lvl #{p[:level]}" if p[:level]
        bits << "#{p[:gold]} gold" if p[:gold]
        bits << p[:position] if p[:position]
        bits.empty? ? nil : "you: #{bits.join(' · ')}"
      end

      # True for one instant, so they ride in the block for exactly the iteration
      # they happened in and are never written to a table the agent later reads
      # as fact.
      def events_line(events)
        "just now: #{Array(events).join(' ')}"
      end

      # Back to the MUD's own abbreviations, so the exits line here reads the
      # same as the `[ Exits: n e s w ]` line the agent sees everywhere else.
      # A direction we don't recognise renders in full rather than being
      # truncated into something that looks like a different one.
      SHORT = RoomParser::DIRECTIONS.each_with_object({}) { |(abbr, full), h| h[full] = abbr }.freeze

      def short(direction)
        SHORT[direction.to_s] || direction.to_s
      end
    end
  end
end
