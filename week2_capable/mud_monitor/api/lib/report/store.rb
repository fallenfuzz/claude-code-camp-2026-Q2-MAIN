require "json"
require "pathname"

module Report
  # Directory listing and safe path resolution for test-run report .json files.
  #
  # Mirrors SessionLog::Store deliberately, including the realpath containment
  # check — a report id arrives from a URL, and `../../etc/passwd` is the first
  # thing anyone tries.
  #
  # One difference that matters: reports live under the boukensha ROOT dir, not
  # the profile dir, because fixtures and the runs that compare them are shared
  # across profiles. A run whose cases used one profile is filtered by reading
  # the document, not by looking at where the file sits.
  class Store
    class NotFound < StandardError; end

    GLOB = "**/*.json".freeze

    def initialize(dir:)
      @dir = Pathname.new(dir)
    end

    # Newest-first. Run ids are `%Y%m%dT%H%M%SZ`-prefixed, so lexical sort ==
    # chronological, exactly as it is for sessions.
    def paths
      return [] unless @dir.directory?

      @dir.glob(GLOB)
          .reject { |path| path.to_s.include?("#{File::SEPARATOR}.work#{File::SEPARATOR}") }
          .sort_by { |path| path.basename.to_s }
          .reverse
    end

    # Reports are nested one directory deep (`reports/<name>/<run_id>.json`), so
    # an id is resolved by scanning the listing rather than by joining a path —
    # which also means a crafted id can never become a path at all.
    def path_for(id)
      safe_id = File.basename(id.to_s, ".json")
      path    = paths.find { |candidate| candidate.basename(".json").to_s == safe_id }
      raise NotFound, id unless path&.file?

      resolved = path.realpath
      raise NotFound, id unless resolved.to_s.start_with?(@dir.realpath.to_s + File::SEPARATOR)

      resolved
    end

    def load(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      # A run still being written, or one whose process died mid-write. It is
      # listed as unreadable rather than taking the whole index down.
      nil
    end
  end
end
