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

      # Every direction, reversed. It lives beside `DIRECTIONS` because this is
      # already where the direction vocabulary is defined — `RoutePlanner`
      # derives its canonical order from the table above rather than keeping a
      # second list, for the same reason.
      #
      # A reverse direction is NOT an assumption that passages are two-way.
      # Nothing here links anything; the callers each supply their own evidence
      # that the way back is the way it came (`ExecuteRouteTool` walks it and
      # records nothing, `Memory::ExitResolution` requires the arrival edge and
      # the destination name to agree).
      REVERSE = {
        "north" => "south", "south" => "north", "east" => "west", "west" => "east",
        "up" => "down", "down" => "up",
        "northeast" => "southwest", "southwest" => "northeast",
        "northwest" => "southeast", "southeast" => "northwest"
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

        # tbaMUD's `score`. Every field is optional and independently matched,
        # because a MUD that words one line differently must not cost us the
        # others — that contract is why this stays a bag of optional regexes
        # rather than one template, and it is what let the sheet be widened
        # here without touching the fields that already worked.
        #
        # Every pattern below is anchored on a string this build actually
        # emits (test/fixtures/player/score.txt), not on what a stock CircleMUD
        # `score` "should" say:
        #
        #   You are 17 years old.  It's your birthday today.
        #   You have 19(88) hit, 100(162) mana and 83(94) movement points.
        #   Your armor class is 94/10, and your alignment is 0.
        #   You have 450000 exp, 5000 gold coins, and 0 questpoints.
        #   You need 225000 exp to reach your next level.
        #   This ranks you as Derrano the Minister (level 10).
        #   You are standing.
        #
        # Two of those lines are the reason this method was rewritten. The exp
        # regex used to be /scored (\d+) exp/ and this build says "You have N
        # exp", so the score sheet's own exp never landed; and the `N(M)` maxes
        # for mana/move exist nowhere else in the protocol — the prompt line
        # carries the currents and throws the denominators away.
        def parse_score(text)
          s    = strip(text.to_s)
          rows = lines(text)
          hit  = s.match(/(-?\d+)\((\d+)\) hit/)
          mana = s.match(/(-?\d+)\((\d+)\) mana/)
          move = s.match(/(-?\d+)\((\d+)\) movement/)

          {
            level:       s[/\(level (\d+)\)/, 1]&.to_i,
            # "have" and "scored" both anchor it, and the anchor is load-bearing:
            # "You need 225000 exp to reach your next level" is on the very next
            # line and an unanchored /(\d+) exp/ reads the wrong number.
            exp:         s[/(?:have|scored)\s+(\d+)\s+exp\b/, 1]&.to_i,
            exp_to_next: s[/need\s+(\d+)\s+exp/, 1]&.to_i,
            gold:        s[/(\d+) gold coins/, 1]&.to_i,
            hp:          hit && hit[1].to_i,
            max_hp:      hit && hit[2].to_i,
            mana:        mana && mana[1].to_i,
            max_mana:    mana && mana[2].to_i,
            move:        move && move[1].to_i,
            max_move:    move && move[2].to_i,
            # Verbatim, because "94/10" is two numbers (armour and the spell
            # component of it) and splitting them is a guess about which is
            # which. The monitor renders what the MUD printed.
            armor_class: s[/armor class is (\S+?),/, 1],
            alignment:   s[/alignment is (-?\d+)/, 1]&.to_i,
            age_years:   s[/You are (\d+) years old/, 1]&.to_i,
            title:       s[/ranks you as (.+?) \(level \d+\)/, 1],
            position:    position_of(rows),
            conditions:  conditions_of(rows)
          }.compact
        end

        # `inventory`. tbaMUD collapses duplicates onto one line and pads the
        # count, so the real bytes are "( 2) a bottle" — the space inside the
        # parens is not a typo and an /^\(\d+\)/ misses every stacked item.
        #
        # An empty pack is "  Nothing." under the header, NOT the
        # "You are not carrying anything." a stock CircleMUD prints; both are
        # accepted, and both parse to `[]`, which is a valid snapshot rather
        # than a failure. Text with no header at all is also `[]` — a refusal
        # must never be mistaken for an empty bag by the caller, which is why
        # the hook checks the header itself before replacing the snapshot.
        # Whether a response IS a pack/gear listing at all. `parse_inventory`
        # answers `[]` both for an empty pack and for "Huh?!?", and those two
        # must never be confused by a caller about to REPLACE a snapshot: the
        # first is a real reading, the second would wipe the bag on the strength
        # of a refusal. So the distinction lives here, in one predicate each,
        # rather than as a regex the hook re-invents.
        CARRYING = /^You are carrying:|^You are not carrying anything\./.freeze
        USING    = /^You are using:|^You are not using anything\./.freeze

        def carrying?(text) = lines(text).any? { |l| l =~ CARRYING }
        def using?(text)    = lines(text).any? { |l| l =~ USING }

        def parse_inventory(text)
          body = section(text, /^You are carrying:/) or return []

          body.filter_map do |line|
            next if line =~ /^Nothing\.$/i

            m = line.match(/^\(\s*(\d+)\)\s*(.+)$/)
            descr    = m ? m[2].strip : line
            quantity = m ? m[1].to_i : 1
            next if descr.empty?

            { descr: descr, quantity: quantity, keyword: guess_keywords(descr).first }
          end
        end

        # `equipment`. "<worn on body>       a leather jacket" — the angle
        # bracket is the slot, everything after it is the item.
        def parse_equipment(text)
          body = section(text, /^You are using:/) or return []

          body.filter_map { |line| worn_line(line) }
        end

        # `practice`. The listing AND the sessions counter, because they arrive
        # in the same response and the counter lives nowhere else:
        #
        #   You have 30 practice sessions remaining.
        #   You know of the following spells:
        #   armor                 (good)
        #   bless                 (not learned)
        #
        # Ground truth corrected the plan twice here. This build lists at any
        # location — there is no guildmaster gate to work around — and
        # proficiency is a WORD, never a percent. So it is stored verbatim and
        # the only derived field is `learned`, which is the MUD's own
        # "(not learned)" and not an invented ranking of the grades above it.
        def parse_practice(text)
          s      = strip(text.to_s)
          header = s[/You know of the following (spells|skills)/, 1]
          {
            practices_left: s[/(\d+) practice sessions? remaining/, 1]&.to_i,
            kind:           header && (header == "spells" ? "spell" : "skill"),
            skills:         parse_skills(text)
          }.compact
        end

        # The listing half of `practice`, on its own. Unrecognised text — a
        # refusal, an error, output we have never seen — is `[]`, never a raise.
        def parse_skills(text)
          body = section(text, /You know of the following (?:spells|skills)/) or return []

          body.filter_map do |line|
            # Two-or-more spaces is the column gutter; a skill name may itself
            # contain single spaces ("protection from evil", "cure light").
            m = line.match(/^(.+?)\s{2,}\((.+)\)$/) or next
            grade = m[2].strip
            { name: m[1].strip, proficiency: grade, learned: !grade.match?(/^not learned$/i) }
          end
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

        # The lines a listing owns: everything after its header, up to the
        # prompt that closes every MUD response. nil — not [] — when the header
        # is absent, so a caller can tell "the MUD listed nothing" from "this is
        # not a listing at all". Replacing an item snapshot on the strength of a
        # refusal is exactly the fabricated-empty-bag the doctrine forbids.
        def section(text, header)
          rows = lines(text)
          at   = rows.index { |l| l =~ header } or return nil

          rows[(at + 1)..].to_a.take_while { |l| l !~ PROMPT_LINE }
        end

        # "<worn on body>       a leather jacket" -> the slot and the item.
        # Shared with a MOB's `is using:` block, which prints the same shape —
        # a slot with no item after it (the cityguard fixture) yields a row with
        # a nil descr rather than nothing, because "this slot is filled" is
        # itself the reading.
        def worn_line(line)
          m = line.match(/^<([^>]+)>\s*(.*)$/) or return nil
          descr = m[2].strip
          { worn_on: m[1].strip, descr: (descr.empty? ? nil : descr),
            keyword: (descr.empty? ? nil : guess_keywords(descr).first) }
        end

        # tbaMUD's `score` ends with the position on its own line. Matched
        # against a closed list rather than /^You are (\w+)\.$/, because "You
        # are 17 years old." is also a "You are …" line and would win.
        POSITIONS = %w[standing sitting resting sleeping fighting floating
                       stunned incapacitated dead].freeze

        def position_of(rows)
          rows.each do |line|
            m = line.match(/^You are ([a-z ]+)\.$/) or next
            return m[1] if POSITIONS.include?(m[1])
          end
          nil
        end

        # "You are hungry." / "You are thirsty." collapsed to "hungry,thirsty".
        # Low-cardinality and always short, so one joined column beats a table.
        # Only hungry and thirsty are proven captures for this build; `drunk` is
        # listed because matching a line the MUD may emit costs nothing and
        # inventing a VALUE is the thing the doctrine forbids, not a wider regex.
        CONDITIONS = /^You are (hungry|thirsty|drunk)\.$/.freeze

        def conditions_of(rows)
          found = rows.filter_map { |l| l[CONDITIONS, 1] }
          found.empty? ? nil : found.uniq.join(",")
        end

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
