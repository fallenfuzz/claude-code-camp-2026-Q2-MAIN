# The batch session test harness.
#
# The load-bearing idea is that **a case produces nothing new on disk except a
# normal session log**. Everything the harness wants to know about a case is
# already written by `Boukensha::Logger` — tool calls with `initiator`,
# operation spans with their counters, usage, cost, `end_reason`. A report is a
# DERIVATION over session logs plus a judge verdict, not a second parallel
# telemetry channel. That keeps one source of truth, and it means mud_monitor's
# existing session views work unmodified on a test session.
#
#   scenario  = goal + starting state + rubric        (one file, reusable)
#   plan      = a list of scenarios with overrides    (one file, a suite)
#   case      = one execution of a scenario           (one session .jsonl)
#   run       = one CLI invocation                    (one report .json)
#
# Required from lib/boukensha_loader.rb only when a test flag is present, so an
# ordinary interactive launch pays nothing for any of it.
require_relative "testing/run_log"
require_relative "testing/overrides"
require_relative "testing/fixtures"
require_relative "testing/state_loader"
require_relative "testing/map_memory"
require_relative "testing/stage"
require_relative "testing/session_facts"
require_relative "testing/expectations"
require_relative "testing/judge"
require_relative "testing/report"
require_relative "testing/runner"
require_relative "testing/case_runner"
require_relative "testing/cli"

module Boukensha
  module Testing
  end
end
