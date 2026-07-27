## Technical Goal
In Week 2 we want the to create an outer agnetic loop to make the agent capable.
Its important we improve its token efficeny, and have very good observability.

## Technical Uncertainty
I am uncertain through prompting alone that we can engineer such a complex outer loop.
I am uncertain if we can make it token efficent, since itelligence may just require a specific amount of cost.
I am uncertain if we will just end up having to rely mostly on "scripts" due to model latency.
Will we simply just end up have an Agent that is simply wearing a trenchcoat of many tranditional scripting and routing logic.

## Technical Hypotheses 
Purely using AI along will fail to achieve build a capable loop.
We will need as humans build the problem infront of us, solving key issues first, and the iterate back again to build a real loop.
AI will fail to handle the level of complexity for development and if we do not keep full ownership of code we will end in a technical dead end.

## Technical Observerations

Since I attempted twice and failed to build a complete outerloop using AI with the most intelligent avaliable models,
Instead of working of closing the outer loop I am going to tackle the each problem in front of me.

### Step 1: Determine a benchmark of token usage from moving from Point A to Point B

I will ask the agent from the starting position move to the bakery and list the menu.
65K tokens and not reaching the bakery often happens.

- We need to "cache" knowledge about each room to reduce traversal.
- The agent isn't checking "exits" to get full exit names making its reasoning navigating an unknown world often random movements
- manually loging in and moving the player back to the starting position is annoying.

### Step 2: Reset Player Script

We will create a reset player script to move the player back to starting position.
./bin/move_player_to_start_room
- we added to the mud_manager admin specific tools
- this script will login as the player and admin
- the admin commands will move the player back to the starting position.

### Step 3: Always Collect Exits Data 

Since we always need to see full exits information create a composite tool call "inspect"
which will show ==look and ==exits

This works, but the are other things we could be learning about new visited rooms, like objects, mobs, npcs and interactions.

- We will need to parse the data and keep a subagent that extract out entities
- We can iterate over entities and use "examine, consider" and other non-dangerous commmands
- We can return structured JSON and the upset this into an SQLITE table.
- We could consider using a local models that is even more cost effective than Haiku but we will stick with Haiku for now.

### Step 4: Subtask Delegation

We need to define a new "task" in our settings.yml called room_inspector.
We will have our player agent call a tool "inspect_room" which in turns will
will call MCP calls to MudManager and have our RoomInspector agent parse the contents.

- Claude suggested that it make MCP calls and just pass the raw data to RoomInspector and no tool use, I disagreed that it RoomInspector should have ownership of calling the MudManager, it should share the Telnet session since only one "task" should run at a time, and I want my player to be the orchestrator and want it to avoid making multiple tool calls when it can delegate out.
- Before even testing now I had a concern of allowing the player having access to "look" command to force it to select inspect_room tool

### Step 5 Allow List (Tool Permissions)

I asked Claude Opus to write me tool permissions. It took multiple iterations since it kept making poor assumptions:
- it only allowed MCP tools to have permissions, I had to tell it all tools define needs permission
- It create allow, deny, and permit, where the last was for graunlar permissions, this was really confusing, so I said only have allow, and by default a task has no tools.
- It updated the settings.yml with a large list of tool commands, I noticed there are many "item" commands "get_item", "drop_item" where other tools are rolled up into single tool calls with parameters, Claude thinks this is fine and 26 tools is not a lot, but I am tempting to roll all items tool into an "item" tool call.
- I decided to not let the playe have access to send_raw so it reasons based on the tools it has.
- We don't have like Claude's API to tell our agent it has to use a tool, or use at least one tool, which is a common tool permission.
- Claude was really confused about what snytax format to use for the permissions, and I did tell it determine the shape of permissions since we want to full granular control and dont want permissions to be brittle.
- I did test asking Claude to move without having the ability to move and it determined it couldn't moved and didn't waste calls.
- for some reason Cluade decided to remove the prefix for tools from MCP and I told it needs to have explict naming to avoid conflicts.
  - I discovered that prefixes are aded in our settings.yml when adding mcp so we have control avoid scoping issue in the future.

## Step 6: Fast Rebuild

I keep forgetting to rebuild my gems, so I created a ascript called .week2_capable/bin/rebuild
to rebuild the mud_manager and boukensha.

## Step 7: Test inspect_room

⠦ Calling tool: inspect_room  (iter 1/25 · 37s · ↑ 3.1k · ↓ 65 · 1 calls)
Calling "inspect_room" is really slow.

- When we move to a new area with move it always "look" information if we want it or not.
  - I dont know if this gets ingested by the LLM on that turn or next so it might not matter.

- [inspect_room_1](./artifacts/inspect_room_1.json)
- [inspect_room_1](./artifacts/inspect_room_2.json)

- Does the agent actually see the response from the subtask?
- In our log_viz we have no sense of time since its not visualized, not even timestamps or duration
- it seems parsing to json is the most expensive task
- the subtask has its own token usage, does it include that in our overall limits?
- it moved several times without calling inspect_room for new rooms navigating blind again
- it never found the bakery this time.
- We can't tell whats going on in a tool call since there is no logging setup
- We could probably use a seperate log of just calls to mud manager so we can see the real underlying calls.

Its concerning that the json part is so painful to debug.

## Step 8: Improved Observability Tool
We obviously need better obserability, the sintra app is fine, but we also have another one to visualize the mud data.
We should just have a single mud monitor:
- see mud manager logs
- see world data visualization
- see agent sessions
I'll create a new plan [mud_monitor](../plans/week2/mud_monitor.md)
Considerable amount of arugments planning with Claude Opus but I told it I want logs at:
  - telnet session raw output
  - mud manager api calls
  - agent sessions
It didn't like security for passwords, or size of logs, but they are okay for our development usecase.
It broke it plan to mud_monitor into 10 phases, Im not sure how much confidence I have in to do that much work.
I only had to run to phase 6, after implementation we discovered that each subtask will spawn a new log/session and thats a problems so I asked Claude to fix it.

-  http://localhost:5173/sessions/20260722T231230Z-e16fba10, It says 35s from delegating to the subtask, I dont think the subtask adds up to 35s but there is more time being sent doing useless things, I was expecting the subtask only doing parsing but iterally doing its own loop instead of a single turn calling consider and exmaine which is going to consume more time then just a script that will iterate through them.

## Step 9: (NLP Lookup Candidaites) ~ Fix Implementation of RoomInspector and Add Skill for Troubleshooting

We have more rich logging and might be a good idea to create a slash command skill /mud-debug that is aware of our telnet logs, mud manager logs, agent logs. It already naturally does this but better guidance could have better results.

I thought about it and it seems like an NLP solution must be possible that would very performant.
We can just create test and validation data for world data and create own data to test it.

AI proposed three NLP solutions, and I didn't trust them, and asked to make test data and validation from world data, and all three of its test failed, not because NLP can't work its just its overconfident without testing.

I left Claude Opus running with dangerously permissions and it 

         Model         │ params │ PR-AUC │ best F1 │
├───────────────────────┼────────┼────────┼─────────┤
│ BERT-mini, no context │  11.2M │  14.2% │   18.9% │
├───────────────────────┼────────┼────────┼─────────┤
│ BERT-mini + context   │  11.2M │  15.8% │   21.8% │
├───────────────────────┼────────┼────────┼─────────┤
│ BERT-small + context  │    29M │  18.0% │   22.6% │
├───────────────────────┼────────┼────────┼─────────┤
│ BERT-medium + context │    41M │  19.2% │   23.1% │
├───────────────────────┼────────┼────────┼─────────┤
│ BERT-base + context   │   110M │  21.9% │   23.5% │
│                      │   P   │   R   │  F1   │  speaks in   │
├──────────────────────┼───────┼───────┼───────┼──────────────┤
│ qwen3.5 7B zero-shot │  9.2% │ 25.9% │ 13.5% │ 45% of rooms │
├──────────────────────┼───────┼───────┼───────┼──────────────┤
│ BERT-medium 41M      │ 19.4% │ 30.9% │ 23.9% │ 21% of rooms │

And its results it summarized with qwen wasn't good, and BERT Medium 41M beat out qwen, but qwen didn't have thinking on and it could thinking could make it slow. BERT-medium they said it could detect 1/3 candidates in a room but 87% of the rooms were empty. I think we need to seperate out all the teleporter room data, or just load CircleMud's dataset which will give us a reaslitc dataset. I think it was also saying we should just determine if we think the room is empty. 

We never tested haiku's ability to detech candidaites.

It checked only walkable rooms and now it says it when from 2 in 5 to 1 in 5. ITs stats changed but isays it doest better.

┌──────────────────────────────────┬─────────┬────────┐
│                                  │ best F1 │ PR-AUC │
├──────────────────────────────────┼─────────┼────────┤
│ BERT-base, all rooms (110M)      │   23.5% │  21.9% │
├──────────────────────────────────┼─────────┼────────┤
│ BERT-medium, all rooms (41M)     │   23.1% │  19.2% │
├──────────────────────────────────┼─────────┼────────┤
│ BERT-medium, walkable only (41M) │   28.1% │  27.5% │

detection is a dial you pick, not a fixed number:
┌─────────────────────────────┬─────────────┬───────────┬───────┐
│          strategy           │ probes/room │ time/room │ finds │
├─────────────────────────────┼─────────────┼───────────┼───────┤
│ probe every word (no model) │        20.4 │     24.5s │ 89.5% │
├─────────────────────────────┼─────────────┼───────────┼───────┤
│ model, top-3, no gate       │         3.0 │      3.6s │ 80.4% │
├─────────────────────────────┼─────────────┼───────────┼───────┤
│ model, top-3, score ≥0.3    │        0.35 │      0.4s │ 24.5% │
├─────────────────────────────┼─────────────┼───────────┼───────┤
│ model, top-1, score ≥0.9    │        0.18 │      0.2s │ 18.2% │
├─────────────────────────────┼─────────────┼───────────┼───────┤
│ no feature                  │           0 │
└─────────────────────────────┴─────────────┴───────────┴───────┘

Okay so basically Top-3 no gate with 3 probs would get 80% there with 3.6s

│                  │ precision │ recall │
├──────────────────┼───────────┼────────┤
│ Trained model    │     30.2% │  24.5% │
├──────────────────┼───────────┼────────┤
│ Haiku (best arm) │     20.3% │  38.5% │
Haiku wasn't better and our trained model obviously performed better at $0 cost and is much faster.
The truth is we probably don't need to catch everything, but we need to figure out when we get stuck then use reasoning and that can do deeper probes of reasoning and we would at that point have the room descriptions stored in our db to do a lookup without evoking the MUD.

I had it write a journal in our SHRED format in docs/plans/week_2/nlp_look_candidaites/JOURNAL.md

I never implemented the troubleshooter and we spend out time jsut focused on the look_candidates

## Step 10 - Integrate Look Candididates Into our RoomInspector

So we have a possible solution with our trained model
We also need to parse json manually

New plan at: docs/plans/week_2/look_candidates_runtime

I had it implement the new room_inspector.
It did expose tools with settings, which I guess is fine.
Extractor appears to be the model itself in the codebase
I have no observed the room_inspector run but claude is saying:
- Was slow: 33.8s per room. Now: ~5s. Could be ~0.5s.
It thinks the TUI redraws every 60ms and its adding a delay.

We will need to perform a test with and without the tui.

I performed without the tui and it performed incredibly fast
the mud monitor doesn't show total duration for a session so I will have to add that
I will then need to perform with and without tui

When an agent moved it has the print out of the room, and I wonder if that gets
injested back into the message history and does our tool call end up back in the tool history
so could we ideally remove from the message history.

We also have no way of seeing what the current message history looks like.
ingested at each step, I wonder if thats something we can capture of that would be too expensive to do.

I notice in some runs it just goes back to moving without actually calling inspect_room.
We need some kind of way to fix this.

## Step 11 - Message History
I asked Claude to add to mud monitor a button within the Mud Monitor in a session when a request is made to show me the contents of that requests, since that is a gaurntee of what the agent is consuming in terms of tokens so I can decide if anything need to be trimed down.

I notice still my agent calling move and not inspect_room.

I am going to ask Claude to try and show token count for input eg. system prompt how much it is, or other granualary lines.

When a move returns a location

Now that I can see how much tokens I am using per call I beg the question:
- is it better to put a cap on accumlative max token budget or how much a single session call grows:
  - eg. cumalitive stop at 60K tokens or single request 6k tokens.

## Step 12 The Move Issue
- I wanted confidence that the tool results can be reasoned upon and yet it does if its in the message history.
- its not listening to do inspect_room before moving
  - what we will need to do is limit its tools, generic agents don't do this but we have full control of our loop.
  - so we can check if we don't have an entry for the current area.

A few ways to fix the move issue:
  - have our own move that will then call the tbamud_move and have code that can will check our memory where we currently art and whether it will permit the move or not
  - create generic before and after hooks on any tool call, basically doing the same as above but more flexbile
  - somehow limit tool calls conditionally, I guess this would have to indiciate state change of world or player data which only can observe through our local memory store.

I think we need lifecycle hooks:
  before_agent_call
  before_tool_call
  after_tool_call

Before we can create the lifecycle hooks I think we actually need to store something in the db, at least our current location and a rooms table. Actually I think we will need to implement both.

We really do need the most condensed version of data to the agent, most description is describing where things are but we have pure exit information. Can we boil down the descriptiWon without a heavy LLM call?UI

We have a new plan execute at docs/plans/week_2/basic_memory.md

We need to test it and see what gets written to the db.
I think we should have a db viewer in the mud monitor 


## Step 13 Database Preview Mud Monitor
Obviously I should be able to use VSCode extension or thirdy party program but its not working.
So I will simply have in the mud monitor a way of observing the data there.

We have now a knowledge tab, with overview of player stats, room, entities and frontier, not sure what frontier means.
I need to determine if how we are giving the agent context of the location before it acts.

Frontier is an edge and not a room. A direction the agent has seen but never walked.

It appears that it does update as it goes but I'll have to investage the code closely for how its implemented.

I would really like a visual of what it thinks it sees as a map, and possibly
overlayed against the world data we do know of. The only thing is that they could end up constructing a different map than what we know.

## 14 Step IbnouT Adaption of Mud Observer

Our bootcamper IbnouT created an impressive realtime mud observer which show the map with movements
and vital stats and tasks in realtime.

I reviewed the plan and I don't know how that plan drove it or if a model like fable was used.
I had claude reverse engineer it into technical spec, and the second step will be to have it adapt
that plan based on my projects requirements. Some functionality we do not have currently is task management
so we cannot fully realize that exact implementaiton yet.

While I have an updated plan I noticed I am missing vitials.
We really should have a score check often to update vitals.
So before I execute this plan I want to fix that issue.

doc/plans/week_2/mud_observer

## 14 CDC

While exploring to capture player data in the database, I realize I probably want Change Capture Data logging
THis is so we can see progressing of leveling, or items added or removed. We are mostly interested in player data
but I suppose we can make it generic enough to capture any change.

If we switch to postgres we would get this first class or probably as an extension but I'm trying to keep things
self contained to just the SQLITE file since its portable.

doc/plans/week_2/change_capture

The agent has concerned about jittery values and did not implement my full generic CDC.
But I told it to do as I say and I will decide how to solve noise if that occurs.
Honestly things like HP are not a concern because an agent doesn't activity poll watching a battle
or if it does not fast or it runs out of tokens.

It did create ticker graphs under progressiong but HP did not appear to be working but they say it does.
I can' tell right now until we progress further.

I notice it didn't add invetory, equipment, skills or other player information because it was like "you have no exp, no levels and nothing
so why build that out?" So I will make a script to create a new player and give them stuff via the admin user.

##  15 Populated Player Creation Script and Player Scopying

While I did create a script a plan to seed a player with data
doc/plans/week_2/seed_player.md

The only problem is that our knowledge base thinks there is only one user that exits.
We have to right now handle scoping for another player.

I decided to have profiles within .bounkensha and we will have its own database and log files.
I have a drop down in Mud Monitor to change players.
You have to specify --profile to boukensha.

docs/plans/week_2/player_scoping.md

Okay we need to now update our seed_player script how is it going to know what to call the player, password and how much to populate it with?
It would be ideal if we had an agent that had access to admin commands but that sounds like alot of work.

I mean there is no reason I can't have the admin as a profile, I was just thinking
it wouldn't be optimal, but if I did I would need to have prompt override for player so it knows
that its an admin and policy at the profile layer or a flag that its an admin player so it has conditional access to admin commands.
I'll circle back to this some other time.


## 16 Player Update
We want in our hook oupdate the vitals information, inventory and etc,
We updated the schema, and now have a player tab in the knowledge tab in mud monitor.
I don't know if it actually works as expected yet.

doc/plans/week_2/player_update

I want to first a visualize of room layouts tab in knowledge and then I will take the time verify
a new end to end bakery route. I suspect that look, score and other commands are needlessly being
run, and so I want to make sure we are collecting information correctly after next step.

## 17 Known Map

We want a new knowledge->Map
It should show rooms and exits, and indicate frontiers yet explored. 
It would be nice to be able to see targets and entities
It would be nice if the nodes are orgranized based on their actual positioning

docs/plans/week_2/knowledge_map.md

## 18 Review Pathing

Now with all my observability I can reset the player and find the bakery
http://localhost:5173/sessions/20260724T221941Z-e99aa04f

Observations
Iteration 0
- the agent should not have to check 'score' manually as hooks should collect information
  - context about the user should have been injected already from our memory
  - we might want to remove score from our tool list to stop it
  - 1.9s seems really slow
Iteration 1
- look should have not been called, since inspect_room gets us all the information we need
  - if we need to deeper search that would be a future logic step and it would just search across the knowledgebase of room descriptions
Did the agent actually call score or look or is this our underling calls from RoomParser
I don't think we updated anyway to expose that kind of logging of RoomParser into the Agent Session
Request 1:
it doesn't show those two tool calls look and score so maybe it is RoomParser

```sh
[here] The Temple Of Midgaard  (visit 6)
exits: d→The Temple Square ? | e→The Midgaard Donation Room ✓ | n→By The Temple Altar ✓ | s→The Temple Square ✓ | w→The Reading Room ?
here: Admin the Implementor (linkless) is standing here. (mob) | Derrano the Minister (linkless) is standing here. (mob) | An automatic teller machine has been installed in the wall here. (object)
you: 20/20hp 100mana 85mv · lvl 1 · 0 gold · standing
```
Is this summary optimal, maybe we should let our agent know of the template in the system prompt
or have a legend, might allow us to have more compact summary for multiple messages.
Iternation 2
- tbamud_move is called, and see the full description but in the request 2 we see 'moved west → The Reading Room'
  - we obviously want the latter but why wouldn't this be shown in our tbamud_move, did we wrap tbamud_move with a native move tool or there is a hook.
    - it should better reflect in the actual session so its not confusing.
Iteration 3
tbamud__move(direction: "d") error: error [argument_error]: invalid direction: "d" (expected one of north, east, south, west, up, down)
  - why is this invalid? seems like it would be down, maybe when navigating it should use at least two character or whatever will avoid this issue.
Iteration 4
- the agent thanks us for the context, what context is it even talking about? did we insert something we donk't see let me check the requests.

Request 4
```txt
user
tool_result · toolu_01JgqvJLYvpzpPR6LSbg59pd
error: error [argument_error]: invalid direction: "d" (expected one of north, east, south, west, up, down)
user
[here] The Temple Of Midgaard  (visit 7)
exits: d→The Temple Square ? | e→The Midgaard Donation Room ✓ | n→By The Temple Altar ✓ | s→The Temple Square ✓ | w→The Reading Room ✓
here: Admin the Implementor (linkless) is standing here. (mob) | Derrano the Minister (linkless) is standing here. (mob) | An automatic teller machine has been installed in the wall here. (object)
you: 20/20hp 100mana 83mv · lvl 1 · 0 gold · standing
```
- Yep it clearly does give context, but this doesn't show up during our main session information.

Okay so the main conclusion:
- If a agent is trying to find a destination we need a tool_call to: "plan_route"
  - If we already know of the location in the map it should return back the route
  - If the location is not known it should best reason where to look
    - this is where it would make sense to spawn tasks
  - It could be we dont know anything, so then we need broad strategy to explore

docs/plans/week_2/observ_improvements.

## 19 Spans and Traces with Observsation

We have still not moved onto plan_route because I can't see things like:
- the BERT medium call, the actualy details of room survey
So explained to Claude I ned that level of visibility and we need to group related workloads tha I can expand and I need to be able to see db writes in my sessions and it argued we need spans and traces via an Obseveration class.

 docs/plans/week_2/work_attribution.md

It implemented and we do see grouping of work but room surevy I dont see at all, maybe they just didn't implement it mud monitor.

It seems we would greatly benefit from instruementation and will require signfant upheavel
I cannot tell what the UX will look like aftwards but Im going to give it a rip.

## 20 OTel 

I want to be able to use any OTEL compatabile tool.
Lets see if we can upgrade proper

docs/plans/week_2/otel.md

It implemented multiple solutions like Jaeger.
When starting up my MUD I started to get hook errors
I realized I have a observablity gap is my agent runs into errors it doesn't log them

## 21 Agent error logs

We want agent error logs and to see the in our mud monitor
We should now be able to see errors capture with their backtraces in ~/boukensha/profiles/<profile>/error.log

docs/plans/week_2/error_log.md

## Step 22 - Better Bespoke Waterfall

I did review the graphana, tempo and jaeger and these are not going 
give me what I want, which is a waterfall with rich information so I can understand the player journey. Its not a waste that we implemented OTEL and the OTEL infrastructure can be turend off anytime. 

It did break out transcript, so we need to fix that first, its because of the data cchange.

docs/plans/week_2/fix_transcripts.md
Codex Just did not understand that I wanted a tree like structuer for stories
It was getting hung up on waterfall information and made the view simply something we already with had with Jageer

I moved over to Opus 5 and told it my problems and it wrote me a plan that looked ideal.
It appears to know what I brought back.
docs/plans/week_2/session_story_tree

We have a new kind of view but it doesn't work. 
My effort to try and make it easier to consume failed and our original tarnscript was better
Having the traces and spans built in are not useful and now we have graphana and jaeger as a method.

I want it to go back and fix my old view and remove the traces.

 docs/plans/week_2/restore_transcript_view.md.

## Technical Conclusions
There is clearly a considerable amount of observability that needs to be implemented before implementing our custom capable loop. We couldn't anwser our hypothises because of this detour.

OTEL was a very cheap layers of observability, however at this time I dont find having otel of any advantage with could native tooling since it doesn't anwser questions on what happening in the loop but more so about performance. This could be valuable for production use case.

OTEL is not standardized for AI Agent and there is no AI Agent observability tool that will really help us for our specialized agent.

Hooks are obviously integral to getting the agent what you want to do.

## Key Takeaway
If you want to know what you agent is doing, you need to build a bespoke loop story eg. Sessions Show page. that you can walk the entire scope of the agent is doing to help reason what it does, there' no off the self solution


# AI Journal Rollup

• I found several implemented features that were missing from the original 14-step summary. 
I also separated completed work from research and plans that were not implemented.

  1. Benchmark navigation cost to expose why the agent could not reliably reach the bakery.
      - Ran repeated start-to-bakery navigation sessions.
      - Observed runs consuming roughly 65K tokens without reaching the destination.
      - Identified missing exit knowledge, repeated room reasoning, and manual resets.
      - Used those failures to drive automated resets and structured room inspection.

  2. Automate player resets so navigation experiments are repeatable.
      - Added bin/move_player_to_start_room.
      - Added Mud Manager admin primitives needed to relocate another player.
      - Logged in both the mortal and administrator to perform the reset.
      - Made it possible to rerun the same navigation benchmark from a known state.

  3. Collect complete room information before choosing the next movement.
      - Combined room descriptions with full exit destination information.
      - Confirmed that look only provides exit directions, while exits provides destination names.
      - Investigated entities, hidden scenery, asynchronous room activity, and player vitals.
      - Initially built a composite inspection command, then moved composition into Boukensha policy.

  4. Delegate room investigation so the player remains focused on orchestration.
      - Added a room_inspector task and prompt.
      - Added a native inspect_room tool to invoke that task.
      - Shared the existing MCP/Telnet session between the player and delegated task.
      - Let the inspector call MUD tools directly instead of receiving copied raw output.
      - Added mob appraisal using consider and examine.
      - Later removed the model-driven subagent from the inspection path when deterministic processing proved faster.

  5. Restrict tools so each task can only perform its intended role.
      - Added default-deny allow: rules per task.
      - Added parameter-level rules such as restricting check to specific kinds.
      - Validated permission rules against each tool’s schema during startup.
      - Preserved explicit MCP prefixes to prevent naming conflicts.
      - Enforced permissions during both tool advertisement and dispatch.
      - Later moved permission enforcement into the registry so native tools were also gated.

  6. Shorten the development feedback loop.
      - Added week2_capable/bin/rebuild.
      - Rebuilt the Boukensha and Mud Manager gems together.
      - Reduced errors caused by testing stale local gem builds.

  7. Test room inspection and identify where the first design failed.
      - Captured real inspect_room outputs as journal artifacts.
      - Measured inspection calls taking roughly 30–35 seconds.
      - Found that delegated inspection was running a full agent loop instead of a focused parse.
      - Found that the player sometimes moved without inspecting the new room.
      - Exposed missing visibility into delegated calls, durations, and token accounting.
      - Used these failures to drive Mud Monitor and deterministic room surveying.

  8. Build unified observability before optimizing further.
      - Created Mud Monitor with a Rails API and React frontend.
      - Added agent-session, manager-command, and raw Telnet views.
      - Added timestamps, durations, live polling, filtering, and session details.
      - Correlated agent tool calls with the underlying MUD commands.
      - Kept delegated work inside the parent session and labeled it by task.
      - Added health checks and configurable log/database locations.
      - Fixed manager and Telnet log path resolution.

  9. Find a faster and cheaper way to detect hidden room interactions.
      - Extracted supervised training data from the MUD’s world files.
      - Built frozen train/test splits and reachable-room filtering.
      - Compared lexicons, hand-built features, BERT variants, Qwen, and Haiku.
      - Discovered that context matters because the same word can be interactive in one room but not another.
      - Found and corrected evaluation problems involving unreachable rooms, data leakage, and model inputs.
      - Determined that a trained local model outperformed the tested LLM approaches for this task.
      - Built a reproducible model-training and evaluation pipeline.
      - Documented the dataset, experiments, results, and model design.

  10. Replace slow agentic room inspection with a deterministic survey pipeline.

  - Shipped an int8 BERT-medium model for look_candidates.
  - Exported the model to ONNX and ran it directly from Ruby.
  - Verified Ruby/Python token and score parity.
  - Stored the model threshold and metadata in a manifest.
  - Added model download, verification, and status tasks.
  - Replaced the Room Inspector subagent with one deterministic InspectRoom implementation.
  - Added fixed poll, look, exits, consider, and examine sequencing.
  - Added colour-based mob/object classification, deduplication, keyword verification, and retries.
  - Reduced the warm inspection path to zero LLM calls.
  - Confirmed the TUI—not the model—was creating much of the observed latency.

  11. Expose exactly what the model consumes on every request.

  - Added request-level message inspection to Mud Monitor.
  - Reconstructed message timelines from complete prompt snapshots.
  - Added a sidebar showing system, user, assistant, and tool messages.
  - Handled message additions, compaction, and cleared histories.
  - Added token counts by message and request section.
  - Added pricing estimates and clearer cumulative token usage.
  - Made injected context visible instead of leaving it hidden from the session view.

  12. Add lifecycle control and memory so inspection is enforced by the loop.

  - Added generic lifecycle hooks around turns and tool calls.
  - Added automatic room surveying before model calls.
  - Added a SQLite knowledge store using WAL mode.
  - Added tables for player state, rooms, exits, entities, sightings, and encounters.
  - Added room fingerprinting and exit linking.
  - Added current-location tracking and visit counts.
  - Added frontier tracking for exits that had been seen but not walked.
  - Injected a compact [here] state block before each model call.
  - Replaced large raw room outputs with condensed movement and state summaries.
  - Added stale-state handling and survey rules after movement.

  13. Visualize stored knowledge so memory behavior can be verified.

  - Added a Knowledge section to Mud Monitor.
  - Added overview, rooms, entities, frontier, and player views.
  - Read the live SQLite database without introducing ActiveRecord.
  - Added WAL-aware freshness checks and schema-version handling.
  - Displayed room confidence, visits, exits, entities, and survey times.
  - Clarified that a frontier represents an unexplored exit, not an unexplored room.

  14. Explore a real-time observer inspired by IbnouT’s implementation.

  - Reverse-engineered the bootcamper’s observer into a technical specification.
  - Adapted the design to Boukensha’s knowledge store and available runtime data.
  - Designed a combined map, vitals, trail, activity feed, and thought display.
  - Identified missing vitals and task-management data.
  - Produced an implementation plan, but the full Observatory view was not built.

  15. Capture changes over time instead of storing only the latest state.

  - Added an append-only JSONL change journal.
  - Captured every knowledge-store mutation at the store layer.
  - Recorded before/after values while suppressing unchanged writes.
  - Captured room, exit, entity, encounter, player, death, level-up, and item events.
  - Added sequence numbers, timestamps, session attribution, and restart continuity.
  - Added a Progression view with time-series charts and a raw change log.
  - Captured changing HP, mana, and movement values instead of pre-filtering them.

  16. Create populated test players and isolate their state.

  - Added bin/seed_player as a deterministic development harness.
  - Deleted and recreated the configured player on every run.
  - Added Mud Manager character-seeding and administrator primitives.
  - Seeded level, money, stats, skills, inventory, and equipment.
  - Verified the resulting character through live MUD output.
  - Added optional fixture generation for parser development.
  - Added named Boukensha profiles with separate databases and logs.
  - Added --profile selection to Boukensha.
  - Added a player-profile selector to Mud Monitor.
  - Kept shared models, prompts, and installation settings outside profile state.

  17. Expand player memory beyond basic vitals.

  - Extended the schema for score data, skills, inventory, and equipment.
  - Captured live fixtures from a seeded level-10 cleric.
  - Added parsers for score, practice, inventory, and equipment.
  - Accounted for this MUD’s actual wording instead of assumed CircleMUD formats.
  - Reused already-issued commands to avoid extra network round trips.
  - Marked inventory state stale when mutations could not be verified.
  - Added a Player view under Knowledge.

  18. Add a map of what the agent currently knows.

  - Added /knowledge/map to Mud Monitor.
  - Built the map entirely from the existing knowledge endpoint.
  - Positioned connected rooms using deterministic grid-based BFS layout.
  - Displayed room names, internal IDs, visits, entities, and look targets.
  - Highlighted the current room.
  - Rendered explored connections and unexplored frontiers differently.
  - Added zooming, panning, disconnected-component handling, and layout tests.
  - Exposed malformed exit-direction data discovered during visualization.

  19. Review a complete bakery run and identify the next navigation problem.

  - Reset the player and ran another end-to-end bakery attempt.
  - Confirmed automatic context injection and compact movement summaries.
  - Found redundant-looking score and look work originating from hooks.
  - Found that automatic work was not clearly distinguished from model-selected tools.
  - Found invalid abbreviated movement arguments such as d.
  - Concluded that navigation needed an explicit plan_route tool.
  - Designed known-route, frontier-ranking, and broad-exploration behavior.
  - Produced the route-planning specification, but did not implement the tool.

  20. Attribute hidden automatic work to the turn that caused it.

  - Added provenance to automatic context work and tool calls.
  - Grouped room surveys and hook activity into expandable operations.
  - Added operation IDs, parent IDs, nesting, timing, and outcome data.
  - Logged local look-candidate model duration and output counts.
  - Joined knowledge-store journal writes back into the relevant session.
  - Added visibility into automatic room surveys and database mutations.

  21. Convert operation logs into structured traces.

  - Instrumented turns, iterations, LLM generation, tool execution, hooks, compaction, and wrap-up.
  - Added nested span trees and duration waterfalls to Mud Monitor.
  - Propagated trace context across MCP boundaries.
  - Recorded errors and incomplete operations.
  - Added a waterfall interface for understanding where each turn spent its time.
  - Preserved detailed JSONL logs alongside the new trace structure.

  22. Export traces through OpenTelemetry.

  - Added an optional OpenTelemetry telemetry backend.
  - Exported spans through OTLP while retaining existing JSONL logging.
  - Added trace attributes, parentage, durations, errors, and status recording.
  - Added local Collector configurations for Jaeger, Tempo, and debug output.
  - Added Docker Compose observability infrastructure and Grafana provisioning.
  - Added telemetry contract tests and a no-op backend when tracing is disabled.