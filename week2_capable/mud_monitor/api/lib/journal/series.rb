module Journal
  # Folds an ordered list of journal Records into the shapes the Progression
  # view graphs. This is the only place that knows what the player streams mean;
  # the Parser/Follower/Store below it stay world-agnostic, exactly as the
  # writer does.
  #
  #   Journal::Series.fold(records) =>
  #     {
  #       stats:      { "level" => [{seq:, at:, value:}], "exp" => [...], "gold" => [...] },
  #       skills:     { "backstab" => [{seq:, at:, value:}], ... },
  #       milestones: [{seq:, at:, op:, ...fields}],   # level_up, death, in order
  #       items:      [{seq:, at:, op:, ...fields}]    # acquire/drop/use ledger, in order
  #     }
  #
  # A `snapshot` line seeds each stat series with an anchor point so every graph
  # starts from a known baseline rather than at its first mid-session change.
  class Series
    def self.fold(records)
      new(records).fold
    end

    def initialize(records)
      @records = records.sort_by { |r| r.seq.to_i }
    end

    def fold
      stats      = Hash.new { |h, k| h[k] = [] }
      skills     = Hash.new { |h, k| h[k] = [] }
      milestones = []
      items      = []

      @records.each do |r|
        case r.kind
        when "snapshot"
          next unless r.stream == "stat" && r.values.is_a?(Hash)

          r.values.each { |key, value| stats[key] << point(r, value) }
        when "change"
          case r.stream
          when "stat"  then stats[r.key]  << point(r, r.to)
          when "skill" then skills[r.key] << point(r, r.to)
          end
        when "event"
          case r.stream
          when "milestone" then milestones << event_row(r)
          when "item"      then items      << event_row(r)
          end
        end
      end

      {
        stats:      stats.transform_values(&:itself),
        skills:     skills.transform_values(&:itself),
        milestones: milestones,
        items:      items
      }
    end

    private

    def point(record, value)
      { seq: record.seq, at: record.at, value: value }
    end

    def event_row(record)
      { seq: record.seq, at: record.at, op: record.op }.merge(symbolize(record.fields))
    end

    def symbolize(fields)
      (fields || {}).each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
    end
  end
end
