## What metadata attached to rooms would be useful for determinstic movement?

Useful observed metadata:

- region ID and first-arrival edge;
- linked and unexplored exits;
- exit target names;
- room name and description;
- observed entities and services.

Useful derived metadata:

- indoor, outdoor, or unknown;
- landmark classes such as street, square, quarter, river bank, shop, or civic
  building;
- branch or corridor ID;
- distance from the survey origin;
- visit count and visit order;
- unexplored exit count;
- edge traversal history;
- classification confidence and supporting evidence.

Observed facts and inferred classifications should remain separate.
Deterministic constraints should use only classifications above a defined
confidence threshold.

Reliable reverse edges are also required. Missing reverse links prevent
deterministic backtracking and distort coverage calculations.

[Follow Up Question]
I was expecting more descriptive metadata for what a room is.
Since many of things you ask we already have liek visit_counts.
We obviously extract entities. Maybe what need to do is create 30 examples
of surveing prompts the user would enter so we can revesere extract metadata.

The missing metadata is primarily semantic:

- place type: street, square, shop, residence, civic building, temple, park, or
  wilderness;
- environment: indoor, outdoor, covered, underground, or unknown;
- function: commercial, residential, civic, religious, defensive, transport,
  or recreational;
- geographic feature: river, river bank, wall, gate, bridge, road, or district;
- services available from observed entities;
- named features and aliases;
- relationships such as `part_of`, `along`, `inside`, `crosses`, `connects`,
  `opposite`, or `bank_of`;
- classification confidence and evidence.

Creating representative survey prompts is useful for deriving this ontology.
The prompts should cover questions about offerings, boundaries, layout,
districts, routes, defenses, natural features, accessibility, and completeness.
Thirty examples can reveal the required query vocabulary, but the metadata
model should be based on recurring concepts rather than one field per prompt.

