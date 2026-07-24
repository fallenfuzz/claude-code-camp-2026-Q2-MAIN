module Boukensha
  # Five points in the agent loop where something outside the framework may
  # look, and one of them may speak.
  #
  # This is the whole framework change. Everything else that makes the agent
  # remember rooms is a subclass of this, wired at the entrypoint — because
  # boukensha is an MCP host that ships no tools and knows nothing about MUDs,
  # and a hook seam is the honest way to keep it that way.
  #
  # The default is a null object, so every existing caller, test and
  # entrypoint that never passes `hooks:` behaves exactly as it did.
  #
  # Ordering within one turn:
  #
  #   before_turn                     once, at the top of Agent#run
  #   ┌─ before_model                 EVERY iteration, before the API call
  #   │  (5-7s of inference — async MUD output accumulates here)
  #   │  before_tools                 once per tool-use batch, before dispatch
  #   │  ├─ dispatch                  ← the MUD's own pre-send drain destroys
  #   │  └─ after_tool                  the async window at this exact line
  #   └─ (loop)
  #   after_turn                      once, before the text is returned
  #
  # `before_model` rather than a single coarse `before_turn` refresh is
  # load-bearing: the agent MOVES inside its own loop (56 `move` calls against
  # 28 turns in the sampled sessions), so a room refresh that only fires at turn
  # start means the model reasons about the room it just left.
  #
  # `before_tools` exists for one reason, and it is the only reason: the window
  # between the model's response and the first dispatch is the last moment the
  # output that arrived DURING inference is still in the buffer. One line later
  # the tool's own pre-send drain has thrown it away — including, in the logs,
  # a fight that took the player from 20H to -6H with no command ever issued.
  class Hooks
    def before_turn(context:) = nil

    def before_model(context:) = nil

    # Fires ONCE per tool-use batch, before the first dispatch — not once per
    # call. `calls` is the raw tool_use blocks, for a hook that wants to know
    # what is about to happen.
    def before_tools(calls:, context:) = nil

    # Return nil to keep the tool result as-is, or a String to REPLACE what the
    # model sees. The substitution lands between the logger and the context, so
    # the session log and mud_monitor keep the MUD's exact words while the model
    # gets a stub of whatever the hook has already parsed on its behalf.
    def after_tool(name:, args:, result:, context:) = nil

    def after_turn(context:, text:) = nil
  end
end
