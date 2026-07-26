require "pathname"

module ErrorLog
  class Store
    class NotFound < StandardError; end

    attr_reader :path

    def initialize(path:, live_window: 10)
      @path = Pathname.new(path)
      @live_window = live_window
    end

    def existing_path
      @path.file? ? @path : nil
    end

    def path!
      existing_path || raise(NotFound, @path.to_s)
    end

    def live?
      existing_path && Time.now - File.mtime(@path) <= @live_window
    end
  end
end
