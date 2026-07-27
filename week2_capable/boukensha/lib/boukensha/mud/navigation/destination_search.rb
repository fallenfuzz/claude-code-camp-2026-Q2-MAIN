require "json"

module Boukensha
  module Mud
    module Navigation
      # Deterministic, dependency-free lexical search over the agent's OWN
      # knowledge — never the bundled world files, never conversation history.
      # See docs/plans/week_2/plan_route.md §4. Pure: no store access, no I/O,
      # so every case is a plain hash in, a ranked array out.
      #
      # At the room counts this project measures (dozens, not thousands) a
      # normalized lexical match is the whole job; FTS5/embeddings are a later
      # escalation gated on a logged failure, not a default (§4.2/§10.8).
      module DestinationSearch
        # Lower is better — plan_route.md §4.2's own rank order.
        TIER_EXACT_NAME       = 1
        TIER_NAME_PHRASE      = 2
        TIER_NAME_TOKEN       = 3
        TIER_ENTITY           = 4
        TIER_DESCRIPTION      = 5
        TIER_EXIT_TARGET_NAME = 6

        class << self
          # Unicode-normalize, lowercase, punctuation -> space, collapse
          # whitespace. The one normalization every field and the query both
          # go through, so "Grubby's Bakery" and "grubbys bakery" agree.
          def normalize(str)
            # Apostrophes elide rather than split a word in two — "Grubby's"
            # normalizes to "grubbys", not "grubby s" — so a query typed
            # without the punctuation ("grubbys bakery") still hits the exact
            # tier instead of falling back to a weaker token match.
            str.to_s.unicode_normalize(:nfkc).downcase.gsub(/['’]/, "")
               .gsub(/[^[:alnum:]\s]/, " ").gsub(/\s+/, " ").strip
          end

          def tokens(str) = normalize(str).split(" ")

          # rooms:            Store#rooms
          # entities_by_room: Store#entities_by_room (room_id => [{descr:, keyword:, kind:}])
          # exits_by_room:    Store#all_exits, grouped by room_id — the
          #                   caller (RoutePlanner) already builds this
          #                   grouping for BFS, so it is not duplicated here.
          #
          # Returns every room that matches at all, each
          # { room_id:, tier:, evidence: }, sorted by tier then room_id.
          # Empty when nothing matches — a real "no evidence" answer, not a
          # raise. A blank query matches nothing rather than everything.
          def search(query, rooms:, entities_by_room: {}, exits_by_room: {})
            q = normalize(query)
            return [] if q.empty?

            q_tokens = tokens(query)

            rooms.filter_map { |room| match_room(q, q_tokens, room, entities_by_room, exits_by_room) }
                 .sort_by { |m| [m[:tier], m[:room_id]] }
          end

          private

          def match_room(q, q_tokens, room, entities_by_room, exits_by_room)
            name_norm = normalize(room[:name])

            return { room_id: room[:id], tier: TIER_EXACT_NAME, evidence: room[:name] } if name_norm == q
            return { room_id: room[:id], tier: TIER_NAME_PHRASE, evidence: room[:name] } if q.length.positive? && name_norm.include?(q)
            if token_overlap?(q_tokens, tokens(room[:name]))
              return { room_id: room[:id], tier: TIER_NAME_TOKEN, evidence: room[:name] }
            end

            entity = matching_entity(q, q_tokens, entities_by_room[room[:id]])
            return { room_id: room[:id], tier: TIER_ENTITY, evidence: entity[:descr] } if entity

            if text_matches?(q, q_tokens, room[:description]) || candidate_matches?(q, q_tokens, room[:look_candidates])
              return { room_id: room[:id], tier: TIER_DESCRIPTION, evidence: room[:description].to_s[0, 80] }
            end

            exit_name = matching_exit_target(q, q_tokens, exits_by_room[room[:id]])
            return { room_id: room[:id], tier: TIER_EXIT_TARGET_NAME, evidence: exit_name } if exit_name

            nil
          end

          def token_overlap?(q_tokens, field_tokens)
            return false if q_tokens.empty? || field_tokens.empty?

            (q_tokens & field_tokens).any?
          end

          def text_matches?(q, q_tokens, text)
            norm = normalize(text)
            return false if norm.empty?

            norm.include?(q) || token_overlap?(q_tokens, tokens(text))
          end

          def candidate_matches?(q, q_tokens, look_candidates_json)
            parse_candidates(look_candidates_json).any? { |c| text_matches?(q, q_tokens, c) }
          end

          def parse_candidates(json)
            return [] unless json

            Array(JSON.parse(json.to_s))
          rescue StandardError
            []
          end

          def matching_entity(q, q_tokens, entities)
            Array(entities).find { |e| normalize(e[:keyword]) == q || text_matches?(q, q_tokens, e[:descr]) }
          end

          def matching_exit_target(q, q_tokens, exits)
            hit = Array(exits).find { |e| e[:target_name] && text_matches?(q, q_tokens, e[:target_name]) }
            hit && hit[:target_name]
          end
        end
      end
    end
  end
end
