# Renders a test-run report document for the reports list and detail views.
#
# `#summary` is deliberately thin — the list renders twenty of these and does
# not need twenty embedded case arrays. `#detail` is the document as written,
# because the report is already the shape the detail page wants; re-deriving it
# here would be a second opinion about numbers that were computed once, by the
# harness, from the logs.
class ReportSerializer
  def initialize(document, path:)
    @doc  = document || {}
    @path = path
  end

  def summary
    summary = @doc["summary"] || {}
    {
      id: @doc["run_id"],
      kind: @doc["kind"],
      name: @doc["name"],
      started_at: @doc["started_at"],
      ended_at: @doc["ended_at"],
      profile: @doc.dig("environment", "profile"),
      provider: @doc.dig("environment", "provider"),
      model: @doc.dig("environment", "model"),
      # The field a reader needs BEFORE comparing two rows. A table that
      # silently interleaves two configurations invites exactly the wrong
      # comparison, so this travels with every row rather than living only on
      # the detail page.
      settings_digest: @doc.dig("environment", "settings_digest"),
      git_sha: @doc.dig("environment", "git_sha"),
      cases: summary["cases"],
      passed: summary["passed"],
      failed: summary["failed"],
      errored: summary["errored"],
      pass_rate: summary["pass_rate"],
      cost_usd: summary.dig("cost_usd", "total"),
      # The batch's variance in one array, for the list's sparkline. The whole
      # point of --batch 20 is that the agent is stochastic; a single number
      # hides it.
      tool_calls_series: Array(@doc["cases"]).map { |c| c.dig("facts", "model_tool_calls") },
      unreadable: @doc.empty?
    }
  end

  def detail = @doc.merge("id" => @doc["run_id"])
end
