## What would strategies look like?

Strategies define how reachable frontiers are ordered:

- `nearest` chooses the frontier requiring the shortest known walk.
- `depth` continues along the current branch before backtracking.
- `spread` prefers frontiers from branches, streets, or sectors explored less
  during the survey.
- `perimeter` prefers frontiers likely to extend the known regional boundary.
- `landmark` prefers frontiers with evidence for landmark classes not yet
  observed.

`spread` is the appropriate default for surveying a region. Branch coverage and
recent traversal history should be deterministic inputs. A reasoner is needed
only when frontier meaning cannot be derived from stored metadata.

A strategy also requires a completion condition. `min_rooms` and `min_legs`
permit completion. `max_rooms` and `max_legs` are hard budgets. The `mix` fields
in the example appear to mean `min`.

[Follow Up Question]
Can we rely on our Player Agent to make a good strategy choice?
If we need to create a Survevory would they just decide?

[Decision] I don't think the player agent should decide a stragety. 
It hsould be internally decided within move to.

