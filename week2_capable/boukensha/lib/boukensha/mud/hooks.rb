require "json"
require_relative "room_parser"
require_relative "room_survey"
require_relative "state_block"
require_relative "memory/store"
require_relative "memory/fingerprint"
require_relative "../hooks"
require_relative "../permissions"

module Boukensha
  module Mud
    # Everything that knows what a MUD is, hanging off the framework's five-call
    # seam. Wired at the entrypoint, for the same reason `inspect_room` was:
    # deployment-specific glue, not framework.
    #
    # What it replaces: a tool the model had to remember to call, that re-derived
    # rooms it had already been told about (3 of 11 surveys in the sampled
    # session), and shipped ~230 permanent tokens per call to do it.
    #
    # The three bodies, and why each is where it is:
    #
    #   before_tools  ONE poll. The only moment the output that arrived during
    #                 inference is still alive — one line later the tool's own
    #                 pre-send drain destroys it. §5.6.
    #   after_tool    Cheap, synchronous, NO MUD I/O. Scrapes the prompt line off
    #                 whatever just ran, fingerprints movement results for
    #                 IDENTIFICATION only, and returns the stub that replaces a
    #                 105-token room dump the hook has already read. §5.5, §6.2.
    #   before_model  The reconciliation, and the only body allowed to spend a
    #                 blocking round trip. Known room: spends nothing. §5.4.
    #
    # Every body is wrapped in a rescue. An agent with broken memory must degrade
    # to the behaviour it had before this existed, never to a dead REPL.
    class Hooks < Boukensha::Hooks
      MOVEMENT_TOOLS = %w[move flee track].freeze
      COMBAT_TOOLS   = %w[attack skill_strike cast_spell].freeze

      # Inventory ops the agent performs on its own initiative, mapped to the
      # journal's item-stream verb. These are discrete events — an acquire is not
      # a keyed-value transition — so they go through `journal.event`, and the
      # add/remove/use *history* lives in the journal while the current bag stays
      # a replace-on-read snapshot in the store (change_capture.md §"shared seam").
      ITEM_OPS = {
        "get_item"       => "acquire",
        "drop_item"      => "drop",
        "put_item"       => "stow",
        "equip_item"     => "equip",
        "consume_item"   => "consume",
        "use_magic_item" => "use"
      }.freeze


      # Operations that move gold or experience without printing the new totals.
      # `score` is maintained by the hook now — the player's allowlist no longer
      # offers `check(kind: score)` — so anything that can invalidate the sheet
      # has to say so here or the state block quietly serves a stale figure
      # forever. Buying and selling is the one the model does on purpose;
      # winning a fight is the one that happens to it. Both mark the sheet dirty
      # and the NEXT turn re-reads it. Nothing here spends a round trip: a
      # refresh before every model call is exactly the per-iteration cost this
      # design exists to avoid.
      SCORE_STALE_TOOLS = %w[shop].freeze

      # tbaMUD's own words when the world moves without us asking it to.
      DEPARTURE = /^(?:the |a |an )?(.+?)\s+(?:leaves|has left|flees)\b/i.freeze
      ARRIVAL   = /\bhas arrived\b/i.freeze
      DEATH     = /you are dead|mortally wounded|you have been killed/i.freeze
      LEVEL_UP  = /you (?:have )?(?:raised|gained) a level|welcome to level/i.freeze
      VICTORY   = /is dead! R\.I\.P\.|you have slain|you killed/i.freeze
      FLED      = /you flee head over heels|you flee/i.freeze

      # `call_tool` is the permission-scoped dispatcher for the hook's own slice
      # (`tools.room_survey.allow`) — a SEPARATE Registry from the player's, so
      # the poll and look below can never re-enter after_tool and recurse.
      def initialize(store:, call_tool:, look_candidates: nil, logger: nil, journal: nil,
                     prefix: "tbamud__", turn_policy: false, warn_to: $stderr)
        @store     = store
        @call_tool = call_tool
        @logger    = logger
        # The append-only progression log, the store's time-series sibling.
        # Generic CDC over the knowledgebase lives in the STORE now (every
        # mutation there emits a delta); the hook only journals signals that are
        # NOT store writes — text-derived milestones (level-up, death) and the
        # item ops the agent performs before player_items exists to record them.
        @journal   = journal
        @prefix    = prefix
        @warn_to   = warn_to
        @turn_policy_enabled = turn_policy
        # The survey opens its OWN `room_survey` span, from inside `#survey` —
        # so the span is the survey's property and a second caller could not
        # mislabel it. `look`, `check(exits)`, `consider` and `examine` are then
        # one unit of automatic work by construction rather than by four call
        # sites agreeing on a string.
        @survey = RoomSurvey.new(call_tool: call_tool, look_candidates: look_candidates,
                                 entities: store, prefix: prefix, warn_to: warn_to,
                                 logger: logger)

        # Per-iteration scratch, reset as it is consumed.
        @pending_events = []
        @arrival        = nil     # { look:, direction:, from_room_id: } after a movement
        @current_room_id = nil    # nil ⇒ cold: nothing has told us where we are
        @live            = []     # the entity lines last actually observed here
        # Is the character sheet believed current? False at process start (a
        # fresh login, or a reconnect after one) and again whenever something
        # has moved gold, experience or level without printing the new totals.
        # `before_turn` clears it with one `check(score)` — at TURN boundaries
        # only, never per iteration. See SCORE_STALE_TOOLS.
        @scored          = false
        @fight           = nil    # an open encounter, spanning several tool calls
      end

      # ---------- before_turn ---------------------------------------------

      # Once per turn, and only when the sheet is not believed current: at
      # process start, after a level-up, after a kill, after a death, after
      # shopping. `threat_level` is what keeps a `consider` verdict from being
      # reused twenty levels after it was true, and gold/exp are read here
      # because the prompt line carries only HP/mana/movement.
      #
      # This is also the reason the player's allowlist no longer offers
      # `check(kind: score)`: with a refresh policy in place, a manual score
      # check can only ever duplicate a reading the hook already has.
      def before_turn(context:)
        return if @scored

        guard do
          during("player_bootstrap", "before_turn") do
            @store.update_player!(session_id: @logger&.session_id,
                                  **RoomParser.parse_score(call(:check, kind: "score")))
          end
          @scored = true
        end
      end

      # ---------- before_tools ---------------------------------------------

      # One `poll`, unconditionally, before the first dispatch of the batch.
      #
      # It looks wasteful — 79% of polls came back empty in the logs — but that
      # rate is a PLACEMENT bug, not evidence against polling: `poll` used to run
      # as step 1 of the survey, immediately after a command whose own pre-send
      # drain had just emptied the buffer. Here it runs in the one window where
      # the thinking-gap output still exists.
      #
      # What the 7 non-empty polls contained: a fight the agent never issued a
      # command for, carrying the player from 20H to -6H; and `The cityguard
      # leaves east`, which is the difference between the state block reporting a
      # cityguard and lying about one. `poll` is a non-blocking buffer drain, so
      # this costs one MCP pipe round trip and no MUD wait.
      def before_tools(calls:, context:)
        guard do
          text = during("async_poll", "before_tools") { call(:poll).to_s }
          absorb_mud_text(text)
          @pending_events.concat(event_lines(text))
        end
      end

      # ---------- after_tool ------------------------------------------------

      # Cheap and synchronous. Returns nil to leave the model's copy alone, or a
      # String to replace it.
      def after_tool(name:, args:, result:, context:)
        guard do
          text  = result.to_s
          local = unprefix(name)

          # BEFORE absorb_mud_text, for two reasons: `hp_before` must be the
          # reading from before this blow landed, and a swing that gets us
          # killed has to have opened the encounter that the death then closes —
          # otherwise the fatal fight is filed against nobody.
          open_fight(args) if COMBAT_TOOLS.include?(local)

          absorb_mud_text(text)

          # The model looks at its own sheet, its own pack and its own skill
          # list on its own initiative, for gameplay reasons. Every one of those
          # results is a free reading of the character, and this is where we
          # ride them — no new round trips, exactly as the prompt-line scrape
          # above rides whatever the model just called.
          capture_player(local, args, text)

          # An item the agent moved on its own initiative: the ledger the review
          # asked for ("when was this added/removed/used"). Recorded off the tool
          # the model already called, so no round trip is spent.
          capture_item_op(local, args) if ITEM_OPS.key?(local)

          # Gold left or entered the purse and the sheet cannot know it.
          @scored = false if SCORE_STALE_TOOLS.include?(local)

          settle_fight(local, text)

          next movement_outcome(local, args, text) if MOVEMENT_TOOLS.include?(local)

          nil
        end
      end

      # ---------- before_model ----------------------------------------------

      # Establish position, reconcile it against memory, and render what the
      # model gets to see. The only body that may spend a blocking round trip —
      # and for a room we have stood in before, it spends none.
      def before_model(context:)
        guard do
          during("position_refresh", "before_model") do
            look = arrival_look || cold_look
            resolve_position(look) if look
          end

          # Spans nothing but store reads — no MUD I/O at all — and is bracketed
          # anyway so the reads behind the `[here]` block are attributed to
          # rendering it rather than pooling into whatever ran last.
          during("state_render", "before_model") do
            context.state_block = render_state
            context.turn_policy = compute_turn_policy(context)
          end
        end
        nil
      end

      # ---------- reconcile_move! --------------------------------------------

      # Reconcile one MUD move result as a movement step, IMMEDIATELY rather
      # than deferring to the next before_model. For `execute_route`, which
      # performs several moves inside one tool call and needs per-step state
      # refresh — not just per-iteration — so a fight starting mid-route is
      # attributed to the step it started on rather than discovered only on
      # arrival (move_around.md §6).
      #
      # Reuses the exact same `resolve_position` every ordinary move eventually
      # runs through — this is not a second copy of that logic, only an
      # earlier call to it. It leaves `@arrival` untouched (nil), so the NEXT
      # `before_model` finds nothing to redo: `arrival_look` sees no pending
      # arrival, `cold_look` sees `@current_room_id` already set, and
      # `before_model` spends nothing beyond re-rendering the state block.
      #
      # Returns { ok: true, room_id:, room_name: } on a genuine arrival,
      # { ok: false, text: } on a rejected move (and records the failed
      # frontier attempt, exactly as `movement_outcome` does for a single
      # model-issued move), or nil if something in reconciliation itself
      # raised — `execute_route` should treat that the same as `ok: false`.
      def reconcile_move!(direction:, text:)
        guard do
          absorb_mud_text(text)
          look = RoomParser.parse_look(text)

          unless look.complete?
            if @current_room_id
              @store.record_frontier_attempt!(room_id: @current_room_id, direction: direction, outcome: "failed")
            end
            next { ok: false, text: text }
          end

          from_id = @current_room_id
          @pending_arrival_edge = { from: from_id, direction: direction.to_s }
          @look_is_fresh = false
          resolve_position(look)
          @store.record_frontier_attempt!(room_id: from_id, direction: direction, outcome: "succeeded") if from_id
          { ok: true, room_id: @current_room_id, room_name: @store.room(@current_room_id)&.[](:name) }
        end
      end

      private

      # =========================== position =================================

      # The Look we already have, from a movement result after_tool parsed for
      # free. Consumed once: a second iteration with no new movement must not
      # re-resolve the same arrival.
      def arrival_look
        a = @arrival or return nil
        @arrival = nil
        @pending_arrival_edge = { from: a[:from_room_id], direction: a[:direction] }
        @look_is_fresh = false      # movement text: an index key, never a record
        a[:look]
      end

      # A real `look`, and the only correct action when nothing has told us where
      # we are: a fresh login, a new session, a `/clear`, a reconnect. In every
      # one of those `player_state.current_room_id` is a hint from a previous
      # process that may be hours stale — the character may have been moved or
      # logged out elsewhere — so it is never trusted, only re-confirmed.
      def cold_look
        return nil if @current_room_id      # position already established this process

        @pending_arrival_edge = nil
        # Flagged as a REAL look so a survey that follows can reuse it instead of
        # spending a second one. Movement text never gets this flag — see §5.5.
        @look_is_fresh = true
        RoomParser.parse_look(call(:look))
      end

      # §4.2. Identity is `rooms.id`, resolved by content AND arrival edge,
      # because neither half is reliable alone: content alone merges mazes, and
      # dead-reckoning alone breaks the first time `flee` moves the player
      # without a `move` call — and `flee` is on the player's allowlist.
      def resolve_position(look)
        return unless look.complete?

        # Cleared per arrival: a `check(exits)` spent disambiguating one room
        # must never be mistaken for evidence about the next.
        @resolved_targets = nil

        weak = Memory::Fingerprint.weak(name: look.name, description: look.description,
                                        exit_dirs: look.exit_dirs)
        candidates = @store.rooms_by_weak(weak)
        edge       = @pending_arrival_edge
        from_id    = edge && edge[:from]
        direction  = edge && edge[:direction]

        room, ambiguity = case candidates.size
                          when 1 then [candidates.first, nil]
                          when 0 then [nil, nil]
                          else disambiguate(candidates, weak, from_id, direction)
                          end

        if candidates.empty?
          room, entities = discover(look, weak)
        elsif room.nil?
          room, entities = provisional(look, weak, candidates)
          ambiguity = candidates.size
        else
          room, entities = revisit(room, look)
        end
        return unless room

        link_arrival(from_id, direction, room)
        @current_room_id = room[:id]
        @ambiguity       = ambiguity
        @live            = entities
        @store.update_player!(current_room_id: room[:id], prev_room_id: from_id,
                              last_direction: direction, hp: look.hp, mana: look.mana, move: look.move)
      end

      # Several rooms share this weak fingerprint. Disambiguate in increasing
      # order of cost, and stop at the first answer.
      def disambiguate(candidates, weak, from_id, direction)
        # By arrival edge. Free.
        if from_id && direction
          known = @store.exit_at(from_id, direction)
          hit   = known && candidates.find { |c| c[:id] == known[:target_room_id] }
          return [hit, nil] if hit
        end

        # By strong fingerprint. One `check(exits)`, and it settles almost every
        # real case — the destination NAMES of the neighbours are exactly what
        # differs between two rooms that look identical.
        targets = during("room_disambiguation", "before_model") do
          RoomParser.parse_exits(call(:check, kind: "exits"))
        end
        strong  = Memory::Fingerprint.strong(weak, targets)
        @resolved_targets = targets
        matches = candidates.select { |c| c[:strong_fingerprint] == strong }
        return [matches.first, nil] if matches.size == 1

        # Still ambiguous. The honest record is not a guess.
        [nil, candidates.size]
      end

      # A room we have never stood in. Survey it properly — this is the cost
      # memory does NOT remove, and §5.5 explains why we refuse the apparent
      # shortcut of building it from the movement text instead.
      def discover(look, weak)
        # The survey runs its OWN `look` when all we have is movement text, and
        # that is not an oversight — §5.5. `run_command` drains the buffer
        # BEFORE sending, so a movement result is the room as it existed after
        # an unbounded amount of unobserved history: the mob that walked in
        # during the last inference is in the text, and the line saying the
        # other one walked out was destroyed. One round trip is the price of a
        # room record without a hole in it.
        #
        # A COLD look has no such hole — we issued it ourselves, a moment ago,
        # with nothing in between — so it is handed straight through and the
        # first arrival of a session pays for one `look`, not two.
        surveyed = @survey.survey(look: (@look_is_fresh ? look : nil))
        targets  = surveyed[:exit_targets]
        id = @store.create_room(
          name: look.name, description: look.description, weak_fingerprint: weak,
          strong_fingerprint: Memory::Fingerprint.strong(weak, targets),
          look_candidates: surveyed[:look_candidates], surveyed: true
        )
        @store.record_exits!(id, dirs: look.exit_dirs, targets: targets)
        persist_entities(id, surveyed)
        @first_visit = true
        [@store.room(id), surveyed_entities(surveyed)]
      end

      # Neither a match nor a miss. Record it as `provisional`, carry on, and
      # tell the model the location is uncertain. The merge resolver that would
      # later pin this to one of its candidates is deliberately NOT built — the
      # schema keeps the door open for free (no UNIQUE fingerprint, identity is
      # the surrogate id), and the logs will say whether Midgaard's explored area
      # contains ambiguous rooms at all.
      def provisional(look, weak, candidates)
        log_conflict("ambiguous_room", name: look.name, candidates: candidates.map { |c| c[:id] })
        id = @store.create_room(
          name: look.name, description: look.description, weak_fingerprint: weak,
          strong_fingerprint: @resolved_targets && Memory::Fingerprint.strong(weak, @resolved_targets),
          confidence: "provisional"
        )
        @store.record_exits!(id, dirs: look.exit_dirs, targets: @resolved_targets || {})
        @first_visit = true
        [@store.room(id), live_entities(look)]
      end

      # The case Market Square and Main Street hit three times in one session,
      # and the whole point of the exercise: bump the counters and spend nothing.
      def revisit(room, look)
        @store.touch_room(room[:id])
        @store.record_exits!(room[:id], dirs: look.exit_dirs)
        @first_visit = false
        [room, live_entities(look)]
      end

      # We walked an edge and know where it lands. A room cannot move; a stale
      # edge can — so a conflict is resolved in the fresh reading's favour and
      # the edge pays for it.
      def link_arrival(from_id, direction, room)
        return unless from_id && direction && room

        known = @store.exit_at(from_id, direction)
        if known && known[:target_room_id] && known[:target_room_id] != room[:id]
          log_conflict("stale_edge", from: from_id, direction: direction,
                                     expected: known[:target_room_id], found: room[:id])
          @store.demote_exit!(from_id, direction)
        end
        @store.link_exit!(from_id, direction, room[:id])

        # `check(exits)` said this way led somewhere else. Walking it is the
        # stronger evidence — a room cannot move, and the exits table can be
        # stale, mis-parsed, or (as with "Too dark to tell.") never a name at
        # all. Correct the stored name to where we actually landed, or the
        # state block renders a `✓` next to a room the agent has never been in,
        # which is worse than the `?` it replaced.
        return unless known && known[:target_name] && known[:target_name] != room[:name]

        log_conflict("exit_name_mismatch", from: from_id, direction: direction,
                                           expected: known[:target_name], found: room[:name])
        @store.rename_exit_target!(from_id, direction, room[:name])
      end

      # =========================== entities =================================

      def persist_entities(room_id, surveyed)
        # A parse that could not tell mobs from objects is wrong in EVERY room at
        # once now that entities are world-level, not per-room. Degrade to a room
        # with no entity record rather than a room with a wrong one.
        return if surveyed[:uncoloured].to_i.positive?

        (surveyed[:mobs] || []).each do |m|
          id = @store.remember_entity(kind: "mob", descr: m[:desc], keyword: m[:keyword],
                                      threat: m[:threat], equipment: m[:equipment])
          @store.record_sighting!(entity_id: id, room_id: room_id, count: m[:count])
        end
        (surveyed[:objects] || []).each do |o|
          id = @store.remember_entity(kind: "object", descr: o[:desc], keyword: o[:keyword])
          @store.record_sighting!(entity_id: id, room_id: room_id, count: o[:count])
        end
      end

      # The `here:` line's source of truth: what we actually saw, decorated with
      # what we remember about it. Presence is live; judgement is remembered.
      def live_entities(look)
        mobs = (look.mob_lines || {}).map { |desc, count| decorate(desc, count, "mob") }
        objs = (look.object_lines || {}).map { |desc, count| decorate(desc, count, "object") }
        mobs + objs
      end

      # After a survey, the fresher reading is the survey's own — it looked at
      # the room a round trip later than the movement text did, and it is the
      # only one that carries the appraisal.
      def surveyed_entities(surveyed)
        (surveyed[:mobs] || []).map { |m| decorate(m[:desc], m[:count], "mob") } +
          (surveyed[:objects] || []).map { |o| decorate(o[:desc], o[:count], "object") }
      end

      def decorate(desc, count, kind)
        row = @store.entity_for(desc, kind: kind)
        {
          desc: desc, count: count, kind: kind,
          threat: row && row[:threat], threat_fresh: row && row[:threat_fresh],
          encounters: row && encounter_note(row[:id])
        }
      end

      # "if it fights the minotaur at level 3 and loses, it should record that
      # and refer to it along with its current level when deciding whether it can
      # win" — the system prompt's Strategy section, rendered.
      def encounter_note(entity_id)
        rows = @store.encounters_for(entity_id)
        return nil if rows.empty?

        worst = rows.first
        return nil unless %w[died fled].include?(worst[:outcome])

        "you #{worst[:outcome]} against this at level #{worst[:player_level]}"
      end

      # =========================== live text ================================

      # Every MUD response carries the prompt line, which makes HP tracking free.
      # Also where death and level-up are noticed, on whatever text happens to
      # carry them.
      def absorb_mud_text(text)
        return if text.to_s.empty?

        if (p = RoomParser.parse_prompt(text))
          @store.update_player!(hp: p[:hp], mana: p[:mana], move: p[:move])
        end

        # A level change invalidates every stored `threat` at once, so the next
        # turn re-reads score and appraisals stop being reused. The `level` value
        # transition itself is captured by the stat upsert when score re-reads;
        # this milestone marks the *moment* for the progression timeline.
        if text =~ LEVEL_UP
          @scored = false
          journal_event(stream: "milestone", op: "level_up", level: @store.level)
        end

        note_death(text) if text =~ DEATH
        drop_departed(text)
      end

      # Lines worth showing the model for exactly one iteration. The prompt is
      # never an event — shipping it as one would put a false line in the state
      # block.
      def event_lines(text)
        RoomParser.lines(text).reject { |l| l =~ RoomParser::PROMPT_LINE }
      end

      # `The cityguard leaves east.` Removing the entity is the SAFE direction:
      # under-reporting presence costs the agent a redundant look, while
      # over-reporting it means telling the model to fight something that walked
      # out of the room.
      def drop_departed(text)
        RoomParser.lines(text).each do |line|
          m = line.match(DEPARTURE) or next
          noun = m[1].to_s.split(/\s+/).last.to_s.downcase
          next if noun.empty?

          @live.reject! { |e| e[:desc].to_s.downcase.include?(noun) }
        end
      end

      def note_death(text)
        # Dying costs experience and moves the character. Everything on the
        # sheet below the vitals is now a guess.
        @scored = false
        close_fight("died", RoomParser.parse_prompt(text)&.[](:hp))
        journal_event(stream: "milestone", op: "death", level: @store.level)
        # The Void fingerprints like any other room and must never be recorded as
        # an explored location — it looks like a perfectly ordinary room to every
        # part of this design — so position is dropped rather than re-derived.
        @current_room_id = nil
        @live = []
      end

      # =========================== encounters ===============================
      #
      # A fight spans several tool calls, so the outcome is a small state
      # machine rather than something readable off any one result. It opens when
      # the agent swings, and closes on exactly one of the schema's four
      # outcomes — including `abandoned`, which is what walking away from an
      # unfinished fight actually is and is worth knowing.

      def open_fight(args)
        return if @fight

        target = args && (args["target"] || args[:target])
        @fight = {
          entity_id: @store.entity_by_keyword(target)&.[](:id),
          room_id: @current_room_id,
          hp_before: @store.player[:hp]
        }
      end

      def settle_fight(local, text)
        return unless @fight

        if text =~ VICTORY
          # A kill pays experience and usually gold, and neither total appears
          # in the death message. Mark the sheet dirty rather than guessing at
          # the arithmetic.
          @scored = false
          close_fight("won", RoomParser.parse_prompt(text)&.[](:hp))
        elsif local == "flee" && text =~ FLED
          close_fight("fled", RoomParser.parse_prompt(text)&.[](:hp))
        elsif MOVEMENT_TOOLS.include?(local)
          # Walked away mid-fight. Not a defeat, but not a win either, and the
          # agent should be able to tell the difference later.
          close_fight("abandoned", RoomParser.parse_prompt(text)&.[](:hp))
        end
      end

      def close_fight(outcome, hp_after)
        f = @fight || {}
        @store.record_encounter!(outcome: outcome, room_id: f[:room_id] || @current_room_id,
                                 entity_id: f[:entity_id], hp_before: f[:hp_before], hp_after: hp_after)
        @fight = nil
      end

      # =========================== movement =================================

      # §6.2. The whitelist is on SUCCESS, never a blacklist on failure: we
      # substitute only when the parse yielded a room name AND an exits line AND
      # a prompt line. Anything else — a closed door, a refusal, text this parser
      # has never seen — reaches the model verbatim.
      #
      # The asymmetry is deliberate. A missed substitution costs ~100 tokens. A
      # wrongly swallowed failure costs an agent that retries a wall forever.
      def movement_outcome(local, args, text)
        look = RoomParser.parse_look(text)
        direction = args && (args["direction"] || args[:direction])

        unless look.complete?
          # plan_route.md §6.3's missing memory: a rejected `move` ("Alas, you
          # cannot go that way.") is the frontier-planner's evidence that this
          # exit is currently blocked. Only `move` carries a fixed, walkable
          # direction — `flee`/`track` do not name one the same way.
          if local == "move" && direction && @current_room_id
            @store.record_frontier_attempt!(room_id: @current_room_id, direction: direction, outcome: "failed")
          end
          return nil
        end

        @arrival = { look: look, direction: direction&.to_s, from_room_id: @current_room_id }
        if local == "move" && direction && @current_room_id
          @store.record_frontier_attempt!(room_id: @current_room_id, direction: direction, outcome: "succeeded")
        end
        verb = local == "flee" ? "fled" : "moved"
        direction ? "#{verb} #{direction} → #{look.name}" : "#{verb} → #{look.name}"
      end

      # =========================== rendering ================================

      def render_state
        room   = @current_room_id && @store.room(@current_room_id)
        events = @pending_events
        @pending_events = []
        block = StateBlock.render(
          room: room,
          exits: room ? @store.exits_for(room[:id]) : [],
          here: @live,
          player: @store.player,
          events: events,
          first_visit: @first_visit,
          candidates: (@first_visit && room && room[:look_candidates] && parse_json(room[:look_candidates])),
          ambiguity: @ambiguity
        )
        # The prose and the look_candidates are sent ONCE, on arrival. Every
        # later iteration in the same room gets the name — the model has already
        # read the description, and re-sending the largest field in the record
        # every 5 seconds is the accumulation this design exists to stop.
        @first_visit = false
        block
      end

      # §7. No new grammar: `Permissions` already pins enum params and already
      # validates them against each tool's declared enum at startup, so the turn
      # policy is expressible in the rule syntax that exists.
      #
      # Only the first row of the plan's table is implemented — `move` pinned to
      # the directions the MUD itself just printed — because that constraint
      # cannot be wrong: it came from the MUD in the same breath as the room.
      #
      # The failure mode it respects: tbaMUD's `[ Exits: ]` line OMITS closed
      # doors, so pinning naively makes `open door; east` unreachable. Any
      # direction memory has a remembered target_name for is added back.
      def compute_turn_policy(context)
        return nil unless @turn_policy_enabled && @current_room_id

        exits = @store.exits_for(@current_room_id)
        # tbaMUD's `[ Exits: ]` line OMITS closed doors, so pinning `move` to it
        # naively makes `open door; east` unreachable. `room_exits` keeps a
        # direction it has ever learned a target_name for, so a door we have
        # been through once stays reachable even on a visit where it is shut.
        dirs = exits.map { |e| e[:direction] }.compact.uniq
        return nil if dirs.empty?

        move = "#{@prefix}move"
        # A pure allowlist naming only `move` would DENY every other tool, which
        # is the opposite of narrowing. So the policy restates every tool the
        # task already granted, with just this one constrained: it can take a
        # direction away, and it can never grant anything settings.yaml withheld.
        rules = context.tools.keys.map { |name| name == move ? "#{move}(direction: #{dirs.join('|')})" : name }
        Permissions.from(rules)
      rescue StandardError
        nil
      end

      # =========================== plumbing =================================

      def call(tool, **args)
        @call_tool.call("#{@prefix}#{tool}", args)
      end

      # An operation span: a bracketed unit of work that OWNS everything done
      # inside it — the MUD calls, the store writes, the journal lines, the
      # local inference. That containment is what lets the monitor render
      # `room survey` nested inside `establish position` instead of scattering
      # four unexplained commands through the model's narrative as siblings.
      #
      # Reentrant, and restoring rather than clearing on the way out, because
      # `disambiguate` opens a span inside `before_model`'s and the calls after
      # it must not come back out unlabelled.
      #
      # Falls back to a logger-less span so the ambient stack (and therefore the
      # journal's `operation_id`) behaves identically whether or not anything is
      # writing the brackets down.
      def during(operation, trigger, &block)
        return @logger.operation(operation, trigger: trigger, &block) if @logger

        Boukensha::Operation.open(operation, trigger: trigger, &block)
      end

      def unprefix(name)
        i = name.to_s.index("__")
        i ? name.to_s[(i + 2)..] : name.to_s
      end

      # =========================== player ===================================
      #
      # Collection rides readings the agent already pays for. There is NO
      # scheduled `check(inventory)` here and deliberately so: it would buy
      # freshness with round trips the design spends nowhere else, and the
      # monitor can say "snapshot as of T" honestly instead.

      def capture_player(local, args, text)
        case local
        when "check"
          case (args && (args["kind"] || args[:kind])).to_s
          when "score"     then @store.update_player!(**RoomParser.parse_score(text))
          when "inventory" then capture_items("inventory", text)
          when "equipment" then capture_items("equipped", text)
          end
        when "practice" then capture_practice(text)
        end
      end

      # The one place the replace-on-read snapshot is written, and the reason it
      # checks the header before parsing: `parse_inventory` answers `[]` both
      # for an empty pack and for a refusal, and replacing the bag on the
      # strength of "Huh?!?" would delete everything the agent owns. A reading
      # that is not a listing is no reading at all — the old snapshot stands and
      # `items_updated_at` keeps saying how old it is.
      def capture_items(location, text)
        if location == "inventory"
          return unless RoomParser.carrying?(text)

          @store.replace_items!(location: location, items: RoomParser.parse_inventory(text))
        else
          return unless RoomParser.using?(text)

          @store.replace_items!(location: location, items: RoomParser.parse_equipment(text))
        end
      end

      # `practice` carries the listing AND the sessions counter in one response.
      # Skills are EARNED, so this upserts and never deletes: a listing that
      # omits a skill is not evidence the character forgot it.
      def capture_practice(text)
        practice = RoomParser.parse_practice(text)
        @store.update_player!(practices_left: practice[:practices_left])
        skills = practice[:skills].map { |s| s.merge(kind: practice[:kind]) }
        @store.upsert_skills!(skills)
      end

      def parse_json(text)
        JSON.parse(text)
      rescue StandardError
        nil
      end

      # =========================== journal ==================================
      #
      # Generic CDC over the knowledgebase lives in the STORE (every mutation
      # there emits a delta). The hook only journals signals that are NOT store
      # writes: text-derived milestones and the item ops the agent performs
      # before a player_items table exists to record them. Every path is a no-op
      # without a journal, and the journal's writes are internally guarded.

      def capture_item_op(local, args)
        return unless @journal

        @journal.event(stream: "item", op: ITEM_OPS[local], tool: local, keyword: item_keyword(args))
      end

      def journal_event(stream:, op:, **fields)
        @journal&.event(stream: stream, op: op, **fields)
      end

      # Best-effort handle for the item the op acted on, read off whatever the
      # model passed. A richer descr is player_update.md's parser's job; the
      # keyword is enough to render an honest ledger of actions taken.
      def item_keyword(args)
        return nil unless args.is_a?(Hash)

        (args["item"] || args[:item] || args["keyword"] || args[:keyword] ||
         args["target"] || args[:target] || args.values.find { |v| v.is_a?(String) })&.to_s
      end

      def log_conflict(kind, **fields)
        @logger&.tool_result(name: "memory_conflict", result: { kind: kind }.merge(fields).to_json, ok: true)
      end

      # A corrupt or locked DB, a survey that raised, an MCP hiccup — none of it
      # may kill the turn. An agent with broken memory degrades to the behaviour
      # it had before any of this existed.
      def guard
        yield
      rescue StandardError => e
        Boukensha.error_log.record(e, component: "mud_hooks",
                                  boundary: caller_locations(1, 1).first&.label || "guard")
        @warn_to&.puts "[mud_hooks] #{e.class}: #{e.message}"
        nil
      end
    end
  end
end
