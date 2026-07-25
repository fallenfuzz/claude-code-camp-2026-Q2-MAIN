# Agent lifecycle hooks

The agent exposes five lifecycle seams. A user turn can contain multiple model
iterations, and each model iteration can contain a batch of multiple tool calls.

```mermaid
flowchart TD
    turn_start([User turn starts])
    before_turn["before_turn(context)<br/>Once per user turn"]
    before_model["before_model(context)<br/>Once per model iteration"]
    call_model[Call model with current context]
    response_kind{Tool calls requested?}
    before_tools["before_tools(calls, context)<br/>Once per tool batch"]
    dispatch_tool[Dispatch next tool]
    raw_result[Receive raw tool result]
    after_tool["after_tool(name, args, result, context)<br/>Once per tool"]
    add_context[Add original or transformed result to context]
    batch_remaining{Another tool in this batch?}
    after_turn["after_turn(context, text)<br/>Once before returning"]
    turn_end([Return final response])

    turn_start --> before_turn
    before_turn --> before_model
    before_model --> call_model
    call_model --> response_kind
    response_kind -- Yes --> before_tools
    before_tools --> dispatch_tool
    dispatch_tool --> raw_result
    raw_result --> after_tool
    after_tool --> add_context
    add_context --> batch_remaining
    batch_remaining -- Yes --> dispatch_tool
    batch_remaining -- No --> before_model
    response_kind -- No --> after_turn
    after_turn --> turn_end
```

The Week 2 MUD integration currently uses the hooks as follows:

| Hook | Current responsibility |
|---|---|
| `before_turn` | Initialize or refresh player state, including the initial `check(score)`. |
| `before_model` | Establish the current position, survey unknown rooms, and inject current state. |
| `before_tools` | Poll asynchronous MUD output before dispatching a model-selected tool batch. |
| `after_tool` | Update memory from the result and optionally replace the value placed in model context. |
| `after_turn` | Provide a final seam immediately before the agent returns its response. |

The hook interface and its five call sites are described in
[`basic_memory.md`](./basic_memory.md). Observations of the hooks running in a
recorded session are documented in
[`observ_improvements.md`](./observ_improvements.md).
