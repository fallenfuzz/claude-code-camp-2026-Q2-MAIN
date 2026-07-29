require_relative "base"
require_relative "scoped_prompt"

module Boukensha
  module Tasks
    # Where does the new place begin? — move_to.md §5.4, §5.5.
    #
    # Detecting that a region has stopped meaning "here" and deciding where its
    # boundary goes are different jobs needing different data, which is what
    # makes them separable. The navigator reads the one shape line it already
    # sees and raises `scope_suspect`; placement needs the region's whole room
    # graph, because finding the single entrance a quarter hangs off is a
    # question about connectivity. Shipping that graph into every leg decision
    # would be expensive, and letting the navigator guess without it produces
    # exactly the interior-edge boundary `find_mayor_split.yml` names as the
    # failure.
    #
    # So this fires only when signalled, which is also the one place a stronger
    # model would be affordable. It starts equal to the navigator; whether that
    # is enough is a config change and a batch run.
    #
    # It must be able to DECLINE. A navigator that flags a large-but-coherent
    # region is a false positive, and the cartographer holding the full graph is
    # the only thing positioned to say so. Declarations are earned and never
    # overwritten, so a boundary invented on the first uneasy leg permanently
    # mis-scopes every later `plan_route` in that area (§7.6) — the failure mode
    # is not a missing region, it is a confident wrong one.
    class Cartographer < Base
      include ScopedPrompt

      def self.task_name = "cartographer"
    end
  end
end
