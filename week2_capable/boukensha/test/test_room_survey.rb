require_relative "helper"
require "json"

# Mud::RoomSurvey: the round trips, and how few of them memory lets it make.
#
# The survey is no longer a tool — nothing the model can call reaches it. It
# runs from Mud::Hooks#before_model, and only for a room the agent has never
# stood in. What is tested here is the sequence it issues and, more importantly,
# the sequence it DOESN'T.
class TestRoomSurvey < Minitest::Test
  TRANSCRIPTS = JSON.parse(
    File.read(File.expand_path("fixtures/mud_transcripts.json", __dir__))
  ).freeze

  def t(key) = TRANSCRIPTS.fetch(key)

  # Records what was asked and replies from a script. The survey's whole
  # dependency on the outside world is this lambda.
  class FakeMud
    attr_reader :calls

    def initialize(responses)
      @responses = responses
      @calls = []
    end

    def to_proc
      lambda do |name, args = {}|
        @calls << [name, args]
        key = name.sub("tbamud__", "")
        key = "#{key}:#{args[:target] || args[:kind]}" if args[:target] || args[:kind]
        @responses.fetch(key) { @responses.fetch(name.sub("tbamud__", ""), "") }
      end
    end
  end

  # Stands in for Mud::Memory::Store's entity half. The real one is exercised in
  # test_memory_store.rb; here we only care that the survey ASKS.
  class FakeEntities
    attr_reader :rows, :writes

    def initialize(rows = {})
      @rows   = rows
      @writes = []
    end

    def entity_for(descr, kind: "mob") = @rows[descr]

    def remember_entity(kind:, descr:, keyword: nil, threat: nil, equipment: nil)
      @writes << { kind: kind, descr: descr, keyword: keyword, threat: threat }
      1
    end
  end

  def survey_for(responses, **kwargs)
    fake = FakeMud.new(responses)
    [Boukensha::Mud::RoomSurvey.new(call_tool: fake.to_proc, warn_to: nil, **kwargs), fake]
  end

  def temple_responses
    { "look" => t("look_temple"), "check:exits" => t("exits_temple") }
  end

  def common_square_responses
    { "look" => t("look_common_square"),
      "check:exits" => t("exits_common_square"),
      "consider:fido" => t("consider_fido"), "examine:fido" => t("examine_fido") }
  end

  FIDO = "A beastly fido is mucking through the garbage looking for food here.".freeze

  # --- the sequence ----------------------------------------------------------

  # `poll` is conspicuously absent. It used to be step 1 here, which is the one
  # moment in the loop it cannot succeed — the preceding command's own pre-send
  # drain had already emptied the buffer, and 79% of them came back empty as a
  # result. It belongs to Hooks#before_tools now, and it was never a room
  # concern to begin with.
  def test_survey_issues_look_then_exits_then_one_pair_per_distinct_mob
    s, fake = survey_for(common_square_responses)
    s.survey

    assert_equal ["tbamud__look", "tbamud__check", "tbamud__consider", "tbamud__examine"],
                 fake.calls.map(&:first)
    assert_equal({ kind: "exits" }, fake.calls[1].last)
  end

  def test_survey_returns_the_full_room_schema
    s, = survey_for(common_square_responses)
    room = s.survey

    assert_equal "The Common Square", room[:name]
    assert_equal "The Eastern End Of Poor Alley", room[:exit_targets]["west"]
    assert_equal %w[north east south west], room[:exit_dirs]
    assert_equal 1, room[:mobs].size
    assert_equal "fido", room[:mobs].first[:keyword]
    assert_equal 3, room[:mobs].first[:count]
    assert_equal "The perfect match!", room[:mobs].first[:threat]
    assert_equal "excellent condition", room[:mobs].first[:health]
    assert_empty room[:look_candidates] # no extractor injected
  end

  # A wrong keyword costs one round trip and says so; the survey retries with
  # the next noun rather than dropping the mob.
  def test_a_wrong_keyword_guess_is_retried_against_the_mud
    responses = temple_responses.merge(
      # Repaint the teller machine yellow so it reads as a mob and gets the
      # consider/examine treatment — the keyword the guesser gets wrong.
      "look" => t("look_temple").gsub("\e[0;32m", "\e[0;33m"),
      "consider:machine" => "They aren't here.\r\n",
      "consider:teller" => "Fairly easy.\r\n",
      "examine:teller" => t("examine_cityguard")
    )
    s, fake = survey_for(responses)
    room = s.survey

    assert_equal %w[machine teller], fake.calls.select { |n, _| n.end_with?("consider") }.map { |_, a| a[:target] }
    assert_equal "teller", room[:mobs].first[:keyword]
    assert_equal "Fairly easy.", room[:mobs].first[:threat]
  end

  def test_a_mob_that_answers_to_nothing_is_kept_with_a_null_threat
    responses = common_square_responses.merge(
      "consider:fido" => "They aren't here.\r\n", "consider:beastly" => "They aren't here.\r\n"
    )
    s, fake = survey_for(responses)
    room = s.survey

    # Two attempts, then it gives up rather than burning turns.
    assert_equal 2, fake.calls.count { |n, _| n.end_with?("consider") }
    assert_equal 0, fake.calls.count { |n, _| n.end_with?("examine") }
    assert_nil room[:mobs].first[:threat]
    assert_equal FIDO, room[:mobs].first[:desc]
  end

  # --- what memory buys ------------------------------------------------------

  # The row §10's cost model is built on, and the reason `entities` is
  # world-level rather than room-level: `consider` and `examine` appraise a
  # TYPE, so a cityguard met in a brand-new room costs nothing at all.
  def test_a_familiar_mob_at_the_same_level_costs_zero_round_trips
    entities = FakeEntities.new(
      FIDO => { id: 1, keyword: "fido", threat: "The perfect match!",
                equipment: [], threat_fresh: true }
    )
    s, fake = survey_for(common_square_responses, entities: entities)
    room = s.survey

    assert_equal %w[tbamud__look tbamud__check], fake.calls.map(&:first)
    assert_equal "The perfect match!", room[:mobs].first[:threat]
    assert_equal "fido", room[:mobs].first[:keyword]
  end

  # `consider`'s verdict is relative to the PLAYER'S level, so levelling
  # invalidates it. The keyword is not level-relative and survives — which is
  # why re-appraisal costs one call and never pays for a wrong guess.
  def test_levelling_re_appraises_the_threat_but_never_re_guesses_the_keyword
    entities = FakeEntities.new(
      FIDO => { id: 1, keyword: "fido", threat: "The perfect match!",
                equipment: ["<wielded> a club"], threat_fresh: false }
    )
    s, fake = survey_for(common_square_responses, entities: entities)
    room = s.survey

    considers = fake.calls.select { |n, _| n.end_with?("consider") }
    assert_equal 1, considers.size, "exactly one re-reading"
    assert_equal "fido", considers.first.last[:target], "no guessing, so no miss"
    assert_equal 0, fake.calls.count { |n, _| n.end_with?("examine") }, "equipment is remembered"
    assert_equal "The perfect match!", room[:mobs].first[:threat]
  end

  # `health` is instance state that changes with every blow landed. Serving a
  # remembered "excellent condition" for a mob that is bleeding out is exactly
  # the confident lie this design exists to avoid.
  def test_remembered_health_is_never_served
    entities = FakeEntities.new(
      FIDO => { id: 1, keyword: "fido", threat: "The perfect match!",
                equipment: [], threat_fresh: true }
    )
    s, = survey_for(common_square_responses, entities: entities)

    assert_nil s.survey[:mobs].first[:health]
  end

  def test_a_new_appraisal_is_written_back
    entities = FakeEntities.new
    s, = survey_for(common_square_responses, entities: entities)
    s.survey

    write = entities.writes.find { |w| w[:descr] == FIDO }
    assert_equal "fido", write[:keyword]
    assert_equal "The perfect match!", write[:threat]
  end

  # --- look_candidates -------------------------------------------------------

  def test_look_candidates_come_from_the_injected_extractor
    seen = nil
    extractor = lambda do |name:, description:, exit_targets:, mobs:, objects:, exclude:|
      seen = { name: name, description: description, exits: exit_targets, mobs: mobs }
      %w[garbage]
    end
    s, = survey_for(common_square_responses, look_candidates: extractor)
    room = s.survey

    assert_equal %w[garbage], room[:look_candidates]
    assert_equal "The Common Square", seen[:name]
    assert_equal "The Eastern End Of Poor Alley", seen[:exits]["west"]
    # The extractor is handed the parsed entities so it can subtract their
    # keywords without the survey knowing how.
    assert_equal "fido", seen[:mobs].first[:keyword]
  end

  def test_survey_still_returns_when_no_extractor_is_installed
    s, = survey_for(common_square_responses, look_candidates: nil)
    assert_empty s.survey[:look_candidates]
  end

  # --- the colour toggle -----------------------------------------------------

  # The survey passes the count through so Hooks can refuse to write entities.
  def test_uncoloured_output_is_reported_upward
    responses = common_square_responses.merge("look" => t("look_common_square").gsub(/\e\[[0-9;]*m/, ""))
    s, = survey_for(responses)

    assert_equal 3, s.survey[:uncoloured]
  end
end
