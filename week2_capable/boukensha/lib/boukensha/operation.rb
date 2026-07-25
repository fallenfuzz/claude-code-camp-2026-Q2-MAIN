require "securerandom"

module Boukensha
  # The unit of work, as ambient state.
  #
  # Everything else in the session log is instantaneous — a call, a result, a
  # transform. Nothing said "here is a thing that started, contained other
  # things, and finished". `buildTranscriptTree` compensated by folding *runs of
  # adjacent* hook calls together, and adjacency is a proxy for containment that
  # is wrong in both directions: one model call landing mid-survey splits a
  # single operation into two groups, and a survey's calls sit as siblings of
  # the position refresh they actually ran *inside*.
  #
  # So containment becomes a fact rather than a guess, and this is where it
  # lives. It is a bare thread-local stack rather than an argument threaded
  # through Logger, the dispatcher, RoomSurvey, Store and Journal for the reason
  # Logger's own comment already gives about `task`: a field a call site can
  # forget is a field that goes dead. The argument is stronger here, because
  # there are now TWO writers — Logger and Journal — that must agree on which
  # operation is current, and one call site forgetting to pass it means a CDC
  # line silently attributed to nothing.
  #
  # The cost, named rather than hidden: it is invisible at the call site, and it
  # is per-THREAD. A future concurrent agent gets correct isolation for free; a
  # future fiber scheduler would not, and would need Fiber storage here instead.
  module Operation
    KEY = :boukensha_operation_stack

    # `trigger` is the lifecycle seam the OUTERMOST span fired from, inherited
    # downward: a survey opening inside `before_model` fired from `before_model`
    # too, and making RoomSurvey name a seam it should know nothing about is how
    # a label ends up disagreeing with the truth.
    #
    # `attributes` is the one field a call site fills in DURING the span rather
    # than at open time — `#set` merges into it, and Logger#operation folds the
    # bag into `operation_end` alongside the counter delta. Without it there is
    # nowhere to hang a fact only known once the block is running (the model
    # actually used, the token counts, the room resolved) — Struct's other
    # fields are all decided at `open`.
    Frame = Struct.new(:id, :name, :trigger, :parent_id, :attributes, keyword_init: true) do
      def set(**attrs)
        attributes.merge!(attrs)
      end
    end

    SESSION_KEY = :boukensha_operation_session_id

    class << self
      def stack = (Thread.current[KEY] ||= [])

      # The span a write is happening inside, or nil at top level — which is the
      # honest answer for a tool call the model chose.
      def current       = stack.last
      def current_id    = stack.last&.id
      def current_name  = stack.last&.name

      # Set once by Logger#initialize, read here rather than threaded through
      # every call site that wants it — the same argument as the frame stack
      # itself. Thread-local for the same forward-looking reason the stack is.
      def session_id = Thread.current[SESSION_KEY]

      def session_id=(value)
        Thread.current[SESSION_KEY] = value
      end

      # What crosses the MCP wire in `_meta` so the far side (mud_manager) can
      # stamp its own ManagerLog record with the id of the span that made the
      # call — the correlation `manager_record_serializer.rb` renders as
      # "exact". Empty at top level (a call the model made with nothing open)
      # rather than a hash of nils, so a server that inspects `_meta` sees
      # exactly the keys that are meaningful.
      def wire_meta
        { "boukensha/session_id" => session_id, "boukensha/operation_id" => current_id }.compact
      end

      # Open a span for the duration of the block. Reentrant, and `ensure`
      # RESTORES the predecessor rather than clearing: `room_survey` opens
      # inside `position_refresh`, and a wipe on the way out would send every
      # following call back out unattributed.
      #
      # Used directly only where there is no logger to write the brackets (a
      # test, a degraded boot). Logger#operation is the normal entry point.
      def open(name, trigger: nil)
        frame = Frame.new(id: "op_#{SecureRandom.hex(3)}", name: name.to_s,
                          trigger: (trigger || current&.trigger)&.to_s, parent_id: current_id,
                          attributes: {})
        stack.push(frame)
        begin
          yield frame
        ensure
          stack.pop
        end
      end

      # Test seam. A span left open by a raise that escaped `ensure` would
      # mislabel every later write in the process.
      def reset! = Thread.current[KEY] = []
    end
  end
end
