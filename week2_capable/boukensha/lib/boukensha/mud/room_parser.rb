require "set"

module Boukensha
  module Mud
    # Text in, struct out. Nothing else.
    #
    # This is the parsing half of what used to be `Tools::InspectRoom`. Losing
    # the `call_tool:` constructor argument is the point of the split, not a
    # side effect of it: a parser that only parses has no round trips to fake,
    # so every test below it is a string in and a struct out. The sequencing
    # half — the poll/look/exits/consider/examine round trips — moved to
    # Mud::RoomSurvey, and the session-lifetime keyword cache moved to the
    # `entities` table, where it survives process exit.
    #
    # Purity is load-bearing for a second reason: `after_tool` runs this over
    # every movement result, in the hot path of the agent loop, and must never
    # be able to spend a MUD round trip of its own.
    class RoomParser
      # tbaMUD colours the two entity lists differently, verified in
      # src/act.informative.c: list_obj_to_char() wraps ground objects in
      # CCGRN, list_char_to_char() wraps mobs in CCYEL. look_at_room() also
      # paints the ROOM NAME with CCYEL — same code as mobs — but it is the
      # first line, so position disambiguates it.
      YELLOW = "\e[0;33m".freeze   # mobs (and the room name)
      GREEN  = "\e[0;32m".freeze   # ground objects
      RESET  = "\e[0m".freeze
      ANSI   = /\e\[[0-9;]*m/.freeze

      EXITS_LINE  = /^\[ Exits:(.*)\]$/.freeze
      # HP goes NEGATIVE below zero — "-6H 100M 84V >" is tbaMUD saying you are
      # mortally wounded and dying. That prompt is the single most important
      # line the agent can be shown, so the `-?` is not defensive padding: an
      # anchored /^\d+H/ silently drops exactly the reading that matters most.
      PROMPT_LINE = /^-?\d+H -?\d+M -?\d+V/.freeze
      STATS       = /(-?\d+)H (-?\d+)M (-?\d+)V/.freeze

      # "north - By The Temple Altar"
      EXIT_TARGET = /^(\w+)\s+-\s+(.+)$/.freeze

      # The autoexit line abbreviates; `check(exits)` and the movement tool both
      # spell directions out. Everything downstream — room_exits.direction, the
      # fingerprint, the turn policy — uses the long form, so normalise here and
      # nowhere else.
      DIRECTIONS = {
        "n" => "north", "s" => "south", "e" => "east", "w" => "west",
        "u" => "up",    "d" => "down",
        "ne" => "northeast", "nw" => "northwest",
        "se" => "southeast", "sw" => "southwest"
      }.freeze

      # Where a mob's long description stops being its name. "A beastly fido IS
      # mucking…", "A cityguard STANDS here." Everything before the verb is the
      # noun phrase we can guess a keyword from.
      VERB = /\b(?:is|are|was|were|has|have|had|stands?|sits?|lies?|rests?|sleeps?|
                 hangs?|leans?|waits?|guards?|paces?|walks?|blocks?|kneels?|floats?)\b/x.freeze

      ARTICLES = %w[a an the some].to_set

      # tbaMUD's answer when a keyword doesn't match anything in the room.
      NOT_HERE = /aren't here|isn't here|no one here|nothing here/i.freeze

      # What one `look` (or one movement result, which has the same shape) says.
      #
      # `complete` is the whole reason this is a struct and not a hash: §6.2's
      # movement substitution is a whitelist on the success shape, and a caller
      # must not have to re-derive "did this actually look like a room?" from
      # three separate nil checks.
      Look = Struct.new(
        :name, :description, :mob_lines, :object_lines,
        :hp, :mana, :move, :exit_dirs, :uncoloured, :has_exits_line, :has_prompt,
        keyword_init: true
      ) do
        # A room description we are willing to act on: it named a room, it
        # printed an exits line, and it ended in a prompt. Anything less is a
        # refusal, an error, or output we have never seen — never a room.
        def complete? = has_exits_line && has_prompt && !name.to_s.empty?
      end

      class << self
        # The room name, the prose, the exit directions, the entity lines after
        # `[ Exits: ]`, and the prompt stats — all in one pass.
        def parse_look(text)
          raw      = text.to_s.split(/\r?\n/)
          coloured = raw.map { |l| [l, colour_of(l)] }
          stripped = raw.map { |l| strip(l) }

          exits_at  = stripped.index { |l| l =~ EXITS_LINE }
          exit_dirs = exits_at ? parse_exit_dirs(stripped[exits_at]) : []
          name      = stripped.find { |l| !l.empty? } || ""
          body      = exits_at ? stripped[(stripped.index(name) + 1)...exits_at] : []

          entities = exits_at ? coloured[(exits_at + 1)..] || [] : []
          mob_lines, object_lines, uncoloured = classify(entities)

          prompt = stripped.find { |l| l =~ PROMPT_LINE }
          stats  = prompt&.match(STATS)

          Look.new(
            name:           name,
            description:    body.map(&:strip).reject(&:empty?).join(" ").squeeze(" "),
            mob_lines:      mob_lines,
            object_lines:   object_lines,
            hp:             stats && stats[1].to_i,
            mana:           stats && stats[2].to_i,
            move:           stats && stats[3].to_i,
            exit_dirs:      exit_dirs,
            uncoloured:     uncoloured,
            has_exits_line: !exits_at.nil?,
            has_prompt:     !prompt.nil?
          )
        end

        # "Obvious exits:" then "direction - Destination" per line. The
        # `[ Exits: n e s w ]` line in `look` gives directions only, never
        # destinations, so this second call is load-bearing rather than
        # redundant.
        def parse_exits(text)
          lines(text).each_with_object({}) do |line, out|
            next if line =~ PROMPT_LINE || line.start_with?("Obvious exits")

            m = line.match(EXIT_TARGET) or next
            out[m[1].downcase] = m[2].strip
          end
        end

        # "The cityguard is in excellent condition." plus anything after
        # "is using:".
        def parse_examine(text)
          rows      = lines(text)
          health    = rows.find { |l| l =~ /is in (.+?) condition/ }&.match(/is in (.+?) condition/)&.captures&.first
          using     = rows.index { |l| l =~ /is using:/ }
          equipment = using ? rows[(using + 1)..].reject { |l| l =~ PROMPT_LINE } : []
          { health: health && "#{health} condition", equipment: equipment }
        end

        # The prompt line rides on EVERY MUD response, which makes it the one
        # free reading in the whole design: `after_tool` scrapes it off whatever
        # the model just called and player HP tracking costs nothing.
        # Returns nil when the text carries no prompt at all.
        # The LAST prompt, not the first: a single `poll` can carry a whole
        # fight ("0H …" then "-6H …"), and only the final line is the state the
        # agent is actually in.
        def parse_prompt(text)
          line = lines(text).select { |l| l =~ PROMPT_LINE }.last or return nil
          m    = line.match(STATS) or return nil
          { hp: m[1].to_i, mana: m[2].to_i, move: m[3].to_i }
        end

        # tbaMUD's `score`. Every field is optional and independently matched:
        # the prompt line already covers hp/mana/move, so this exists only for
        # level/gold/exp, and a MUD that words one line differently must not
        # cost us the other two.
        def parse_score(text)
          s = strip(text.to_s)
          {
            level: s[/\(level (\d+)\)/, 1]&.to_i,
            exp:   s[/scored (\d+) exp/, 1]&.to_i,
            gold:  s[/(\d+) gold coins/, 1]&.to_i,
            max_hp: s[/(\d+)\((\d+)\) hit/, 2]&.to_i
          }.compact
        end

        # Keyword guesses, best first: the nouns of the leading noun phrase,
        # read right to left. "A beastly fido is mucking…" -> ["fido",
        # "beastly"]; "An automatic teller machine has been…" -> ["machine",
        # "teller", "automatic"]. The first guess is usually right and the
        # caller verifies the rest against the MUD rather than trusting this.
        def guess_keywords(line)
          phrase = strip(line).split(VERB).first.to_s
          phrase.scan(/[A-Za-z]+/)
                .map(&:downcase)
                .reject { |w| ARTICLES.include?(w) }
                .reverse
        end

        def lines(text) = text.to_s.split(/\r?\n/).map { |l| strip(l).strip }.reject(&:empty?)

        def strip(line) = line.to_s.gsub(ANSI, "").delete("\r")

        # "[ Exits: n e s w d ]" -> ["north", "east", "south", "west", "down"],
        # in the MUD's own order. Tokens we don't recognise are kept verbatim
        # rather than dropped: an unknown direction we cannot walk is a smaller
        # error than a known exit we forgot exists.
        def parse_exit_dirs(line)
          inner = line.to_s[EXITS_LINE, 1].to_s
          inner.split(/\s+/).reject(&:empty?).map { |tok| DIRECTIONS[tok.downcase] || tok.downcase }
        end

        # The colour a line's text is actually printed in — the LAST non-reset
        # code in its leading run of escapes. tbaMUD does not emit one code per
        # line: the reset that closes entity N lands at the start of the line
        # carrying entity N+1 ("\e[0m\e[0;33mA beastly fido…"), so reading the
        # first code finds the reset and every entity after the first looks
        # uncoloured.
        def colour_of(line)
          leading = line.to_s[/\A(?:\e\[[0-9;]*m)+/] or return nil
          leading.scan(ANSI).reject { |c| c == RESET }.last
        end

        # Split the post-exits lines into mobs and objects, deduping identical
        # lines (three fidos are one appraisal). Colour is the signal; if the
        # character's `color` toggle is off there are no codes at all.
        #
        # Returns [mobs, objects, uncoloured_count]. The parser REPORTS the
        # uncoloured count rather than warning about it: a wrong mob/object
        # split used to cost one bad JSON field, but the `entities` table is
        # world-level, so a mis-kinded row is now wrong in every room at once.
        # Store refuses to write entities when this is non-zero (§11), and the
        # survey is what puts the warning on the operator's screen.
        def classify(entities)
          mobs       = Hash.new(0)
          objects    = Hash.new(0)
          uncoloured = 0

          entities.each do |raw, colour|
            line = strip(raw).strip
            next if line.empty? || line =~ PROMPT_LINE

            case colour
            when GREEN  then objects[line] += 1
            when YELLOW then mobs[line] += 1
            else
              uncoloured += 1
              # Positional fallback: tbaMUD prints objects before mobs, but with
              # no colour we cannot tell where the boundary is. Mobs is the safer
              # bucket — a wrong `consider` costs one round trip and answers
              # "They aren't here", where a missed mob silently drops a threat.
              mobs[line] += 1
            end
          end

          [mobs, objects, uncoloured]
        end
      end
    end
  end
end
