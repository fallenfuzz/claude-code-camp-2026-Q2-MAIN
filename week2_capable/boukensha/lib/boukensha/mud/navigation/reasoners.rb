require "json"
require_relative "../../tasks/navigator"
require_relative "../../tasks/cartographer"
require_relative "../../tasks/surveyor"

module Boukensha
  module Mud
    module Navigation
      # The two model calls `MoveTo` makes, as plain lambdas: payload hash in,
      # answer hash out.
      #
      # They are lambdas rather than methods on `MoveTo` so the subsystem's own
      # loop, limits, journalling and region writes are all testable against a
      # scripted answer with no model, no network and no key — which is the same
      # trade `RoomSurvey` makes with its injected `call_tool`.
      #
      # Both go through `Boukensha.run_task`, and §2.1's economics follow from
      # what that does: it builds its OWN `Context` and its own `Agent` with its
      # own `max_turn_tokens` from `tasks.<name>` in settings.yaml. The
      # navigator's spend therefore does not land on the player's turn budget,
      # and each call is a fresh small context with no tool-schema prefix and no
      # accumulating transcript.
      #
      # `tools: false` for both, and it matters for the same reason it does for
      # the judge: registering the MUD server for a task that cannot use one
      # would open a second telnet login. Neither of these has tools by design —
      # they answer with fields, and §5.2 is the argument for why.
      module Reasoners
        module_function

        # `logger:` — the PLAYER's logger. Passing it appends the sub-run to the
        # player's session file, bracketed by task_start/task_end, instead of
        # minting a file per decision. Six navigator calls in one `move_to`
        # would otherwise be six session files nothing joins back to the walk
        # they belong to.
        def navigator(logger: nil)
          reasoner(Tasks::Navigator, logger: logger)
        end

        def cartographer(logger: nil)
          reasoner(Tasks::Cartographer, logger: logger)
        end

        # The survey's ledger keeper. Same shape as the other two and for the
        # same reasons, with one difference worth naming: this one is called
        # CONDITIONALLY rather than once per leg, because a leg that discovered
        # no room and settled no claim has nothing to tell it. That is what
        # bounds its cost, and it is why a survey through a dense interior can
        # walk six rooms on a single call.
        def surveyor(logger: nil)
          reasoner(Tasks::Surveyor, logger: logger)
        end

        def reasoner(task_class, logger: nil)
          lambda do |payload|
            raw = Boukensha.run_task(task_class, JSON.pretty_generate(payload),
                                     logger: logger, tools: false)
            parse(raw)
          end
        end

        # Strict about the shape, tolerant about the packaging — the same posture
        # `Testing::Judge#parse` takes, and for the same reason: a model that
        # fenced its JSON or prefaced it with a sentence still answered, and
        # throwing that answer away would spend a second call to be told the
        # same thing.
        #
        # Returns nil rather than raising on unparseable output. `MoveTo` treats
        # nil as "no usable answer" and stops with a reason, which is the honest
        # outcome; an exception here would abort a walk that has already moved
        # the character.
        def parse(raw)
          text = raw.to_s.strip
          text = Regexp.last_match(1).strip if text =~ /```(?:json)?\s*(.+?)```/m
          text = text[text.index("{")..text.rindex("}")] if text.include?("{") && text.include?("}")

          doc = JSON.parse(text)
          doc.is_a?(Hash) ? doc : nil
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
