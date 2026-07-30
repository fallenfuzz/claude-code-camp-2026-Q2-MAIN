## Is landmarks useful as value because the move_to will probably need a new LLM call eg Surveyor?

Landmarks are useful as coverage evidence and frontier-selection targets. They
should not normally be mandatory completion requirements because a region may
not contain the requested number or class of landmarks.

Landmark targets can influence frontier selection and appear in the final
coverage report. Survey completion should depend on measurable graph state:

- minimum rooms visited;
- minimum branch diversity;
- remaining reachable regional frontiers;
- hard room and leg budgets.

A semantic reasoner is needed to classify landmarks when room and exit text
cannot be classified reliably by deterministic rules.

[Follow Up Question]
What is a landmark? If the questions ask about two banks, how do even know
this town has two river banks? If we have a fountain as an entity, how that
tied to our landmark metadata? I would suspect most landmarks are unique and
so would counts even make sense. Why wouldnt be left riverbank, right riverbank
Or if the strategy to walk the town, and determin its a wall city with road along it
would it generate landmarks of "east wall road", "west wall road", "north...", "south..."
and would the straegy bubble up to walk around the entire road map.

A landmark is a named or distinguishable feature that can identify a place or
describe its structure. It may be represented by an entity, one room, or a
connected group of rooms.

A fountain entity can support a landmark record:

```text
landmark: fountain
identity: Temple Square fountain
observed_in: Temple Square
evidence: entity #123
```

River banks should be distinct observed features related to the same river,
such as `east_bank bank_of River Tanna`. The system must not assume that two
banks are reachable, inside the region, or represented by separate rooms.

Counts are useful for repeated classes such as gates, squares, or bridges.
Unique features are better represented by identity and relationships. Survey
requests should therefore use targets or questions, not assertions that the
requested features exist.

A wall road can be represented as connected room segments related to a city
wall. Names such as `east wall road` should be created only when names,
directions, or graph evidence support those identities. A perimeter strategy
can continue following the connected feature until it closes, leaves scope, has
no continuation, or reaches a hard budget. That behavior comes from a
feature-following coverage goal, not from landmark counts alone.

