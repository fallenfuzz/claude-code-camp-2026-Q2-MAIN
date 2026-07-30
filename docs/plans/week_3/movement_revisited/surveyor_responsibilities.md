## If we have a Survevory what are their reasonings?

The Surveyor answers narrow semantic questions:

- What kind of place is this room?
- Is the room indoor or outdoor?
- Which services, institutions, or landmarks were observed?
- Which candidate frontier best fills a current coverage gap?
- Does the evidence suggest a new district or regional boundary?
- Are remaining frontiers materially different from areas already surveyed?

The Surveyor receives the survey objective, accumulated coverage metrics,
classified landmarks and offerings, branch-level visit history, current
frontier candidates, and current region structure.

`MoveTo` remains responsible for route calculation, budgets, deterministic
constraint enforcement, and completion. The Surveyor may be separate from the
Navigator because surveying is coverage-oriented while navigation is
destination-oriented. Both remain internajsul to the same public `move_to` tool.

[follow up questions]
We already have call in our before model which will build our room memory eg:
exmainse, considers, it builds our entities. So obviously a call here we could already do
Does that mean our catographer call should live outside or move_to call because Navigator
was the one soft suggesting to split regions but now its the Surevory

I was thinking an LLM would live inside the move_to that would be the one strategizing
its walkpath or determine the condition of surveyed good enough.

The existing room-memory call should remain responsible for facts observable in
one room: entities, descriptions, exits, and local semantic classifications.
The Surveyor should consume those facts and reason across rooms. It should not
repeat room extraction.

The Cartographer should remain a separate internal responsibility because
region boundaries are durable map mutations. The Surveyor may report evidence
that the current region contains distinct places. The Cartographer validates
that evidence against the accumulated graph and selects or declines an exact
boundary. Both calls may occur inside `move_to`; they do not need to become
public tools.

An LLM inside `move_to` can own:

- compiling the survey objective;
- choosing among valid frontier candidates using semantic evidence;
- adapting the survey plan as new features are discovered;
- judging semantic goals such as whether the town's offerings are represented;
- explaining why the survey is complete or incomplete.

`MoveTo` should still own:

- reachable-frontier calculation;
- route execution and replanning;
- hard budgets and interruption handling;
- enforcement of region scope and deterministic constraints;
- validation that a claimed completion has sufficient recorded evidence.

`surveyed enough` therefore has two parts. Deterministic gates establish minimum
coverage and safety limits. The Surveyor decides whether the accumulated
evidence answers the user's objective. A Surveyor completion claim cannot
override unmet deterministic gates.

