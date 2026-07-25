require_relative "room_parser"

module Boukensha
  module Mud
    # The round trips. Everything Mud::RoomParser refuses to do.
    #
    # This is the sequencing half of what used to be `Tools::InspectRoom`, and
    # it is no longer a tool: nothing the model can call reaches it. It runs
    # from `Mud::Hooks#before_model`, and only for a room the agent has never
    # stood in — which is the whole saving. A revisit costs zero of the calls
    # below.
    #
    # It still runs under its OWN allowlist (`tools.room_survey.allow` in
    # settings.yaml) — look, check(exits), consider, examine, nothing else —
    # because retiring the tool must not widen the tool surface. `look` is
    # deliberately absent from the *player's* allowlist, so this is the only
    # route to a room survey.
    #
    # `call_tool` is injected (`->(name, args) { text }`) so the whole survey is
    # testable against a transcript with no MUD, no MCP, and no network.
    #
    # Two things that used to live here are gone on purpose:
    #   * `poll` — it was step 1 of the survey, which is the one moment in the
    #     loop it cannot succeed (the preceding command's pre-send drain already
    #     ate the buffer). It moved to Hooks#before_tools. See plan §5.6.
    #   * the session-lifetime `@keywords` cache — it is the `entities` table
    #     now, so an appraisal survives process exit and is reused in a room it
    #     was never made in.
    class RoomSurvey
      # What the survey's tool calls are labelled with in the session log, and
      # the settings key its allowlist lives under.
      NAME = "room_survey".freeze

      MAX_KEYWORD_ATTEMPTS = 2

      # `entities:` — anything answering #keyword_for(desc) and
      # #remember_keyword(desc, keyword, threat:). Mud::Memory::Store is the
      # real one; nil means "no memory", and the survey degrades to appraising
      # every mob every time, which is exactly today's behaviour.
      # `call_meta:` — the provenance stamped on every call this survey makes
      # (`operation:`/`trigger:`). It is constant for the whole survey by
      # design: the four commands below are one unit of automatic work, and a
      # reader that sees them as four separate player actions is being lied to.
      def initialize(call_tool:, look_candidates: nil, entities: nil, prefix: "tbamud__",
                     warn_to: $stderr, call_meta: {})
        @call_tool = call_tool
        @extract   = look_candidates
        @entities  = entities
        @prefix    = prefix
        @warn_to   = warn_to
        @call_meta = call_meta || {}
      end

      # The survey. `look` and `check(exits)` are unconditional; the
      # consider/examine pair is the only data-dependent part, and it is skipped
      # entirely for a mob description the `entities` table has already
      # appraised. In Midgaard, after the first hour, that is usually every mob
      # in the room.
      # `look:` — an ALREADY-PARSED look to survey against, when the caller has
      # just spent one itself. Pass it only for the output of a real `look`,
      # never for a movement result: `run_command` drains the buffer before
      # sending, so movement text is the room as it existed after an unbounded
      # amount of unobserved history — the mob that walked out is gone and the
      # line saying so was destroyed. That distinction is the whole of §5.5, and
      # this parameter is the one place it can be got wrong.
      def survey(look: nil)
        room  = look || RoomParser.parse_look(call(:look))
        exits = RoomParser.parse_exits(call(:check, kind: "exits"))

        warn_about_colour(room.uncoloured)
        # An uncoloured parse cannot tell a mob from an object, and `entities`
        # is world-level — so one bad guess here is wrong in every room the type
        # ever appears in, not just this one. Still appraise (the agent needs to
        # know what it is standing next to right now); just never write it down.
        remember = room.uncoloured.zero?

        mobs = room.mob_lines.map { |line, count| appraise(line, count, remember: remember) }
        objects = room.object_lines.map do |line, count|
          { keyword: RoomParser.guess_keywords(line).first, desc: line, count: count }.compact
        end

        {
          name: room.name,
          description: room.description,
          exit_dirs: room.exit_dirs,
          exit_targets: exits,
          hp: room.hp, mana: room.mana, move: room.move,
          uncoloured: room.uncoloured,
          mobs: mobs,
          objects: objects,
          look_candidates: candidates(room, exits, mobs, objects)
        }
      end

      private

      def call(tool, **args)
        @call_tool.call("#{@prefix}#{tool}", args, @call_meta)
      end

      # consider + examine per DISTINCT mob, priced by what memory already knows
      # rather than by how many mobs are standing here:
      #
      #   never seen this description     3 trips (consider, maybe a retry, examine)
      #   seen it, same player level      0 trips
      #   seen it, but we have levelled   1 trip (consider — the verdict moved)
      #
      # The middle row is the common case after the first hour in Midgaard,
      # where cityguards, fidos and janitors are the same three descriptions
      # everywhere. The last row is why `threat` is stored with the level it was
      # measured at: `consider`'s answer changes as the player levels, so a
      # level-up must invalidate every appraisal at once rather than let the
      # agent act on a reading from twenty levels ago.
      def appraise(line, count, remember: true)
        known   = @entities&.entity_for(line)
        keyword = known && known[:keyword]

        # A remembered keyword skips the guess-and-verify entirely, so even a
        # re-appraisal never pays for a miss.
        threat =
          if known && known[:threat_fresh]
            known[:threat]
          elsif keyword
            consider(keyword)
          end

        unless keyword
          keyword, threat = resolve(line)
          return { keyword: nil, desc: line, count: count, threat: nil } unless keyword
        end

        # `equipment` is a property of the type and is remembered. `health` is
        # NOT: it changes with every blow landed, and serving a remembered
        # "excellent condition" for a mob that is bleeding out is exactly the
        # confident lie this design exists to avoid.
        equipment = known && known[:equipment]
        health    = nil
        unless equipment
          detail    = RoomParser.parse_examine(call(:examine, target: keyword))
          equipment = detail[:equipment]
          health    = detail[:health]
        end

        if remember
          @entities&.remember_entity(kind: "mob", descr: line, keyword: keyword,
                                     threat: threat, equipment: equipment)
        end
        { keyword: keyword, desc: line, count: count, threat: threat,
          health: health, equipment: equipment }
      end

      # Returns [keyword, threat] for a description we have never resolved. Every
      # distinct mob costs at least one `consider` — that IS the threat reading —
      # and a wrong first guess costs one more.
      def resolve(line)
        guesses = RoomParser.guess_keywords(line).first(MAX_KEYWORD_ATTEMPTS)

        guesses.each do |guess|
          answer = call(:consider, target: guess).to_s
          next if answer =~ RoomParser::NOT_HERE

          threat = RoomParser.lines(answer).reject { |l| l =~ RoomParser::PROMPT_LINE }.first
          return [guess, threat]
        end
        # Give up rather than burning turns: emit the mob with a null threat.
        [nil, nil]
      end

      # One reading against a keyword the MUD has already answered to.
      def consider(keyword)
        answer = call(:consider, target: keyword).to_s
        return nil if answer =~ RoomParser::NOT_HERE

        RoomParser.lines(answer).reject { |l| l =~ RoomParser::PROMPT_LINE }.first
      end

      # The one field no parse can produce. Advisory by design, so a missing
      # model just means an empty list.
      def candidates(room, exits, mobs, objects)
        return [] unless @extract

        @extract.call(name: room.name, description: room.description,
                      exit_targets: exits, mobs: mobs, objects: objects,
                      exclude: Set.new)
      end

      # The parser reports the count; saying something about it is this class's
      # job, because it is the one with an operator to talk to.
      def warn_about_colour(count)
        return unless count.to_i.positive?

        @warn_to&.puts "[#{NAME}] #{count} entity line(s) had no colour codes; " \
                       "mob/object split is a guess and will NOT be remembered. " \
                       "Enable the character's `color` toggle."
      end
    end
  end
end
