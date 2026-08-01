require_relative "helper"
require "json"

# Survey-mode `move_to`, end to end — docs/plans/week_3/movement_revisited/
# surveyor_architecture.md.
#
# Everything below runs against a scripted MUD and a scripted surveyor, so the
# loop, its budgets, its terminal statuses, its conditional reasoner cadence and
# its report are all testable with no model, no network and no key — the same
# trade `test_move_to.rb` makes for destination travel.
class TestSurvey < Minitest::Test
  H  = Boukensha::Mud::Hooks
  M  = Boukensha::Mud::Memory
  MT = Boukensha::Mud::Navigation::MoveTo

  TRANSCRIPTS = JSON.parse(
    File.read(File.expand_path("fixtures/mud_transcripts.json", __dir__))
  ).freeze

  MARKET_SQUARE_MOVE = "\e[0;33mMarket Square\e[0m\r\n   You are standing on the market square, the famous " \
                       "Square of Midgaard.\r\nRoads lead in every direction.\r\n\e[0;36m[ Exits: n e s w ]" \
                       "\e[0m\r\n\r\n20H 100M 81V (news) (motd) > ".freeze

  MARKET_SQUARE = {
    "look" => MARKET_SQUARE_MOVE,
    "check:exits" => "Obvious exits:\r\nnorth - The Temple Square\r\neast  - Main Street\r\n" \
                     "south - The Common Square\r\nwest  - Main Street\r\n\r\n20H 100M 81V > ",
    "check:score" => "This ranks you as Dummy the Man (level 1).\r\n20H 100M 81V > ",
    "poll" => ""
  }.freeze

  COMMON_SQUARE = {
    "look" => TRANSCRIPTS.fetch("look_common_square"),
    "check:exits" => TRANSCRIPTS.fetch("exits_common_square"),
    "check:score" => "This ranks you as Dummy the Man (level 1).\r\n20H 100M 84V > ",
    "consider:fido" => TRANSCRIPTS.fetch("consider_fido"),
    "examine:fido" => TRANSCRIPTS.fetch("examine_fido"),
    "poll" => ""
  }.freeze

  class ScriptedMud
    attr_reader :move_calls

    def initialize(start_fixtures:, moves: [], polls: [])
      @current    = start_fixtures.dup
      @moves      = moves.dup
      @polls      = polls.dup
      @move_calls = []
    end

    def nav_call_tool
      lambda do |name, args = {}|
        case name
        when "tbamud__move"
          @move_calls << args["direction"]
          step = @moves.shift || {}
          @current = step[:fixtures] if step[:fixtures]
          step[:text].to_s
        when "tbamud__poll" then @polls.shift.to_s
        else ""
        end
      end
    end

    def hook_call_tool
      lambda do |name, args|
        key = name.sub("tbamud__", "")
        key = "#{key}:#{args[:target] || args[:kind]}" if args[:target] || args[:kind]
        @current.fetch(key) { @current.fetch(name.sub("tbamud__", ""), "") }
      end
    end
  end

  # A surveyor that answers from a script. `calls` records every payload it was
  # handed, which is how the cadence tests assert what was NOT asked rather than
  # only what was answered.
  class ScriptedSurveyor
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls   = []
    end

    def to_proc
      lambda do |payload|
        @calls << payload
        answer = @answers.shift
        raise answer if answer.is_a?(StandardError)

        # A surveyor that has run out of scripted answers has nothing further to
        # say, which is a legitimate answer and not a failure.
        answer || {}
      end
    end
  end

  # Collects journal lines without a file, as in test_move_to.rb.
  class FakeJournal
    attr_reader :events

    def initialize = @events = []
    def event(stream:, op:, **fields) = @events << { stream: stream, op: op }.merge(fields)
  end

  def setup
    @store = M::Store.open(":memory:")
  rescue M::Store::Unavailable => e
    skip e.message
  end

  def teardown
    @store&.close
    Boukensha::Operation.reset!
  end

  def hooks_at_market_square(mud)
    hooks = H.new(store: @store, call_tool: mud.hook_call_tool, warn_to: nil)
    hooks.before_model(context: Boukensha::Context.new(system: "t"))
    hooks
  end

  def move_to(mud, hooks, **kwargs)
    MT.new(store: @store, call_tool: mud.nav_call_tool, hooks: hooks, **kwargs)
  end

  # The seed the objective "how big is it and what does it offer" produces: one
  # claim for the size, one for the offerings.
  SEED = {
    "open" => [
      { "statement" => "Midgaard's offerings span a describable set of classes",
        "predicate" => "composition", "subject" => "Midgaard", "priority" => 1.0, "confidence" => 0.2,
        "decisive_when" => "every named class has a confirmed instance, or no new class appears for several rooms",
        "args" => { "classes" => %w[commercial civic residential], "classes_observed" => %w[commercial] } },
      { "statement" => "Midgaard is a settlement of walkable, bounded extent",
        "predicate" => "extent_bounded", "subject" => "Midgaard", "priority" => 0.9, "confidence" => 0.3,
        "decisive_when" => "every in-scope frontier is drained" }
    ]
  }.freeze

  def south_to_common_square
    ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE }],
      polls: [""] * 8
    )
  end

  # ---------- the contract ------------------------------------------------

  def test_a_survey_walks_and_reports_the_ledger_rather_than_a_room_count
    mud = south_to_common_square
    surveyor = ScriptedSurveyor.new(SEED)
    result = move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc,
                     limits: { "survey_max_rooms" => 1 })
             .call(survey: "walk around town and work out how big it is and what it offers")

    assert_match(/\[move_to\] survey of/, result)
    assert_match(/Findings/, result)
    assert_match(/Midgaard's offerings span a describable set of classes/, result)
    assert_match(/to settle: every named class has a confirmed instance/, result,
                 "an unfinished claim says what would finish it, which is what makes the next session cheap")
    refute_empty mud.move_calls, "a survey walks"
  end

  # A survey is a `move_to` call, so it journals the same `answered` line travel
  # does and lands in the same `no_progress_calls` projection. A survey mode that
  # stayed out of that count would leave a hole in the one fact that says whether
  # the tool's budget turned into coverage.
  def test_a_survey_journals_the_same_answered_line_travel_does
    mud = south_to_common_square
    journal = FakeJournal.new
    surveyor = ScriptedSurveyor.new(SEED)
    move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc, journal: journal,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "how big is this town")

    answered = journal.events.find { |e| e[:op] == "answered" }
    assert_equal "survey", answered[:mode]
    assert_equal "how big is this town", answered[:destination]
    assert_equal 1, answered[:rooms_walked]
  end

  # ---------- assessing a door before entering it (§5.1) -------------------

  # The judgement the recorded run's surveyor made in prose and nothing could
  # read. It arrives on a hint now, is validated against its vocabulary, and is
  # what the planner defers on.
  def test_the_surveyors_assessment_of_a_frontier_is_recorded
    mud = south_to_common_square
    surveyor = ScriptedSurveyor.new(SEED.merge(
      "hints" => [{ "room_id" => 1, "direction" => "north", "expected_class" => "religious",
                    "assessability" => "unassessable", "hazard" => "suspected",
                    "note" => "an unlit well; nothing says where it goes" }]
    ))
    move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "how big is this town")

    hint = @store.frontier_hints[[1, "north"]]
    assert_equal "unassessable", hint[:assessability]
    assert_equal "suspected", hint[:hazard]
    assert_equal "religious", hint[:expected_class]
  end

  # A surveyor inventing a value must not thereby grant permission: an
  # unrecognised answer is the same as no answer, and no answer defers.
  def test_an_unrecognised_assessment_is_treated_as_no_answer
    mud = south_to_common_square
    surveyor = ScriptedSurveyor.new(SEED.merge(
      "hints" => [{ "room_id" => 1, "direction" => "north", "assessability" => "probably fine" }]
    ))
    move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "how big is this town")

    assert_nil @store.frontier_hints.dig([1, "north"], :assessability)
  end

  # And the surveyor is shown what has already been assessed, so it is not asked
  # the same question every leg.
  def test_the_payload_carries_the_assessment_already_on_record
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    @store.record_frontier_hint!(room_id: 1, direction: "north", assessability: "unassessable")
    surveyor = ScriptedSurveyor.new(SEED)
    move_to(mud, hooks, surveyor: surveyor.to_proc, limits: { "survey_max_rooms" => 1 })
      .call(survey: "how big is this town")

    # The seed call is asked only about the question; `open_frontiers` rides on the
    # revision payload, which is the call that can act on it.
    frontiers = surveyor.calls.filter_map { |c| c["open_frontiers"] }.last
    shown = frontiers.find { |f| f["direction"] == "north" }
    assert_equal "unassessable", shown["assessability"]
  end

  # The surveyor is never given a frontier to choose and never asked for one.
  # That is the single most consequential difference from the superseded design,
  # and it is what makes the walk reproducible.
  def test_the_surveyor_is_never_asked_to_choose_a_direction
    mud = south_to_common_square
    surveyor = ScriptedSurveyor.new(SEED)
    move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "what does this town offer")

    payload = surveyor.calls.first
    refute payload.key?("candidates"), "candidates are the navigator's payload, not the surveyor's"
    assert payload.key?("ledger")
    assert payload.key?("new_evidence")
    assert_equal Boukensha::Mud::Navigation::Predicates::NAMES, payload["predicates"]
  end

  def test_the_same_ledger_over_the_same_map_walks_the_same_way_twice
    walks = 2.times.map do
      store = M::Store.open(":memory:")
      mud   = south_to_common_square
      hooks = H.new(store: store, call_tool: mud.hook_call_tool, warn_to: nil)
      hooks.before_model(context: Boukensha::Context.new(system: "t"))
      MT.new(store: store, call_tool: mud.nav_call_tool, hooks: hooks,
             surveyor: ScriptedSurveyor.new(SEED).to_proc, limits: { "survey_max_rooms" => 1 })
        .call(survey: "what does this town offer")
      store.close
      mud.move_calls
    end

    assert_equal walks.first, walks.last
    refute_empty walks.first
  end

  # ---------- steps that did not land --------------------------------------
  #
  # The recorded coverage failure. In session 20260730T201603Z-ff25f010 the
  # survey held four open claims, twenty-six unspent rooms and nine unspent
  # legs when one step on leg 5 came back unreadable, and it stopped there —
  # because every kind of stop ended the loop. About one move in twenty is
  # refused in ordinary play, so a survey that gives up on the first shut door
  # cannot achieve coverage on any map that has one.

  def test_a_refused_step_does_not_end_the_survey
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      # The first frontier the planner picks is refused; the walk carries on.
      moves: [{ text: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > " },
              { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE }],
      polls: [""] * 8
    )
    result = move_to(mud, hooks_at_market_square(mud),
                     surveyor: ScriptedSurveyor.new(SEED).to_proc)
             .call(survey: "how big is this town")

    assert_operator mud.move_calls.size, :>=, 2,
                    "a refusal is a frontier to re-plan around, not a reason to hand the turn back"
    refute_match(/interrupted/, result)
  end

  def test_a_survey_gives_up_after_its_setback_allowance_rather_than_forever
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: Array.new(8) { { text: "Alas, you cannot go that way.\r\n\r\n20H 100M 81V > " } },
      polls: [""] * 8
    )
    result = move_to(mud, hooks_at_market_square(mud),
                     surveyor: ScriptedSurveyor.new(SEED).to_proc,
                     limits: { "survey_max_setbacks" => 3 })
             .call(survey: "how big is this town")

    assert_equal 3, mud.move_calls.size, "the allowance is a ceiling, and it is enforced"
    assert_match(/survey_max_setbacks \(3\) reached/, result)
  end

  # The recorded failure itself, in miniature. The survey walks a frontier, the
  # room behind it cannot be identified, and the old code called that an
  # interruption and ended a thirty-room survey on its fifth leg. It now steps
  # back out, marks the exit, and spends the rest of its budget on frontiers
  # that can still tell it something.
  def test_a_frontier_that_cannot_be_identified_costs_one_leg_not_the_survey
    dark = "It is pitch black...\r\n\r\n27H 132M 94V > "
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      moves: [{ text: dark, fixtures: { "look" => dark, "poll" => "" } },
              { text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE },
              { text: TRANSCRIPTS.fetch("look_common_square"), fixtures: COMMON_SQUARE }],
      polls: [""] * 8
    )
    result = move_to(mud, hooks_at_market_square(mud),
                     surveyor: ScriptedSurveyor.new(SEED).to_proc)
             .call(survey: "how big is this town and what does it offer")

    walked, back, = mud.move_calls
    assert_equal Boukensha::Mud::Navigation::ExecuteRouteTool::REVERSE[walked], back,
                 "the way back out is the reverse of the way in, walked without a model call"
    assert_operator mud.move_calls.size, :>=, 3, "and the survey carries on with its budget intact"
    assert_equal 1, @store.exit_at(1, walked)[:opaque],
                 "the exit that told us nothing is not offered again"
    refute_match(/interrupted/, result)
    refute_match(/no longer known/, result)
  end

  # ---------- budgets and terminal statuses --------------------------------

  def test_a_survey_stops_on_its_own_room_budget_and_says_so
    mud = south_to_common_square
    result = move_to(mud, hooks_at_market_square(mud),
                     surveyor: ScriptedSurveyor.new(SEED).to_proc,
                     limits: { "survey_max_rooms" => 1 })
             .call(survey: "how big is this town")

    assert_equal 1, mud.move_calls.size
    assert_match(/stopped on budget|surveyed/, result)
  end

  def test_a_survey_with_nothing_left_to_learn_reports_surveyed
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)
    # A claim whose only decisive test is draining the frontier set, on a map
    # whose frontiers are all out of reach of the remaining budget.
    surveyor = ScriptedSurveyor.new(
      "open" => [{ "statement" => "The town is bounded", "predicate" => "extent_bounded",
                   "subject" => "Midgaard", "decisive_when" => "every in-scope frontier is drained" }]
    )
    result = move_to(mud, hooks, surveyor: surveyor.to_proc, limits: { "survey_max_rooms" => 0 })
             .call(survey: "how big is this town")

    assert_match(/surveyed/, result)
    assert_match(/no open claim has a decisive test left within the remaining budget/, result)
    assert_empty mud.move_calls
  end

  # Seeding is the one place a surveyor failure is fatal, because there is no
  # ledger yet to score against. Once one exists the planner keeps going with no
  # reasoner at all, which the resume test below pins.
  def test_a_surveyor_that_fails_to_seed_stops_the_survey_with_a_reason
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    surveyor = ScriptedSurveyor.new(RuntimeError.new("boom"))
    result = move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc)
             .call(survey: "how big is this town")

    assert_match(/the surveyor did not answer/, result)
    assert_empty mud.move_calls, "nothing walked on a ledger that was never opened"
  end

  def test_a_deployment_with_no_surveyor_says_so_and_leaves_travel_alone
    mud = ScriptedMud.new(start_fixtures: MARKET_SQUARE)
    hooks = hooks_at_market_square(mud)

    assert_match(/no surveyor is configured/, move_to(mud, hooks).call(survey: "map the town"))
    assert_match(/\[move_to\] Market Square — arrived/, move_to(mud, hooks).call(destination: "Market Square"))
  end

  # ---------- reasoner cadence ---------------------------------------------

  # A leg that discovered no room and settled no claim tells the surveyor
  # nothing it could act on, so the planner carries on against the ledger it
  # already has. This is what bounds reasoner cost the way `max_decisions`
  # bounds navigator calls for travel.
  def test_the_surveyor_is_not_called_again_for_a_leg_that_discovered_nothing
    mud = ScriptedMud.new(
      start_fixtures: MARKET_SQUARE,
      # Walking south lands back in Market Square: a room already known, so
      # nothing new was learned and there is nothing to revise.
      moves: [{ text: MARKET_SQUARE_MOVE, fixtures: MARKET_SQUARE }],
      polls: [""] * 4
    )
    surveyor = ScriptedSurveyor.new(SEED)
    move_to(mud, hooks_at_market_square(mud), surveyor: surveyor.to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "what does this town offer")

    assert_equal 1, surveyor.calls.size, "the seed call, and no revision it could have acted on"
  end

  # ---------- durability ----------------------------------------------------

  # The strongest practical argument for the whole model. A second survey of the
  # same region resumes from what the first established rather than restarting
  # its counters at zero, and the surveyor's own seeding call receives the
  # existing ledger.
  def test_a_second_survey_resumes_from_the_ledger_the_first_one_left
    mud = south_to_common_square
    hooks = hooks_at_market_square(mud)
    move_to(mud, hooks, surveyor: ScriptedSurveyor.new(SEED).to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "what does this town offer")

    resumed = ScriptedSurveyor.new({})
    move_to(mud, hooks, surveyor: resumed.to_proc, limits: { "survey_max_rooms" => 0 })
      .call(survey: "what does this town offer")

    ledger = resumed.calls.first["ledger"]
    refute_empty ledger, "the second survey is handed what the first established"
    assert_includes ledger.map { |c| c["predicate"] }, "composition"
    assert_equal 2, @store.claims.size, "and it is the same two claims, not a fresh pair"
  end

  def test_claims_and_their_evidence_survive_the_call_that_opened_them
    mud = south_to_common_square
    seed = { "open" => SEED["open"].map { |c| c.merge("evidence" => [{ "polarity" => "support",
                                                                      "note" => "an open market" }]) } }
    move_to(mud, hooks_at_market_square(mud), surveyor: ScriptedSurveyor.new(seed).to_proc,
            limits: { "survey_max_rooms" => 1 })
      .call(survey: "what does this town offer")

    claim = @store.claims.first
    assert_equal "an open market", @store.claim_evidence(claim[:id]).first[:note]
    assert_equal "what does this town offer", claim[:objective]
  end
end
