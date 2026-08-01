require_relative "predicates"
require_relative "assessment"
require_relative "egress"

module Boukensha
  module Mud
    module Navigation
      # Applying what the surveyor answered — surveyor_architecture.md, "What the
      # surveyor returns".
      #
      # The response is a set of LEDGER OPERATIONS and not a movement decision,
      # and every one of them is validated before it is applied. Because the
      # surveyor cannot name a frontier, the class of failure where a reasoner
      # returns an invalid or stale direction does not exist here, and the
      # deterministic fallback the superseded design needed for that case is
      # unnecessary. What can still go wrong is a claim nobody could ever settle,
      # and the three rules below are what stop one entering the ledger.
      class ClaimLedger
        # Rejections, kept as a running list so the caller can journal what was
        # thrown away. A ledger that silently dropped half a surveyor's answer
        # would be indistinguishable from a surveyor that had nothing to say.
        attr_reader :rejected, :opened, :revised

        # `objective` is the question the survey was asked, stamped onto every
        # claim opened here. It belongs to the ledger rather than to each call
        # because it does not change between them — and a keyword on `apply!`
        # would make the answer hash ambiguous with the keywords beside it.
        def initialize(store:, region_id:, objective: nil, journal: nil)
          @store     = store
          @region_id = region_id
          @objective = objective
          @journal   = journal
          @rejected  = []
          @opened    = []
          @revised   = []
        end

        def apply!(answer)
          return self unless answer.is_a?(Hash)

          Array(answer["features"]).each { |f| apply_feature(f) }
          Array(answer["open"]).each     { |c| apply_open(c) }
          Array(answer["revise"]).each   { |c| apply_revise(c) }
          Array(answer["park"]).each     { |c| apply_status(c, "parked") }
          Array(answer["retire"]).each   { |c| apply_status(c, c["status"] || "unresolved") }
          Array(answer["hints"]).each    { |h| apply_hint(h) }
          self
        end

        # Did this response change anything at all? `MoveTo` uses it to tell a
        # surveyor that revised the ledger from one that read the evidence and
        # concluded nothing needed changing — the second is a perfectly good
        # answer and should not be mistaken for a failure.
        def changed? = @opened.any? || @revised.any?

        private

        def apply_open(spec)
          statement = spec["statement"].to_s.strip
          predicate = spec["predicate"].to_s.strip
          subject   = presence(spec["subject"])

          # Rule one: the predicate must be in the closed vocabulary, because a
          # predicate the planner cannot run is a claim nothing can score
          # frontiers against or ever settle.
          return reject(spec, "predicate #{predicate.inspect} is not in the vocabulary") unless
            Predicates.known?(predicate)
          return reject(spec, "a claim needs a statement") if statement.empty?

          # Rule two: it must name a decisive condition. This is what rejects
          # "the town is prosperous" at validation time rather than leaving it
          # open forever with nothing that could ever settle it.
          return reject(spec, "no decisive test given") if presence(spec["decisive_when"]).nil?

          # Rule three: a proposal matching an existing claim's predicate and
          # subject MERGES into it, so evidence accumulates in one place instead
          # of the ledger forking every time the surveyor rephrases itself.
          if (existing = @store.claim_by_subject(region_id: @region_id, predicate: predicate, subject: subject))
            return merge_into(existing, spec)
          end

          id = @store.create_claim!(
            region_id: @region_id, statement: statement, predicate: predicate, subject: subject,
            confidence: number(spec["confidence"], 0.5), priority: number(spec["priority"], 0.5),
            answers: presence(spec["answers"]), decisive_when: presence(spec["decisive_when"]),
            args: normalize_args(spec["args"]), room_budget: integer(spec["room_budget"]),
            objective: @objective
          )
          add_evidence(id, spec["evidence"])
          @opened << id
          id
        end

        # A re-proposal of something already in the ledger. Confidence and
        # priority move, argument lists grow, evidence is appended — and the
        # claim keeps its id, its ref, and everything it had already gathered.
        def merge_into(existing, spec)
          fields = {}
          fields[:confidence] = number(spec["confidence"], nil) if spec.key?("confidence")
          fields[:priority]   = number(spec["priority"], nil) if spec.key?("priority")
          fields[:args]       = merge_args(existing, spec["args"]) if spec["args"].is_a?(Hash)
          # A claim re-proposed after being parked is being asked for again.
          fields[:status]     = "open" if existing[:status] == "parked"
          @store.update_claim!(existing[:id], **fields.compact)
          add_evidence(existing[:id], spec["evidence"])
          @revised << existing[:id]
          journal("claim_merged", ref: existing[:ref], predicate: existing[:predicate])
          existing[:id]
        end

        def apply_revise(spec)
          claim = find(spec) or return reject(spec, "no such claim")

          fields = {}
          fields[:confidence]    = number(spec["confidence"], nil) if spec.key?("confidence")
          fields[:priority]      = number(spec["priority"], nil) if spec.key?("priority")
          fields[:statement]     = presence(spec["statement"])
          fields[:decisive_when] = presence(spec["decisive_when"])
          fields[:room_budget]   = integer(spec["room_budget"])
          fields[:args]          = merge_args(claim, spec["args"]) if spec["args"].is_a?(Hash)
          @store.update_claim!(claim[:id], **fields.compact)
          add_evidence(claim[:id], spec["evidence"])
          @revised << claim[:id]
        end

        # Parking and retiring are the same write with a different status, and
        # both keep the row. `unresolved` is a successful outcome — it says what
        # remains to settle the claim, which is more use to the next survey than
        # a room count is.
        def apply_status(spec, status)
          claim = find(spec) or return reject(spec, "no such claim")
          return reject(spec, "#{status} is not a status a surveyor may set") unless
            %w[parked confirmed refuted unresolved].include?(status.to_s)

          @store.settle_claim!(claim[:id], status: status.to_s, reason: presence(spec["reason"]))
          @revised << claim[:id]
        end

        # Feature membership is the one durable per-room tag the model requires,
        # because `circuit_closes`, `connects` and `bounds` all depend on
        # deciding that several separately observed rooms belong to one road or
        # one wall. Until chains can be assembled reliably those three predicates
        # are weaker than the vocabulary table suggests, and this is the write
        # that assembles them.
        def apply_feature(spec)
          slug = presence(spec["slug"]) or return reject(spec, "a feature needs a slug")

          feature_id = @store.upsert_feature!(region_id: @region_id, slug: slug, label: presence(spec["label"]))
          Array(spec["rooms"]).each do |room|
            room_id = room.is_a?(Hash) ? integer(room["room_id"]) : integer(room)
            next unless room_id && @store.room(room_id)

            @store.tag_feature_room!(feature_id: feature_id, room_id: room_id,
                                     note: room.is_a?(Hash) ? presence(room["note"]) : nil)
          end
        end

        def apply_hint(spec)
          room_id   = integer(spec["room_id"])
          direction = presence(spec["direction"])
          return unless room_id && direction

          # `assessability`, `hazard` and `egress` are validated against their
          # vocabularies rather than stored as written, and an unrecognised answer
          # reads as no answer — which for assessability means `unknown`, which
          # defers, and for egress means silence, which permits. A surveyor that
          # invents a value must not thereby grant permission
          # (blind_step_recovery.md §5.1), and neither must it thereby impose a
          # fence (staying_in_town.md §10.1).
          @store.record_frontier_hint!(room_id: room_id, direction: direction,
                                       expected_class: presence(spec["expected_class"]),
                                       note: presence(spec["note"]),
                                       assessability: assessability(spec["assessability"]),
                                       hazard: presence(spec["hazard"]),
                                       egress: egress(spec["egress"]))
        end

        def add_evidence(claim_id, rows)
          Array(rows).each do |e|
            polarity = e["polarity"].to_s
            polarity = "support" unless %w[support contradict neutral].include?(polarity)
            @store.add_claim_evidence!(claim_id: claim_id, polarity: polarity,
                                       room_id: integer(e["room_id"]), note: presence(e["note"]))
          end
        end

        # The surveyor addresses claims by `ref` ("C1"), which is what appears in
        # the payload it was given. An `id` is accepted too, because a reasoner
        # handed both will sometimes answer with either.
        def find(spec)
          ref = presence(spec["ref"]) || presence(spec["id"])
          return nil unless ref

          @store.claims(region_id: @region_id).find { |c| c[:ref] == ref || c[:id].to_s == ref.to_s }
        end

        # Argument lists GROW rather than being replaced. A surveyor answering
        # with the two classes it just saw must not silently drop the four the
        # ledger had already recorded, and a reasoner asked to restate the whole
        # list every call would eventually get it wrong.
        def merge_args(claim, incoming)
          merged = (claim[:args] || {}).dup
          normalize_args(incoming).each do |key, value|
            merged[key] = if value.is_a?(Array) && merged[key].is_a?(Array)
                            (merged[key] | value)
                          else
                            value
                          end
          end
          # The saturation clock for `composition` resets whenever the observed
          # class list actually grows, and here is the only place that can be
          # detected — the planner sees the result, not the change.
          before = Array((claim[:args] || {})["classes_observed"]).size
          after  = Array(merged["classes_observed"]).size
          merged["last_class_at_rooms"] = claim[:rooms_spent].to_i if after > before
          merged
        end

        def normalize_args(args)
          return {} unless args.is_a?(Hash)

          args.to_h { |k, v| [k.to_s, v] }
        end

        def reject(spec, reason)
          @rejected << { spec: spec, reason: reason }
          journal("claim_rejected", predicate: spec["predicate"], statement: spec["statement"], reason: reason)
          nil
        end

        def presence(value)
          s = value.to_s.strip
          s.empty? ? nil : s
        end

        # nil unless the surveyor named one of the three values, so that silence
        # and nonsense reach the store as the same thing and the store's own
        # default — `unknown`, which defers — applies to both.
        def assessability(value)
          v = presence(value)&.downcase
          v if Assessment::ASSESSABILITY.include?(v)
        end

        # Same shape and the same reason: silence and nonsense reach the store as
        # the same thing, and the store's own default — `interior`, which permits —
        # applies to both. A `leaves` the surveyor did not actually write must
        # never fence a survey into the room it is standing in.
        def egress(value)
          v = presence(value)&.downcase
          v if Egress::VALUES.include?(v)
        end

        def number(value, default)
          return default if value.nil?

          Float(value).clamp(0.0, 1.0)
        rescue ArgumentError, TypeError
          default
        end

        def integer(value)
          return nil if value.nil?

          Integer(value)
        rescue ArgumentError, TypeError
          nil
        end

        def journal(op, **fields)
          @journal&.event(stream: "survey", op: op, **fields.compact)
        end
      end
    end
  end
end
