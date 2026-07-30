# Movement Revisited

Read first the @docs/architecture/move_to.md to understand how the system currently works:

My problem is move_to(destionation:, region:) is not useful when we have a broad navigation goal to 
survey a region. "Walk around town and determine the size of the town and what is its offerings"

move_to(objective:"The bakery")

This fails because the Player Agent would counitually call it and reason its pathing
but there's no way to enforce a strategy in terms of when it completes.

I don't think introducing a second tool would be helpful since the agent might turn move_to
into how it used move where it knew it could plan_routes and execute_routes and just didn't.


move_to(
  objective: { 
    type: "survey",
    scope: "Midgaard",
    coverage: { 
      strategy: "spread", 
      rooms: {
        mix: 10,
        max: 30
      },
      legs: {
        mix: 12,
        max: 14
      }
      min_landmarks: { 
        streets: 4, 
        squares: 2, 
        quarters: 2, 
        river_banks: 2 
      } 
    },
    constraints: { 
      prefer_outdoors: true 
    }
  })

# Technical Exploration Questions: 

- [Strategies](strategies.md)
- [Room metadata](room_metadata.md)
- [Landmarks](landmarks.md)
- [Surveyor responsibilities](surveyor_responsibilities.md)
- [Proposed Surveyor architecture](surveyor_architecture.md)

# Current Direction: claim-driven surveying

The coverage-specification sketch above treats a survey as an amount of walking
to perform, which is why it needs `min_rooms`, `min_landmarks`, and a `strategy`
field that nothing is well placed to choose. The current direction models a
survey as an investigation instead: the Surveyor maintains a ledger of
falsifiable claims about the region, each claim carries a predicate that defines
both what would settle it and how it scores candidate frontiers, and the survey
ends when no open claim has a decisive test left within budget. Strategy stops
being configuration because it is whatever the open predicates imply, and the
report returned to the player is the ledger rather than a room count.

- [Claim-driven surveying](claims.md) — the claim model, predicate vocabulary,
  and how predicates become frontier scoring functions
- [Session story](session_story.md) — a two-session walkthrough in Midgaard,
  grounded in the recorded map, showing where this diverges from the run that
  actually happened
