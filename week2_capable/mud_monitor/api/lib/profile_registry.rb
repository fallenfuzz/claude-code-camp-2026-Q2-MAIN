require "pathname"
require "yaml"

class ProfileRegistry
  NAME_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z/
  RUNTIME_ENTRIES = %w[knowledge.sqlite3 sessions journal manager telnet error.log].freeze

  Profile = Data.define(:id, :label, :dir, :available) do
    def as_json(*) = { id: id, label: label, available: available }
  end

  def initialize(root:)
    @root = Pathname.new(root).expand_path
  end

  def all
    entries = profile_entries
    entries.unshift(Profile.new(id: "legacy", label: "Legacy", dir: @root, available: true)) if legacy?
    entries
  end

  def find(id)
    return nil unless id.is_a?(String)
    all.find { |profile| profile.id.casecmp?(id) }
  end

  private

  def profile_entries
    base = @root.join("profiles")
    return [] unless base.directory?

    base.children.filter_map do |child|
      name = child.basename.to_s
      next unless NAME_PATTERN.match?(name) && child.directory?
      canonical = child.realpath
      next unless canonical.to_s.start_with?(base.expand_path.to_s + File::SEPARATOR)
      yaml = canonical.join("profile.yaml")
      next unless yaml.file?
      data = YAML.safe_load(yaml.read, permitted_classes: [], aliases: false) || {}
      label = data.dig("player", "display_name") || data.dig("player", "name") || name
      Profile.new(id: name, label: label.to_s, dir: canonical, available: true)
    rescue Errno::ENOENT, Psych::SyntaxError
      nil
    end.sort_by { |profile| profile.id.downcase }
  end

  def legacy?
    RUNTIME_ENTRIES.any? { |entry| @root.join(entry).exist? }
  end
end
