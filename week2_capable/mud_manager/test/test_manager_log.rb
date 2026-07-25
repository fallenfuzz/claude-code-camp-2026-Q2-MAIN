require_relative "helper"
require "tmpdir"
require "fileutils"

class TestManagerLog < Minitest::Test
  def setup
    @fake = FakeMud.new
    @dir  = Dir.mktmpdir("manager_log")
  end

  def teardown
    @fake.stop
    FileUtils.remove_entry(@dir)
  end

  def test_from_env_returns_nil_when_dir_unset
    with_env("MUD_MANAGER_LOG_DIR" => nil) do
      assert_nil MudManager::ManagerLog.from_env
    end
  end

  def test_from_env_builds_a_log_when_dir_set
    with_env("MUD_MANAGER_LOG_DIR" => @dir) do
      log = MudManager::ManagerLog.from_env
      refute_nil log
    end
  end

  def test_disabled_by_default_writes_no_files
    pool = pool_with_manager_log(nil)
    pool.run_command("default", "look")

    assert_empty Dir.glob(File.join(@dir, "*.jsonl"))
  end

  def test_run_command_writes_one_record_with_positive_elapsed_ms
    pool = pool_with_manager_log(manager_log)
    pool.run_command("default", "look", tool: "tbamud__look", args: {})

    records = read_records
    record  = records.find { |r| r["mode"] == "command" }

    refute_nil record
    assert_equal "default", record["session"]
    assert_equal "tbamud__look", record["tool"]
    assert_equal "look", record["sent"]
    assert_match(/You do: look/, record["received"])
    assert_operator record["elapsed_ms"], :>, 0
    assert_nil record["error"]
  end

  def test_run_raw_writes_one_record
    pool = pool_with_manager_log(manager_log)
    pool.run_raw("default", "score")

    record = read_records.find { |r| r["mode"] == "raw" }
    refute_nil record
    assert_equal "score", record["sent"]
    assert_operator record["elapsed_ms"], :>, 0
  end

  def test_poll_writes_one_record
    pool = pool_with_manager_log(manager_log)
    pool.run_command("default", "look") # opens + logs in first
    @fake.push("A goblin arrives.\r\n")
    sleep 0.05
    pool.poll("default")

    record = read_records.reverse.find { |r| r["mode"] == "poll" }
    refute_nil record
    assert_match(/goblin/, record["received"])
  end

  # boukensha plan §3: a call carrying `_meta["boukensha/operation_id"]` must
  # land in the ManagerLog record for that exchange, so the two logs join by
  # id instead of a timestamp heuristic. Composed with the session id — an
  # operation_id alone does not say WHICH FILE it lives in, which is what the
  # Manager page needs to link `correlation: "exact"` back to `sessions/:id`.
  def test_correlation_id_is_forwarded_from_the_server_to_the_manager_log
    pool   = pool_with_manager_log(manager_log)
    server = MudManager::Mcp::Server.new(pool: pool)

    call = server.send(:call_tool, {
      "name" => "look", "arguments" => {},
      "_meta" => { "boukensha/session_id" => "s1", "boukensha/operation_id" => "op_abc123" }
    })
    refute call["isError"]

    record = read_records.find { |r| r["mode"] == "command" }
    assert_equal "s1:op_abc123", record["correlation_id"]
  end

  # A caller that sends an operation_id with no session_id (a degraded or
  # future client) still correlates — just at operation granularity.
  def test_correlation_id_falls_back_to_the_bare_operation_id_without_a_session_id
    pool   = pool_with_manager_log(manager_log)
    server = MudManager::Mcp::Server.new(pool: pool)

    server.send(:call_tool, {
      "name" => "look", "arguments" => {},
      "_meta" => { "boukensha/operation_id" => "op_abc123" }
    })

    record = read_records.find { |r| r["mode"] == "command" }
    assert_equal "op_abc123", record["correlation_id"]
  end

  # No `_meta` at all — an older client, or the raw JSON protocol — must log
  # exactly as it did before the correlation id existed.
  def test_absent_meta_leaves_correlation_id_nil
    pool   = pool_with_manager_log(manager_log)
    server = MudManager::Mcp::Server.new(pool: pool)

    server.send(:call_tool, { "name" => "look", "arguments" => {} })

    record = read_records.find { |r| r["mode"] == "command" }
    assert_nil record["correlation_id"]
  end

  def test_errors_are_captured
    pool = pool_with_manager_log(manager_log, password: "wrong")

    assert_raises(MudManager::Mcp::ProtocolError) { pool.run_command("default", "look") }

    record = read_records.find { |r| r["mode"] == "login" }
    refute_nil record
    refute_nil record["error"]
    refute_match(/wrong/, record["sent"].to_s) # never the password
  end

  private

  def manager_log
    MudManager::ManagerLog.new(dir: @dir)
  end

  def pool_with_manager_log(log, password: "secret")
    cfg = MudManager::Mcp::Config.new(host: "127.0.0.1", port: @fake.port, name: "Gandalf", password: password)
    MudManager::Mcp::SessionPool.new(default_config: cfg, timeout: 5.0, manager_log: log)
  end

  def read_records
    Dir.glob(File.join(@dir, "*.jsonl")).flat_map do |path|
      File.readlines(path).map { |line| JSON.parse(line) }
    end
  end

  def with_env(vars)
    old = {}
    vars.each { |k, v| old[k] = ENV[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
