# OTEL acceptance fixture

The deterministic acceptance session has `session_id=session-fixture` and two
top-level turns. Both traces carry `session.id=session-fixture` and
`boukensha.session_id=session-fixture`; they have different trace IDs and no
parent relationship.

```text
trace A
└── invoke_agent player
    ├── boukensha.iteration
    │   ├── player_bootstrap
    │   │   └── execute_tool score          initiator=hook, success
    │   ├── chat fixture-model              successful usage
    │   ├── execute_tool move               initiator=model, success
    │   └── execute_tool fail               initiator=model, error status
    └── invoke_agent inspector
        └── chat fixture-model

trace B
└── invoke_agent player
    ├── boukensha.iteration
    │   └── chat fixture-model
    └── boukensha.wrap_up                    max_iterations
        └── chat fixture-model
```

Every JSONL record inside an operation has a 32-character lowercase hex
`trace_id` and 16-character lowercase hex `span_id`. `session_start` and
records between turns omit both. Failed spans record the exception, error
status, and `error.type`. Tool metadata includes name, initiator, and call ID;
model metadata includes provider, request model, finish reason, token usage,
and estimated cost when available. Prompt, arguments, results, room content,
credentials, and reasoning text are absent from OTEL by default.

