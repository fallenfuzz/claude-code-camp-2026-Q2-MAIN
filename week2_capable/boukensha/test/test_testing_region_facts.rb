require_relative "helper"
require "json"
require "sqlite3"
require "boukensha/testing/session_facts"
require "boukensha/testing/expectations"
require "boukensha/mud/memory/schema"

# The region half of tier 1 (mocking_messages.md §9).
#
# Until this existed, "a boundary was placed" was not a thing any projection
# could say, so every region case was gradeable only as prose by the judge —
# even though the placement, the labels and the declined splits are all sitting
# in a database and a journal file the harness already writes. Everything here
# reads those two artifacts and nothing else, which is why it runs with no
# model, no MUD and no cost.
class TestTestingRegionFacts < Minitest::Test
  SF = Boukensha::Testing::SessionFacts
  EX = Boukensha::Testing::Expectations
  SESSION = "20260730T120000Z-abcd1234".freeze

  def setup
    @dir = Dir.mktmpdir
    @journal_dir = File.join(@dir, "journal")
    FileUtils.mkdir_p(@journal_dir)
  end

  def teardown = FileUtils.remove_entry(@dir)

  # ---------- the store half ----------------------------------------------

  def test_region_labels_and_counts_come_off_the_post_run_database
    db = knowledge(regions: ["Midgaard", "⟨from The Temple Of Midgaard⟩"])
    facts = load(knowledge_db: db, regions_at_start: 1)

    assert_equal ["Midgaard", "⟨from The Temple Of Midgaard⟩"], facts.region_labels
    assert_equal 2, facts.regions_known
    assert_equal 1, facts.regions_delta, "the delta is what THIS run declared, not what the fixture carried"
  end

  # A case starting from `snapshot:midgaard` inherits whatever the snapshot
  # declared. Without a starting count there is no honest delta to report, and
  # reporting one anyway would credit the fixture's work to the run.
  def test_the_delta_is_nil_when_nothing_said_what_the_run_started_from
    facts = load(knowledge_db: knowledge(regions: ["Midgaard"]))

    assert_equal 1, facts.regions_known
    assert_nil facts.regions_delta
  end

  def test_a_provisional_label_left_standing_is_reported_as_such
    facts = load(knowledge_db: knowledge(regions: ["Midgaard", "⟨from The Temple Of Midgaard⟩"]))

    assert_equal ["⟨from The Temple Of Midgaard⟩"], facts.provisional_region_labels
    refute EX.no_provisional_regions(true, facts).ok

    named = load(knowledge_db: knowledge(regions: ["Midgaard"]))
    assert EX.no_provisional_regions(true, named).ok
  end

  # The placement, which is what `find_mayor_split`'s undesired_behaviour is
  # actually about — a boundary on an interior edge passes every count-based
  # rule there is.
  def test_a_split_reports_the_room_and_the_edge_it_used
    db = knowledge(regions: ["Midgaard", "Bridge Quarter"],
                   rooms: { 1 => "The Temple Of Midgaard", 2 => "The Bridge" },
                   boundaries: [{ from: 1, to: 2, direction: "north", region: "Bridge Quarter",
                                  reason: "the only crossing", session: SESSION }])
    facts = load(knowledge_db: db)

    assert facts.region_split?
    split = facts.region_splits.first
    assert_equal 2, split[:room_id]
    assert_equal "north", split[:direction]
    assert_equal "Bridge Quarter", split[:region]
    assert_equal "The Bridge", split[:room]
  end

  # A snapshot fixture arrives with boundaries already in it. Reporting those as
  # this run's work would make every case running against `snapshot:midgaard`
  # claim a split it never made.
  def test_a_boundary_from_another_session_is_not_this_run_s_work
    db = knowledge(regions: ["Midgaard", "Bridge Quarter"],
                   rooms: { 1 => "The Temple Of Midgaard", 2 => "The Bridge" },
                   boundaries: [{ from: 1, to: 2, direction: "north", region: "Bridge Quarter",
                                  session: "20260101T000000Z-deadbeef" }])
    facts = load(knowledge_db: db)

    assert_empty facts.region_splits
    refute facts.region_split?
  end

  def test_region_expectations_read_those_facts
    db = knowledge(regions: ["Midgaard", "Bridge Quarter"],
                   rooms: { 1 => "The Temple Of Midgaard", 2 => "The Bridge" },
                   boundaries: [{ from: 1, to: 2, direction: "north", region: "Bridge Quarter",
                                  session: SESSION }])
    facts = load(knowledge_db: db)

    assert EX.region_named("Bridge Quarter", facts).ok
    assert EX.region_named("bridge quarter", facts).ok, "a label is prose the model wrote"
    refute EX.region_named("Countryside", facts).ok
    assert EX.region_split(true, facts).ok
    assert EX.region_split_at_room(2, facts).ok
    refute EX.region_split_at_room(1, facts).ok
  end

  # A large-but-coherent region the cartographer DECLINED to split is a correct
  # outcome, and asserting it is the thing §9 says there was previously no way
  # to say.
  def test_a_declined_split_is_assertable_as_a_pass
    facts = load(knowledge_db: knowledge(regions: ["Midgaard"]),
                 journal: [{ stream: "move_to", op: "region_split_declined",
                             region: "Midgaard", reason: "every room interconnects" }])

    assert EX.region_split(false, facts).ok
    assert EX.journal_op("move_to.region_split_declined", facts).ok
    assert EX.journal_op_not("move_to.region_split", facts).ok
  end

  # ---------- the journal half ---------------------------------------------

  def test_journal_events_are_joined_by_session_and_counted_by_op
    facts = load(journal: [
      { stream: "move_to", op: "decision", direction: "north" },
      { stream: "move_to", op: "decision", direction: "east" },
      { stream: "move_to", op: "region_split", region: "Bridge Quarter" },
      { stream: "stat", op: "level_up" }
    ], foreign: [{ stream: "move_to", op: "region_split", region: "Somebody Else's" }])

    assert_equal 2, facts.journal_ops["move_to.decision"]
    assert_equal 1, facts.journal_ops["move_to.region_split"],
                 "a line from another session must not count as this run's"
    assert_equal 1, facts.journal_ops["stat.level_up"]
    assert_equal 3, facts.journal_events(stream: "move_to").size
  end

  # The files rotate daily and `seq` restarts with them, so chronological order
  # is file name order then append order — never a sort on `seq`.
  def test_events_read_across_a_daily_rotation_in_order
    write_journal("20260730.jsonl", [{ stream: "move_to", op: "decision", leg: 1 }])
    write_journal("20260731.jsonl", [{ stream: "move_to", op: "decision", leg: 2 }])
    facts = load

    assert_equal [1, 2], facts.journal_events(stream: "move_to").map { |e| e["leg"] }
  end

  def test_no_journal_directory_is_no_events_rather_than_a_crash
    facts = SF.load(write_log, journal_dir: File.join(@dir, "nowhere"))

    assert_empty facts.journal_events
    assert_empty facts.journal_ops
  end

  # A journal still being appended to can end mid-line, exactly as a session log
  # can, and the same tolerance applies.
  def test_a_truncated_final_line_is_skipped_rather_than_fatal
    path = File.join(@journal_dir, "20260730.jsonl")
    File.write(path, "#{JSON.generate(kind: 'event', stream: 'move_to', op: 'decision', session_id: SESSION)}\n{\"kind\":\"eve")

    assert_equal 1, load.journal_ops["move_to.decision"]
  end

  def test_the_report_row_carries_the_region_facts
    db = knowledge(regions: ["Midgaard", "Bridge Quarter"],
                   rooms: { 1 => "The Temple Of Midgaard", 2 => "The Bridge" },
                   boundaries: [{ from: 1, to: 2, direction: "north", region: "Bridge Quarter",
                                  session: SESSION }])
    row = load(knowledge_db: db, regions_at_start: 1,
               journal: [{ stream: "move_to", op: "region_split" }]).to_h

    assert_equal 2, row[:regions_known]
    assert_equal 1, row[:regions_delta]
    assert_equal ["Bridge Quarter", "Midgaard"], row[:region_labels]
    assert_equal 2, row[:region_splits].first[:room_id]
    assert_equal 1, row[:journal_ops]["move_to.region_split"]
  end

  private

  def load(knowledge_db: nil, regions_at_start: nil, journal: nil, foreign: nil)
    write_journal("20260730.jsonl", journal) if journal
    write_journal("20260730.jsonl", foreign, session: "20260101T000000Z-deadbeef") if foreign
    SF.load(write_log, knowledge_db: knowledge_db, regions_at_start: regions_at_start,
                       journal_dir: @journal_dir)
  end

  def write_log
    path = File.join(@dir, "#{SESSION}.jsonl")
    File.write(path, JSON.generate(phase: "session_start", session_id: SESSION))
    path
  end

  def write_journal(name, events, session: SESSION)
    path = File.join(@journal_dir, name)
    File.open(path, "a") do |io|
      events.each { |e| io.puts JSON.generate(e.merge(kind: "event", session_id: session)) }
    end
  end

  # A real knowledge database at the schema the agent writes — the point being
  # that these facts are a projection of what the run actually left behind, not
  # of a hash somebody assembled for the test.
  def knowledge(regions: [], rooms: {}, boundaries: [])
    path = File.join(@dir, "knowledge-#{regions.size}-#{boundaries.size}-#{rooms.size}.sqlite3")
    db   = SQLite3::Database.new(path)
    Boukensha::Mud::Memory::Schema.migrate!(db)
    now  = "2026-07-30T12:00:00Z"
    rooms.each do |id, name|
      db.execute("INSERT INTO rooms (id, weak_fingerprint, name, description, first_seen_at, last_seen_at) " \
                 "VALUES (?, ?, ?, '', ?, ?)", [id, "fp#{id}", name, now, now])
    end
    ids = regions.each_with_object({}) do |label, out|
      db.execute("INSERT INTO regions (label, first_seen_at, updated_at) VALUES (?, ?, ?)", [label, now, now])
      out[label] = db.last_insert_row_id
    end
    boundaries.each do |b|
      db.execute("INSERT INTO region_boundaries (from_room_id, to_room_id, direction, region_id, reason, " \
                 "declared_at, session_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                 [b[:from], b[:to], b[:direction], ids.fetch(b[:region]), b[:reason], now, b[:session]])
    end
    db.close
    path
  end
end
