require "test_helper"

module Api
  module V1
    class KnowledgeControllerTest < ActionDispatch::IntegrationTest
      include KnowledgeFixtures

      # ---------- envelope --------------------------------------------------

      test "every payload carries the freshness envelope" do
        use_knowledge_db
        get api_v1_knowledge_path

        assert_response :success
        body = response.parsed_body
        assert body["attached"]
        assert body["live"], "a just-written fixture is inside the live window"
        assert_equal 3, body["schema_version"]
        assert body["last_write_at"].present?
      end

      # Absence is the "agent has never run" state and must render as an empty
      # tab, not a 500 and not a 404.
      test "a missing knowledge file returns 200 with attached false" do
        use_missing_knowledge_db
        get api_v1_knowledge_path

        assert_response :success
        body = response.parsed_body
        assert_not body["attached"]
        assert_not body["live"]
        assert_nil body["player"]
        assert_equal 0, body["stats"]["rooms"]
      end

      test "the room list is empty rather than erroring when nothing is attached" do
        use_missing_knowledge_db

        get api_v1_knowledge_rooms_path
        assert_response :success
        assert_equal [], response.parsed_body["rooms"]

        get api_v1_knowledge_entities_path
        assert_response :success
        assert_equal [], response.parsed_body["entities"]

        get api_v1_knowledge_frontier_path
        assert_response :success
        assert_equal 0, response.parsed_body["count"]
      end

      # ---------- overview --------------------------------------------------

      test "overview reports stats and the player, including the writing session" do
        use_knowledge_db
        get api_v1_knowledge_path

        body = response.parsed_body
        assert_equal 5, body["stats"]["rooms"]
        assert_equal 4, body["stats"]["frontier"]
        assert_equal 1, body["stats"]["provisional"]

        player = body["player"]
        assert_equal 18, player["hp"]
        assert_equal "20260723T225532Z-7ed8c53a", player["session_id"]
        assert_equal "cleric", player["player_class"]
        assert_equal "m", player["gender"]
        assert_not player.key?("race")
        assert_not player.key?("char_class")
        assert_equal 5, player["current_room"]["id"]
        assert_equal "The Common Square", player["current_room"]["name"]
      end

      test "overview serves a file with no player_state row" do
        use_knowledge_db(sql: File.read(KnowledgeFixtures::SEED_SQL).sub(/INSERT INTO player_state.*?;/m, ""))
        get api_v1_knowledge_path

        assert_response :success
        body = response.parsed_body
        assert body["attached"]
        assert_nil body["player"]
        assert_equal 5, body["stats"]["rooms"]
      end

      # ---------- rooms -----------------------------------------------------

      test "rooms returns every room with its exits grouped onto the right row" do
        use_knowledge_db
        get api_v1_knowledge_rooms_path

        assert_response :success
        rooms = response.parsed_body["rooms"]
        assert_equal 5, rooms.length

        temple = rooms.find { |r| r["id"] == 1 }
        assert_equal 3, temple["exits"].length
        assert_equal 3, temple["entity_count"]
        assert_equal %w[cityguard fido mayor], temple["entities"].map { |entity| entity["keyword"] }
        assert_equal [ "wall", "paintings", "giants" ], temple["look_candidates"]

        square = rooms.find { |r| r["id"] == 2 }
        assert_equal %w[north south], square["exits"].map { |e| e["direction"] }.sort
      end

      test "rooms filters by text and by survey state" do
        use_knowledge_db

        get api_v1_knowledge_rooms_path, params: { q: "temple" }
        assert_equal [ 1, 2 ], response.parsed_body["rooms"].map { |r| r["id"] }

        get api_v1_knowledge_rooms_path, params: { filter: "unsurveyed" }
        assert_equal [ 3, 4 ], response.parsed_body["rooms"].map { |r| r["id"] }

        get api_v1_knowledge_rooms_path, params: { filter: "provisional" }
        assert_equal [ 4 ], response.parsed_body["rooms"].map { |r| r["id"] }
      end

      test "rooms clamps limit" do
        use_knowledge_db

        get api_v1_knowledge_rooms_path, params: { limit: 2 }
        assert_equal 2, response.parsed_body["rooms"].length

        get api_v1_knowledge_rooms_path, params: { limit: 99_999 }
        assert_equal 5, response.parsed_body["rooms"].length
      end

      test "room detail includes inhabitants, encounters and inbound exits" do
        use_knowledge_db
        get api_v1_knowledge_room_path(1)

        assert_response :success
        body = response.parsed_body
        assert_equal "The Temple Of Midgaard", body["room"]["name"]
        assert_equal 3, body["entities"].length
        assert_equal 1, body["encounters"].length
        assert_equal "fled", body["encounters"].first["outcome"]
        assert_equal [ 2 ], body["inbound"].map { |i| i["room_id"] }
      end

      test "an unknown room id 404s with the standard error shape" do
        use_knowledge_db
        get api_v1_knowledge_room_path(9999)

        assert_response :not_found
        assert_equal "not_found", response.parsed_body["error"]["code"]
      end

      # ---------- entities --------------------------------------------------

      test "entities filters by kind and keeps threat next to the level it was measured at" do
        use_knowledge_db

        get api_v1_knowledge_entities_path, params: { kind: "mob" }
        mobs = response.parsed_body["entities"]
        assert_equal 3, mobs.length
        assert(mobs.none? { |e| e["kind"] == "object" })

        guard = mobs.find { |e| e["id"] == 1 }
        assert_equal "Are you mad!?", guard["threat"]
        assert_equal 1, guard["threat_level"]
        assert_equal 2, guard["sightings"].length

        mayor = mobs.find { |e| e["id"] == 4 }
        assert_equal "You ARE mad!", mayor["threat"]
        assert_nil mayor["threat_level"]

        get api_v1_knowledge_entities_path, params: { kind: "object" }
        assert_equal [ 3 ], response.parsed_body["entities"].map { |e| e["id"] }
      end

      # ---------- frontier --------------------------------------------------

      test "frontier returns only unwalked exits and a matching count" do
        use_knowledge_db
        get api_v1_knowledge_frontier_path

        assert_response :success
        body = response.parsed_body
        assert_equal 4, body["count"]
        assert_equal body["count"], body["frontier"].length
        assert_equal [ [ 1, "east" ], [ 1, "north" ], [ 3, "west" ], [ 5, "down" ] ],
                     body["frontier"].map { |e| [ e["room_id"], e["direction"] ] }
        assert_equal "The Temple Of Midgaard", body["frontier"].first["room_name"]
      end

      # ---------- the player ------------------------------------------------

      test "the player action serves the sheet, the skills and both item lists" do
        use_knowledge_db
        get api_v1_knowledge_player_path

        assert_response :success
        body = response.parsed_body
        assert body["attached"], "the freshness envelope rides on this payload too"

        player = body["player"]
        assert_equal "Derrano the Minister", player["title"]
        assert_equal [ 162, 94 ], [ player["max_mana"], player["max_move"] ]
        assert_equal %w[hungry thirsty], player["conditions"]

        assert_equal %w[armor bless cure\ light sneak], body["skills"].map { |s| s["name"] }
        assert_equal "good", body["skills"].first["proficiency"]

        assert_equal [ "a bottle", "a hooded lantern" ], body["inventory"].map { |i| i["descr"] }
        assert_equal [ "worn on body", "wielded", "worn on finger" ], body["equipped"].map { |i| i["worn_on"] }
      end

      # Staleness is a fact the page renders, so it has to be ON the payload —
      # the bag's clock, not the row's.
      test "the item snapshot ships its own timestamp" do
        use_knowledge_db
        get api_v1_knowledge_player_path

        player = response.parsed_body["player"]
        assert_equal "2026-07-23T22:55:58Z", player["items_updated_at"]
        assert player["items_updated_at"] < player["updated_at"]
      end

      # The Overview poll runs every 3s and must not have grown a skill list and
      # two item snapshots — that is exactly why #player is its own action.
      test "the overview payload does not carry the player detail" do
        use_knowledge_db
        get api_v1_knowledge_path

        body = response.parsed_body
        assert body["player"].present?
        assert_nil body["skills"]
        assert_nil body["inventory"]
        # …but its counters do include the new tables, so the writer's tally and
        # the reader's stay symmetric.
        assert_equal [ 4, 5 ], [ body["stats"]["skills"], body["stats"]["items"] ]
      end

      test "an older agent's file is served, not rejected" do
        use_knowledge_db(sql: File.read(Rails.root.join("test/fixtures/knowledge/seed_v1.sql")),
                         name: "old.sqlite3")
        get api_v1_knowledge_player_path

        assert_response :success
        body = response.parsed_body
        assert_equal 1, body["schema_version"]
        assert_equal 2, body["player"]["level"], "what V1 knew is still served"
        assert_nil body["player"]["title"]
        assert_equal [], body["skills"]
        assert_equal [], body["equipped"]
      end

      test "the player action is empty rather than erroring when nothing is attached" do
        use_missing_knowledge_db
        get api_v1_knowledge_player_path

        assert_response :success
        body = response.parsed_body
        assert_not body["attached"]
        assert_nil body["player"]
        assert_equal [], body["skills"]
        assert_equal [], body["inventory"]
      end

      # ---------- schema drift ----------------------------------------------

      test "a schema the reader cannot query is 503 with a named code, not a 500" do
        path = use_knowledge_db
        SQLite3::Database.new(path.to_s).tap { |db| db.execute("ALTER TABLE rooms DROP COLUMN visit_count"); db.close }

        get api_v1_knowledge_rooms_path

        assert_response :service_unavailable
        error = response.parsed_body["error"]
        assert_equal "knowledge_schema_mismatch", error["code"]
        assert_equal 3, error["schema_version"]
      end
    end
  end
end
