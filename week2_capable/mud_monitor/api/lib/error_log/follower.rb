module ErrorLog
  class Follower
    def initialize(path)
      @path = path
      @last_key = nil
      @records = []
    end

    def records_after(cursor)
      stat = File.stat(@path)
      key = [stat.ino, stat.size, stat.mtime]
      if @last_key != key
        replaced_or_truncated = @last_key && (stat.ino != @last_key[0] || stat.size < @last_key[1])
        @records = Parser.load(@path)
        @last_key = key
      end
      @records.select { |record| replaced_or_truncated || record.seq > cursor.to_i }
    rescue Errno::ENOENT
      []
    end
  end
end
