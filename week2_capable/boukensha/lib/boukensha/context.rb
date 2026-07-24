require_relative "tool"
require_relative "message"

module Boukensha
  class Context
    attr_reader :system, :messages, :tools, :context_window, :working_dir,
                :turn_tokens, :compaction_threshold
    attr_accessor :current_tokens

    # Volatile state the agent should reason over RIGHT NOW — where it is, what
    # is in the room with it, how much HP it has.
    #
    # Deliberately not a message. A tool_result is appended to @messages
    # forever and re-sent on every subsequent API call, so eleven room surveys
    # means the eleventh call carries all ten previous rooms' full prose (~1,740
    # tokens in the sampled session, and growing). Compaction eventually clears
    # them by throwing away the OLDEST memories — precisely the rooms nearest
    # the start of an exploration.
    #
    # A state block lives here instead: re-rendered before each model call, in
    # exactly one copy that is always current, never duplicated, never stale,
    # never compacted away. ~45 tokens, flat, however long the walk gets.
    #
    # It renders at the TAIL of the request, after any prompt-cache breakpoint
    # on the system+tools+history prefix, so rewriting it every iteration costs
    # nothing in cache terms.
    attr_accessor :state_block

    # An optional Permissions computed for THIS iteration — e.g. `move` pinned
    # to the directions the MUD just printed on the exits line. It may only ever
    # NARROW: a call must satisfy both the task's `allow:` block and this, and
    # this can never grant something settings.yaml didn't.
    attr_accessor :turn_policy

    def initialize(system:, context_window: 200_000, working_dir: nil, compaction_threshold: 0.85)
      @system               = system
      @context_window       = context_window
      @working_dir          = working_dir ? File.expand_path(working_dir) : nil
      @compaction_threshold = compaction_threshold
      @messages             = []
      @tools                = {}
      @current_tokens       = 0
      @turn_tokens          = 0
    end

    def register_tool(tool)
      @tools[tool.name] = tool
    end

    def add_message(role, content, tool_use_id: nil)
      @messages << Message.new(role, content, tool_use_id)
    end

    # What actually goes on the wire: the conversation, plus the state block as
    # a trailing user turn if one is set.
    #
    # Built fresh on every read and never stored, which is the entire trick —
    # @messages stays the pure transcript (so compaction, /clear and the turn
    # counter all keep meaning what they meant), and the state block can be
    # rewritten between iterations without leaving a trail of stale copies
    # behind it.
    def request_messages
      return @messages if @state_block.nil? || @state_block.to_s.strip.empty?

      @messages + [Message.new(:user, @state_block.to_s, nil)]
    end

    # The tools to advertise this iteration. `turn_policy` may hide a tool the
    # task allows; it can never reveal one the task doesn't.
    def advertised_tools
      return @tools if @turn_policy.nil?

      @tools.select { |name, _| @turn_policy.allow_tool?(name) }
    end

    # Update the known context size from the last API response's input_tokens.
    def update_tokens(n)
      @current_tokens = n.to_i
    end

    # Reset the cumulative per-turn spend counter. Called at the top of a turn.
    def reset_turn_tokens
      @turn_tokens = 0
    end

    # Add one API call's input+output tokens to the cumulative per-turn total.
    # This is the spend budget — distinct from current_tokens (window pressure).
    def add_turn_tokens(input, output)
      @turn_tokens += input.to_i + output.to_i
    end

    # Fraction of the context window currently in use (0.0–1.0).
    def usage_fraction
      @context_window > 0 ? @current_tokens.to_f / @context_window : 0.0
    end

    # Integer percentage (0–100).
    def usage_pct
      (usage_fraction * 100).round
    end

    # True when we should compact before the next API call. Defaults to the
    # configured compaction_threshold (a fraction of context_window).
    def needs_compaction?(threshold: compaction_threshold)
      usage_fraction >= threshold
    end

    # Drop the oldest 40% of messages to free space, keeping at least 2.
    # Resets current_tokens to 0 (will be updated by the next API response).
    # Returns the number of messages dropped.
    def compact_messages!(target_fraction: 0.60)
      drop_count = [(@messages.size * 0.40).ceil, @messages.size - 2].min
      drop_count = [drop_count, 0].max
      @messages = @messages.drop(drop_count)
      @current_tokens = 0
      drop_count
    end

    # Drop all conversation history, keeping tools and system prompt intact.
    def clear_messages!
      @messages = []
      @current_tokens = 0
    end

    def tool_count = @tools.size
    def turn_count = @messages.size

    def to_s
      "#<Context turns=#{turn_count} tools=#{tool_count} window=#{context_window} current=#{current_tokens}>"
    end
  end
end
