require "sqlite3"
require "tmpdir"

# Builds a real knowledge.sqlite3 from test/fixtures/knowledge/seed.sql.
#
# The file is built rather than committed: a binary fixture cannot be reviewed
# in a diff, and the point of testing against real SQLite (instead of stubbing
# the reader) is that `query_only`, WAL and `user_version` are exactly the
# behaviours under test — none of which a double would reproduce.
module KnowledgeFixtures
  SEED_SQL = Rails.root.join("test/fixtures/knowledge/seed.sql")

  def self.included(base)
    base.teardown { restore_knowledge_db }
  end

  # Creates the DB, points config.x.mud_monitor.knowledge_db at it, returns the
  # path. `sql:` overrides the seed entirely (for schema-drift cases); `wal:`
  # false leaves the file in the default rollback-journal mode.
  def use_knowledge_db(sql: File.read(SEED_SQL), name: "knowledge.sqlite3", wal: true)
    path = knowledge_tmpdir.join(name)
    db = SQLite3::Database.new(path.to_s)
    db.execute("PRAGMA journal_mode=WAL") if wal
    db.execute_batch(sql)
    # A clean close checkpoints and removes -wal/-shm, which is precisely the
    # on-disk state a reader hits when the agent is not running.
    db.close
    point_config_at(path)
    path
  end

  # Points config at a path that does not exist — the "agent has never run"
  # state, which must render as an empty tab and not an error.
  def use_missing_knowledge_db
    point_config_at(knowledge_tmpdir.join("absent.sqlite3"))
  end

  # The map a past session ended with, where the harness writes it:
  # `tests/knowledge/sessions/<profile>/<session_id>.sqlite3`. Built from the
  # same seed as the live file so a test can point at both and tell them apart
  # by content.
  def use_retained_map(session_id, sql: File.read(SEED_SQL), profile: "legacy")
    cfg = Rails.application.config.x.mud_monitor
    @previous_boukensha_dir = cfg.boukensha_dir unless defined?(@previous_boukensha_dir)
    cfg.boukensha_dir = knowledge_tmpdir

    dir = knowledge_tmpdir.join("tests/knowledge/sessions", profile)
    dir.mkpath
    path = dir.join("#{session_id}.sqlite3")
    db = SQLite3::Database.new(path.to_s)
    db.execute_batch(sql)
    db.close
    path
  end

  def knowledge_tmpdir
    @knowledge_tmpdir ||= Pathname.new(Dir.mktmpdir("knowledge"))
  end

  def point_config_at(path)
    cfg = Rails.application.config.x.mud_monitor
    @previous_knowledge_db = cfg.knowledge_db unless defined?(@previous_knowledge_db)
    cfg.knowledge_db = Pathname.new(path)
    point_profiles_at_tmpdir
    Pathname.new(path)
  end

  # The `legacy` profile every integration test selects only EXISTS when the
  # boukensha dir looks like a runtime — ProfileRegistry#legacy? probes for
  # sessions/, telnet/, journal/, manager/ or knowledge.sqlite3. Rooted at the
  # developer's real ~/.boukensha that is a property of their machine: clear
  # those directories out and every knowledge test 409s with
  # `profile_selection_required`, which is a true answer to a question the test
  # never meant to ask.
  #
  # So the registry is rooted at the same throwaway dir the fixture DB lives in,
  # with one runtime marker in it. The tests then depend on nothing outside
  # tmpdir — which is what the rest of this file was already careful to do.
  def point_profiles_at_tmpdir
    cfg = Rails.application.config.x.mud_monitor
    @previous_profile_registry = cfg.profile_registry unless defined?(@previous_profile_registry)
    knowledge_tmpdir.join("sessions").mkpath
    cfg.profile_registry = ProfileRegistry.new(root: knowledge_tmpdir)
  end

  def restore_knowledge_db
    cfg = Rails.application.config.x.mud_monitor
    cfg.knowledge_db = @previous_knowledge_db if defined?(@previous_knowledge_db)
    cfg.profile_registry = @previous_profile_registry if defined?(@previous_profile_registry)
    cfg.boukensha_dir = @previous_boukensha_dir if defined?(@previous_boukensha_dir)
    FileUtils.remove_entry(@knowledge_tmpdir) if @knowledge_tmpdir&.directory?
  end

  def knowledge_db_path = Rails.application.config.x.mud_monitor.knowledge_db
end
