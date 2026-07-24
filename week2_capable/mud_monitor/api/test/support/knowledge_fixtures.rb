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

  def knowledge_tmpdir
    @knowledge_tmpdir ||= Pathname.new(Dir.mktmpdir("knowledge"))
  end

  def point_config_at(path)
    cfg = Rails.application.config.x.mud_monitor
    @previous_knowledge_db = cfg.knowledge_db unless defined?(@previous_knowledge_db)
    cfg.knowledge_db = Pathname.new(path)
    Pathname.new(path)
  end

  def restore_knowledge_db
    if defined?(@previous_knowledge_db)
      Rails.application.config.x.mud_monitor.knowledge_db = @previous_knowledge_db
    end
    FileUtils.remove_entry(@knowledge_tmpdir) if @knowledge_tmpdir&.directory?
  end

  def knowledge_db_path = Rails.application.config.x.mud_monitor.knowledge_db
end
