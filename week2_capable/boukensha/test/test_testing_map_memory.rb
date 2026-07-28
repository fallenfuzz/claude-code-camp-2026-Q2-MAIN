require_relative "helper"
require "boukensha/testing/map_memory"

# Map memory is the single biggest determinant of the agent's behaviour and the
# one thing a YAML state file cannot express, so it is a mode rather than a
# document — and each mode has a failure it exists to prevent.
class TestTestingMapMemory < Minitest::Test
  MM = Boukensha::Testing::MapMemory

  def setup
    @root     = Dir.mktmpdir
    @profiles = File.join(@root, "profiles")
    @maps     = File.join(@root, "tests", "states", "maps")
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
  end

  private

  def memory(profile)
    MM.new(profile_dir: profile_dir(profile), profiles_dir: @profiles, maps_dir: @maps)
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
