require "fileutils"
require "time"

module Boukensha
  module Testing
    # The agent's world knowledge (`<profile_dir>/knowledge.sqlite3`) is the
    # single biggest determinant of its behaviour — `find_bakery` against a cold
    # map is a different task from `find_bakery` against a warm one — and it is
    # exactly the thing a YAML state file cannot express.
    #
    # So it is a MODE, not a document:
    #
    #   none              archive the current DB aside, start from empty schema
    #   keep              leave it alone ("does it get better the second time")
    #   copy:<profile>    snapshot another profile's DB into this one
    #   snapshot:<name>   restore from tests/states/maps/<name>.sqlite3
    #
    # Two implementation notes matter more than the mode list:
    #
    # **Copy with `VACUUM INTO`, never `cp`.** The store runs in WAL mode, so a
    # file copy taken mid-session copies a torn state — and does it silently,
    # leaving `-wal` and `-shm` sidecars behind. `VACUUM INTO` produces one
    # consistent file with no sidecars.
    #
    # **`none` archives, it does not delete.** Deleting a developer's
    # accumulated map because they typed a test command is not recoverable, and
    # this code WILL get run against a real profile by accident.
    class MapMemory
      class Error < StandardError; end

      ARCHIVE_DIR = "knowledge.archive".freeze
      SIDECARS    = %w[-wal -shm].freeze

      Result = Struct.new(:mode, :archived_to, :source, :stats, keyword_init: true) do
        def as_json
          { mode: mode, archived_to: archived_to, source: source }.compact.merge(stats || {})
        end
      end

      # profile_dir: where this case's knowledge.sqlite3 lives
      # profiles_dir / maps_dir: where `copy:` and `snapshot:` read from
      def initialize(profile_dir:, profiles_dir: nil, maps_dir: nil)
        @profile_dir  = profile_dir.to_s
        @profiles_dir = profiles_dir
        @maps_dir     = maps_dir
      end

      def db_path = File.join(@profile_dir, Mud::Memory::Store::FILENAME)

      def apply!(mode)
        case mode.to_s
        when "none"           then reset!
        when "keep"           then Result.new(mode: "keep", stats: stats_of(db_path))
        when /\Acopy:(.+)\z/  then copy_from_profile(Regexp.last_match(1))
        when /\Asnapshot:(.+)\z/ then restore_snapshot(Regexp.last_match(1))
        else raise Error, "map_memory #{mode.inspect} must be none | keep | copy:<profile> | snapshot:<name>"
        end
      end

      # Write a committed fixture out of a live profile's DB. These are binary
      # files in git; they are small (tens of KB) and they are the only honest
      # way to pin "the map as of the run that produced this result".
      def snapshot!(name)
        raise Error, "snapshot name #{name.inspect} must be a bare filename" unless /\A[\w.-]+\z/.match?(name.to_s)
        raise Error, "no knowledge database at #{db_path}" unless File.file?(db_path)

        dest = snapshot_path(name)
        FileUtils.mkdir_p(File.dirname(dest))
        vacuum_into(db_path, dest)
        dest
      end

      # Row counts at the moment the case starts. "Cold map" is a claim;
      # `rooms: 0` is a fact, and it is the one the report carries.
      def stats_of(path)
        return { rooms_at_start: 0, room_exits_at_start: 0, entities_at_start: 0 } unless File.file?(path)

        with_db(path) do |db|
          %w[rooms room_exits entities].each_with_object({}) do |table, out|
            out[:"#{table}_at_start"] = count(db, table)
          end
        end
      rescue StandardError
        # A fixture we cannot read is worth reporting as unknown, never worth
        # failing a case over before the case has even started.
        {}
      end

      private

      def reset!
        archived = archive!
        # `Store.for_dir` migrates a fresh schema into the now-absent file, so
        # the case starts against an empty but valid DB rather than against no
        # DB at all — which is a different code path in Hooks and not the one
        # under test.
        Mud::Memory::Store.for_dir(@profile_dir).close
        Result.new(mode: "none", archived_to: archived, stats: stats_of(db_path))
      end

      def archive!
        return nil unless File.file?(db_path)

        dir  = File.join(@profile_dir, ARCHIVE_DIR)
        FileUtils.mkdir_p(dir)
        dest = File.join(dir, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}.sqlite3")
        # Archived with VACUUM INTO for the same reason a copy uses it: a WAL
        # whose contents have not been checkpointed is part of the database,
        # and moving only the main file loses whatever is still in it.
        vacuum_into(db_path, dest)
        remove_db!
        dest
      end

      def remove_db!
        FileUtils.rm_f(db_path)
        SIDECARS.each { |suffix| FileUtils.rm_f("#{db_path}#{suffix}") }
      end

      def copy_from_profile(profile)
        raise Error, "copy:<profile> needs a profiles directory" unless @profiles_dir

        source = File.join(@profiles_dir, profile.to_s, Mud::Memory::Store::FILENAME)
        raise Error, "profile #{profile.inspect} has no knowledge database at #{source}" unless File.file?(source)

        install(source, mode: "copy:#{profile}")
      end

      def restore_snapshot(name)
        source = snapshot_path(name)
        raise Error, "no map snapshot #{name.inspect} at #{source}" unless File.file?(source)

        install(source, mode: "snapshot:#{name}")
      end

      def install(source, mode:)
        archived = archive!
        FileUtils.mkdir_p(@profile_dir)
        vacuum_into(source, db_path)
        # Migrated after the copy: a fixture captured against an older schema is
        # brought forward rather than handed to the agent as-is.
        Mud::Memory::Store.for_dir(@profile_dir).close
        Result.new(mode: mode, archived_to: archived, source: source, stats: stats_of(db_path))
      end

      def snapshot_path(name)
        dir = @maps_dir or raise Error, "snapshot:<name> needs a maps directory"
        File.join(dir, "#{File.basename(name.to_s, '.sqlite3')}.sqlite3")
      end

      # One consistent file, no sidecars, whatever state the source's WAL is in.
      def vacuum_into(source, dest)
        FileUtils.rm_f(dest)
        with_db(source) { |db| db.execute("VACUUM INTO ?", [dest.to_s]) }
        raise Error, "VACUUM INTO produced no file at #{dest}" unless File.file?(dest)

        dest
      end

      def with_db(path)
        require "sqlite3"
        db = SQLite3::Database.new(path.to_s)
        begin
          yield db
        ensure
          db.close
        end
      rescue LoadError => e
        raise Error, "the sqlite3 gem is not installed, so map memory cannot be prepared (#{e.message})"
      end

      def count(db, table)
        db.execute("SELECT COUNT(*) FROM #{table}").first.first.to_i
      rescue SQLite3::SQLException
        0
      end
    end
  end
end
