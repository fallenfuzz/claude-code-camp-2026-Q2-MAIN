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
    #   snapshot:<name>   restore from tests/knowledge/snapshots/<name>.sqlite3
    #   session:<id>      restore the map a previous session ENDED with
    #
    # Three implementation notes matter more than the mode list:
    #
    # **Copy with `VACUUM INTO`, never `cp`.** The store runs in WAL mode, so a
    # file copy taken mid-session copies a torn state — and does it silently,
    # leaving `-wal` and `-shm` sidecars behind. `VACUUM INTO` produces one
    # consistent file with no sidecars.
    #
    # **`none` archives, it does not delete.** Deleting a developer's
    # accumulated map because they typed a test command is not recoverable, and
    # this code WILL get run against a real profile by accident.
    #
    # **A session's map is named after the session.** `#retain!` writes the map
    # a case ended with to `tests/knowledge/sessions/<profile>/<id>.sqlite3`,
    # which is the same key every other per-session artifact already joins on.
    # The alternative — the wall-clock archive under the profile dir — files
    # each case's final map under the timestamp at which the NEXT case started,
    # so nothing joins the map to the run that built it. That archive stays
    # where it is: it guards a different hazard (a developer's real accumulated
    # map, destroyed because they typed a test command) and that hazard does not
    # go away just because tests now keep their own copies.
    class MapMemory
      class Error < StandardError; end

      ARCHIVE_DIR = "knowledge.archive".freeze
      SIDECARS    = %w[-wal -shm].freeze

      # How many retained session maps survive per profile. A plan run is ten to
      # fifteen cases and two consecutive runs is the comparison a developer
      # actually makes, so thirty is two runs' worth. At ~127 KB each that is
      # under 4 MB per profile: the policy exists to keep the directory legible,
      # not to reclaim meaningful disk.
      RETAIN_LIMIT = 30

      # `Logger#generate_session_id`, exactly: UTC stamp plus four random bytes.
      # Anything that becomes a filesystem path is matched against this before
      # it is joined to a directory, which is what makes `session:<id>` and the
      # monitor's `?session=` incapable of traversal rather than merely unlikely
      # to be given one.
      SESSION_ID = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/.freeze

      MODES = "none | keep | copy:<profile> | snapshot:<name> | session:<id>".freeze

      def self.session_id?(value) = SESSION_ID.match?(value.to_s)

      Result = Struct.new(:mode, :archived_to, :source, :stats, keyword_init: true) do
        def as_json
          { mode: mode, archived_to: archived_to, source: source }.compact.merge(stats || {})
        end
      end

      # profile_dir:  where this case's knowledge.sqlite3 lives
      # profiles_dir: where `copy:` reads from
      # maps_dir:     where `snapshot:` reads and writes (committed fixtures)
      # sessions_dir: where retained session maps live, for ONE profile —
      #               scoping it that way is what makes pruning unable to reach
      #               `snapshots/` by construction rather than by a check
      def initialize(profile_dir:, profiles_dir: nil, maps_dir: nil, sessions_dir: nil)
        @profile_dir  = profile_dir.to_s
        @profiles_dir = profiles_dir
        @maps_dir     = maps_dir
        @sessions_dir = sessions_dir
      end

      def db_path = File.join(@profile_dir, Mud::Memory::Store::FILENAME)

      def apply!(mode)
        case mode.to_s
        when "none"           then reset!
        when "keep"           then Result.new(mode: "keep", stats: stats_of(db_path))
        when /\Acopy:(.+)\z/  then copy_from_profile(Regexp.last_match(1))
        when /\Asnapshot:(.+)\z/ then restore_snapshot(Regexp.last_match(1))
        when /\Asession:(.+)\z/  then restore_session(Regexp.last_match(1))
        else raise Error, "map_memory #{mode.inspect} must be #{MODES}"
        end
      end

      # Write a committed fixture out of a live profile's DB, or out of a
      # retained session's map. These are binary files in git; they are small
      # (tens of KB) and they are the only honest way to pin "the map as of the
      # run that produced this result".
      #
      # `from_session:` is the half of that workflow the live profile cannot
      # serve: by the time a run has finished and been read, the profile's
      # current map is the NEXT case's, and the one worth pinning is gone.
      def snapshot!(name, from_session: nil)
        raise Error, "snapshot name #{name.inspect} must be a bare filename" unless /\A[\w.-]+\z/.match?(name.to_s)

        source = from_session ? retained_path!(from_session) : db_path
        raise Error, "no knowledge database at #{source}" unless File.file?(source)

        dest = snapshot_path(name)
        FileUtils.mkdir_p(File.dirname(dest))
        vacuum_into(source, dest)
        dest
      end

      # The map this session ENDED with, filed under the session's own id.
      #
      # Called after the agent's turn returns, which is the first moment at
      # which both the finished map and the id that names it are in hand — the
      # whole of the ordering fix. Returns nil rather than raising when there is
      # no database to keep, because a case that never opened one is not a
      # failure of the case.
      def retain!(session_id)
        dest = retained_path(session_id)
        return nil unless File.file?(db_path)

        FileUtils.mkdir_p(File.dirname(dest))
        vacuum_into(db_path, dest)
        dest
      end

      # Keeps the `limit` most recent and deletes the rest, oldest first by
      # name — which sorts correctly because a session id begins with an ISO
      # timestamp. Returns what it deleted.
      #
      # Scoped to ONE profile's retained directory, so it cannot reach a
      # committed snapshot even if a snapshot were named after a session id.
      def prune_retained!(limit: RETAIN_LIMIT)
        return [] unless @sessions_dir && File.directory?(@sessions_dir)

        stale = Dir.glob(File.join(@sessions_dir, "*.sqlite3")).sort[0...-limit] || []
        stale.each { |path| FileUtils.rm_f(path) }
      end

      def retained_maps
        return [] unless @sessions_dir && File.directory?(@sessions_dir)

        Dir.glob(File.join(@sessions_dir, "*.sqlite3")).sort
      end

      # Row counts at the moment the case starts. "Cold map" is a claim;
      # `rooms: 0` is a fact, and it is the one the report carries.
      #
      # `regions` is here for the same reason `rooms` is: `regions_delta` is the
      # only honest way to say a case DECLARED a region, since a case running
      # against `snapshot:midgaard` inherits whatever the snapshot already
      # carried and a bare count would report the fixture's work as the run's
      # (mocking_messages.md §9). A file written before the regions migration
      # has no such table and `count` answers 0, which is what was true of it.
      COUNTED_TABLES = %w[rooms room_exits entities regions].freeze

      def stats_of(path)
        return COUNTED_TABLES.to_h { |t| [:"#{t}_at_start", 0] } unless File.file?(path)

        with_db(path) do |db|
          COUNTED_TABLES.each_with_object({}) do |table, out|
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

      # Restoring is `install`, unchanged: the COPY is migrated, so a map
      # retained under an older schema is brought forward for the case that
      # reads it while the retained file itself stays at the version it was
      # written at. That is what makes a retained map a record rather than
      # something that quietly changes when it is read.
      def restore_session(id)
        install(retained_path!(id), mode: "session:#{id}")
      end

      def retained_path(id)
        dir = @sessions_dir or raise Error, "session:<id> needs a retained-sessions directory"
        unless self.class.session_id?(id)
          raise Error, "session id #{id.inspect} is not a session id (expected 20260729T183933Z-4caca6d5)"
        end

        File.join(dir, "#{id}.sqlite3")
      end

      def retained_path!(id)
        path = retained_path(id)
        unless File.file?(path)
          raise Error, "no retained map for session #{id.inspect} at #{path} " \
                       "(the #{RETAIN_LIMIT} most recent per profile are kept; older ones are pruned)"
        end

        path
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
