require_relative "helper"
require "boukensha/testing/map_memory"

# Map memory is the single biggest determinant of the agent's behaviour and the
# one thing a YAML state file cannot express, so it is a mode rather than a
# document — and each mode has a failure it exists to prevent.
class TestTestingMapMemory < Minitest::Test
  MM = Boukensha::Testing::MapMemory

  SESSION = "20260729T183933Z-4caca6d5".freeze

  def setup
    @root     = Dir.mktmpdir
    @profiles = File.join(@root, "profiles")
    @maps     = File.join(@root, "tests", "knowledge", "snapshots")
    @sessions = File.join(@root, "tests", "knowledge", "sessions", "Derrano")
    FileUtils.mkdir_p([profile_dir("Derrano"), profile_dir("Dummy"), @maps])
  end

  def teardown = FileUtils.remove_entry(@root)

  # `none` ARCHIVES. Deleting a developer's accumulated map because they typed
  # a test command is not recoverable, and this command WILL get run against a
  # real profile by accident.
  def test_none_archives_rather_than_deletes_and_leaves_a_migrated_empty_db
    seed_map("Derrano", rooms: 2)

    result = memory("Derrano").apply!("none")

    assert_equal "none", result.mode
    assert File.file?(result.archived_to), "the previous map must survive as an archive"
    assert_equal 2, count_rooms(result.archived_to), "the archive must hold what was there"
    assert_equal 0, result.stats[:rooms_at_start], "the case starts cold"
    assert File.file?(db_path("Derrano")), "a migrated empty DB, not a missing file"
  end

  def test_none_against_a_profile_with_no_map_is_not_an_error
    result = memory("Derrano").apply!("none")

    assert_nil result.archived_to
    assert_equal 0, result.stats[:rooms_at_start]
  end

  def test_keep_leaves_the_database_alone
    seed_map("Derrano", rooms: 3)

    result = memory("Derrano").apply!("keep")

    assert_equal 3, result.stats[:rooms_at_start]
    assert_empty Dir.glob(File.join(profile_dir("Derrano"), "knowledge.archive", "*"))
  end

  # THE regression this design exists to prevent: the store runs in WAL mode, so
  # a plain `cp` of a database mid-session copies a torn state — silently, and
  # with `-wal`/`-shm` sidecars trailing behind it. `VACUUM INTO` does not.
  def test_copy_is_consistent_against_a_wal_dirty_source
    store = seed_map("Dummy", rooms: 4, close: false)

    begin
      assert File.file?("#{db_path('Dummy')}-wal"), "the fixture must actually leave a dirty WAL"

      result = memory("Derrano").apply!("copy:Dummy")

      assert_equal "copy:Dummy", result.mode
      assert_equal 4, result.stats[:rooms_at_start], "rows still in the WAL must come across"
      assert_empty Dir.glob(File.join(profile_dir("Derrano"), "knowledge.sqlite3-*")),
                   "VACUUM INTO produces one file with no sidecars"
    ensure
      store.close
    end
  end

  def test_copy_archives_whatever_was_there_before
    seed_map("Derrano", rooms: 1)
    seed_map("Dummy", rooms: 5)

    result = memory("Derrano").apply!("copy:Dummy")

    assert File.file?(result.archived_to)
    assert_equal 1, count_rooms(result.archived_to)
    assert_equal 5, count_rooms(db_path("Derrano"))
  end

  def test_copy_from_a_profile_with_no_map_names_the_path_it_looked_at
    error = assert_raises(MM::Error) { memory("Derrano").apply!("copy:Dummy") }

    assert_match(/knowledge database/, error.message)
    assert_match(/Dummy/, error.message)
  end

  def test_snapshot_round_trips_through_a_committed_fixture
    seed_map("Dummy", rooms: 7)
    path = memory("Dummy").snapshot!("bakery_known")

    assert_equal File.join(@maps, "bakery_known.sqlite3"), path

    result = memory("Derrano").apply!("snapshot:bakery_known")

    assert_equal "snapshot:bakery_known", result.mode
    assert_equal 7, result.stats[:rooms_at_start]
  end

  def test_a_missing_snapshot_names_the_file_it_wanted
    error = assert_raises(MM::Error) { memory("Derrano").apply!("snapshot:nope") }

    assert_match(/nope/, error.message)
  end

  def test_a_snapshot_name_may_not_escape_the_maps_directory
    seed_map("Dummy", rooms: 1)

    assert_raises(MM::Error) { memory("Dummy").snapshot!("../../escape") }
  end

  def test_an_unknown_mode_lists_the_modes
    error = assert_raises(MM::Error) { memory("Derrano").apply!("warm") }

    assert_match(/copy:<profile>/, error.message)
    assert_match(/session:<id>/, error.message)
  end

  # ---------- retention ---------------------------------------------------

  # The ordering fix, as a property: the file is named after the session that
  # BUILT it, not after the wall clock at which the next case happened to start.
  def test_retain_names_the_map_after_the_session_that_built_it
    seed_map("Derrano", rooms: 6)

    path = memory("Derrano").retain!(SESSION)

    assert_equal File.join(@sessions, "#{SESSION}.sqlite3"), path
    assert_equal 6, count_rooms(path)
    assert_equal 6, count_rooms(db_path("Derrano")), "retaining is a copy, it does not move the live map"
  end

  # A case that never opened a database is not a failure of the case, and a
  # retention that raised here would turn a passing run into an errored one.
  def test_retain_with_nothing_to_keep_is_not_an_error
    assert_nil memory("Derrano").retain!(SESSION)
  end

  # The one place in this class where an identifier becomes a filesystem path.
  def test_retain_refuses_anything_that_is_not_a_session_id
    seed_map("Derrano", rooms: 1)

    error = assert_raises(MM::Error) { memory("Derrano").retain!("../../../escape") }

    assert_match(/is not a session id/, error.message)
    assert_empty Dir.glob(File.join(@root, "tests", "knowledge", "**", "*.sqlite3"))
  end

  def test_pruning_keeps_the_most_recent_and_removes_the_oldest
    ids = (1..33).map { |i| format("20260729T%06dZ-4caca6d5", i) }
    ids.shuffle.each { |id| touch_retained(id) }

    pruned = memory("Derrano").prune_retained!

    kept = Dir.glob(File.join(@sessions, "*.sqlite3")).map { |p| File.basename(p, ".sqlite3") }.sort
    assert_equal 30, kept.size
    assert_equal ids.last(30), kept, "ids sort chronologically, so oldest-first needs no mtime"
    assert_equal 3, pruned.size
  end

  # Pruning is scoped to ONE profile's retained directory, so a committed
  # fixture is out of reach by construction rather than by a check — including a
  # fixture perverse enough to be named after a session id.
  def test_pruning_cannot_reach_a_snapshot_even_one_named_like_a_session
    seed_map("Dummy", rooms: 2)
    snapshot = memory("Dummy").snapshot!(SESSION)
    (1..31).each { |i| touch_retained(format("20260729T%06dZ-4caca6d5", i)) }

    memory("Derrano").prune_retained!

    assert File.file?(snapshot), "a snapshot is never pruned"
    assert_equal 30, Dir.glob(File.join(@sessions, "*.sqlite3")).size
  end

  def test_pruning_a_directory_that_does_not_exist_yet_is_not_an_error
    assert_empty memory("Derrano").prune_retained!
  end

  # ---------- session:<id> --------------------------------------------------

  def test_session_restores_the_map_a_previous_session_ended_with
    retained!(SESSION, rooms: 9)

    result = memory("Derrano").apply!("session:#{SESSION}")

    assert_equal "session:#{SESSION}", result.mode
    assert_equal 9, result.stats[:rooms_at_start]
  end

  # The COPY is migrated, never the source. That is what makes a retained map a
  # record rather than something that quietly changes when it is read.
  def test_an_older_schema_is_migrated_on_restore_and_the_retained_file_is_left_alone
    retained = retained_at_v1!(SESSION)

    result = memory("Derrano").apply!("session:#{SESSION}")

    assert_equal 1, result.stats[:rooms_at_start], "the V1 row came across"
    assert_equal Boukensha::Mud::Memory::Schema::LATEST_VERSION, user_version(db_path("Derrano"))
    assert_equal 1, user_version(retained), "the retained file stays at the version it was written at"
  end

  def test_a_pruned_session_names_the_file_it_wanted_and_the_policy_that_removed_it
    error = assert_raises(MM::Error) { memory("Derrano").apply!("session:#{SESSION}") }

    assert_match(/#{SESSION}/, error.message)
    assert_match(/#{Regexp.escape(@sessions)}/, error.message)
    assert_match(/30 most recent/, error.message)
  end

  def test_a_session_id_that_is_not_one_is_refused_by_the_loader
    error = assert_raises(MM::Error) { memory("Derrano").apply!("session:../../../etc/passwd") }

    assert_match(/is not a session id/, error.message)
  end

  # ---------- promotion -----------------------------------------------------

  # The missing half of the snapshot workflow: by the time a run has been read,
  # the profile's live map belongs to whatever ran after it.
  def test_a_retained_session_can_be_promoted_to_a_committed_snapshot
    retained!(SESSION, rooms: 4)
    seed_map("Derrano", rooms: 1) # the live map is now a DIFFERENT world

    path = memory("Derrano").snapshot!("midgaard", from_session: SESSION)

    assert_equal File.join(@maps, "midgaard.sqlite3"), path
    assert_equal 4, count_rooms(path), "the session's map, not the profile's current one"
    assert_equal 4, memory("Dummy").apply!("snapshot:midgaard").stats[:rooms_at_start]
  end

  def test_promoting_a_session_that_was_never_retained_names_the_file_it_wanted
    seed_map("Derrano", rooms: 1)

    error = assert_raises(MM::Error) { memory("Derrano").snapshot!("midgaard", from_session: SESSION) }

    assert_match(/#{SESSION}/, error.message)
    refute File.file?(File.join(@maps, "midgaard.sqlite3")), "a failed promotion writes nothing"
  end

  private

  def memory(profile)
    MM.new(profile_dir: profile_dir(profile), profiles_dir: @profiles, maps_dir: @maps,
           sessions_dir: File.join(@root, "tests", "knowledge", "sessions", profile))
  end

  # A retained map with `rooms` rooms in it, written the way CaseRunner writes
  # one: a real store, copied out with VACUUM INTO.
  def retained!(id, rooms: 1)
    FileUtils.rm_rf(profile_dir("Retainer"))
    FileUtils.mkdir_p(profile_dir("Retainer"))
    seed_map("Retainer", rooms: rooms)
    path = MM.new(profile_dir: profile_dir("Retainer"), sessions_dir: @sessions).retain!(id)
    FileUtils.rm_rf(profile_dir("Retainer"))
    path
  end

  # Pruning decides by NAME and never opens a file, so the cheap fixture is the
  # honest one here — thirty real databases would test SQLite, not the policy.
  def touch_retained(id)
    FileUtils.mkdir_p(@sessions)
    File.write(File.join(@sessions, "#{id}.sqlite3"), "not really a database")
  end

  # A retained file written against the ORIGINAL schema, which is the case the
  # migrate-the-copy rule exists for.
  def retained_at_v1!(id)
    require "sqlite3"
    FileUtils.mkdir_p(@sessions)
    path = File.join(@sessions, "#{id}.sqlite3")
    db   = SQLite3::Database.new(path)
    begin
      db.execute_batch(Boukensha::Mud::Memory::Schema::V1)
      db.execute("PRAGMA user_version = 1")
      db.execute(<<~SQL, ["wf1", "The Temple", "A temple.", "2026-07-29T00:00:00Z", "2026-07-29T00:00:00Z"])
        INSERT INTO rooms (weak_fingerprint, name, description, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?)
      SQL
    ensure
      db.close
    end
    path
  end

  def user_version(path)
    require "sqlite3"
    db = SQLite3::Database.new(path)
    begin
      db.get_first_value("PRAGMA user_version").to_i
    ensure
      db.close
    end
  end

  def profile_dir(name) = File.join(@profiles, name)
  def db_path(name)     = File.join(profile_dir(name), Boukensha::Mud::Memory::Store::FILENAME)

  # A real store, so the schema and the WAL behaviour under test are the ones
  # the agent actually runs against.
  def seed_map(profile, rooms:, close: true)
    store = Boukensha::Mud::Memory::Store.for_dir(profile_dir(profile))
    rooms.times { |i| store.create_room(name: "Room #{i}", description: "d#{i}", weak_fingerprint: "wf#{i}") }
    store.close if close
    store
  end

  def count_rooms(path)
    require "sqlite3"
    db = SQLite3::Database.new(path)
    begin
      db.execute("SELECT COUNT(*) FROM rooms").first.first.to_i
    ensure
      db.close
    end
  end
end
