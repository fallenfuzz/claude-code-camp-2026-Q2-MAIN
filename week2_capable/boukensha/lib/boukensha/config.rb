require "yaml"
require "dotenv"
require "pathname"

module Boukensha
  class Config
    OTEL_ENV_NAME = /\AOTEL_[A-Z0-9_]+\z/.freeze
    PLAYER_GENDERS = %w[m f n].freeze
    PLAYER_CLASSES = %w[magic_user cleric thief warrior].freeze
    # The .boukensha config directory is resolved in this order:
    #   1. BOUKENSHA_DIR environment variable (set before loading .env)
    #   2. ~/.boukensha  (default)
    DEFAULT_DIR = File.join(Dir.home, ".boukensha").freeze

    # Default prompts shipped alongside this step.
    PROMPTS_DIR = File.expand_path("../../../prompts", __dir__).freeze

    attr_reader :root_dir, :profile_dir, :profile, :settings

    def initialize
      @root_dir = resolve_dir
      @profile_dir = resolve_profile_dir
      load_env
      @settings = load_settings
      @profile = load_profile
    end

    # Backward-compatible name for callers that only need shared assets.
    def dir = @root_dir

    # ---------- tasks -----------------------------------------------------

    # With no argument: returns the full tasks hash from settings.yaml.
    # With a name: returns that task's settings hash, e.g. tasks(:player).
    def tasks(name = nil)
      all = dig(:tasks) || {}
      return all unless name

      selected = all[name.to_s] || all[name.to_sym] || {}
      return selected unless name.to_s == "player"

      selected.merge(
        "provider" => (profile_dig(:overrides, :task, :provider) || selected["provider"] || selected[:provider]),
        "model" => (profile_dig(:overrides, :task, :model) || selected["model"] || selected[:model])
      ).compact
    end

    # The user's prompts directory for task prompt overrides.
    def user_prompts_dir
      File.join(@root_dir, "prompts")
    end

    # ---------- provider --------------------------------------------------

    def provider_type
      profile_dig(:overrides, :task, :provider) || dig(:tasks, :player, :provider) || "anthropic"
    end

    def model
      profile_dig(:overrides, :task, :model) || dig(:tasks, :player, :model) || "claude-haiku-4-5"
    end

    # ---------- MCP servers ------------------------------------------------

    # MCP servers to plug into the agent, keyed by name. This is where ALL of
    # the agent's tools come from — boukensha ships none of its own:
    #
    #   mcp_servers:
    #     mud:
    #       command: mud-manager
    #       args:    [--mcp]
    #       prefix:  tbamud
    #       env:
    #         MUD_HOST: your.mud.host      # a stdio server's credentials
    #         MUD_NAME: Gandalf            # travel by environment
    #
    # Returns { "mud" => { command:, args:, env:, prefix:, required: } } with
    # defaults applied. `required: false` lets a server fail to spawn without
    # taking the agent down with it.
    def mcp_servers
      (dig(:mcp_servers) || {}).each_with_object({}) do |(name, raw), out|
        entry = raw.is_a?(Hash) ? raw : {}
        get   = ->(k) { entry[k.to_s].nil? ? entry[k.to_sym] : entry[k.to_s] }
        req   = get.call(:required)

        env = (get.call(:env) || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
        apply_profile_mud_env!(env) if name.to_s == "mud"
        out[name.to_s] = {
          command:  get.call(:command).to_s,
          args:     Array(get.call(:args)).map(&:to_s),
          env:      env,
          prefix:   get.call(:prefix)&.to_s,
          required: req.nil? ? true : !!req
        }
      end
    end

    # ---------- agent limits ----------------------------------------------
    # Static per-turn circuit breakers, read where the agent is constructed.
    # A value of 0 or nil means "disabled" (no ceiling) — useful for debugging.

    def agent_max_iterations
      v = dig(:agent, :max_iterations)
      v.nil? ? 25 : Integer(v)
    end

    def agent_max_output_tokens
      v = dig(:agent, :max_output_tokens)
      v.nil? ? 1024 : Integer(v)
    end

    def agent_max_turn_tokens
      v = dig(:agent, :max_turn_tokens)
      v.nil? ? 60_000 : Integer(v)
    end

    def agent_compaction_threshold
      v = dig(:agent, :compaction_threshold)
      v.nil? ? 0.85 : Float(v)
    end

    def otel_enabled?
      env_boolean("BOUKENSHA_OTEL_ENABLED", dig(:observability, :otel, :enabled), false)
    end

    def otel_capture_content?
      env_boolean("BOUKENSHA_OTEL_CAPTURE_CONTENT",
                  dig(:observability, :otel, :capture_content), false)
    end

    def otel_content_max_bytes
      raw = ENV.fetch("BOUKENSHA_OTEL_CONTENT_MAX_BYTES",
                      dig(:observability, :otel, :content_max_bytes) || 4096)
      value = Integer(raw)
      raise ArgumentError, "BOUKENSHA_OTEL_CONTENT_MAX_BYTES must be positive" unless value.positive?
      value
    end

    # Apply standard OpenTelemetry environment configuration from settings.yaml
    # before the SDK is loaded. A real process environment variable always
    # wins, which keeps deployment overrides and secret headers out of YAML.
    #
    # observability:
    #   otel:
    #     env:
    #       OTEL_SERVICE_NAME: boukensha
    #       OTEL_EXPORTER_OTLP_ENDPOINT: http://localhost:4318
    def apply_otel_environment!
      configured = dig(:observability, :otel, :env) || {}
      raise ArgumentError, "observability.otel.env must be a YAML mapping" unless configured.is_a?(Hash)

      configured.each do |name, value|
        key = name.to_s
        unless OTEL_ENV_NAME.match?(key)
          raise ArgumentError, "observability.otel.env key #{key.inspect} must start with OTEL_ and use uppercase letters"
        end
        raise ArgumentError, "observability.otel.env value for #{key} must be a scalar" if value.is_a?(Hash) || value.is_a?(Array)

        ENV[key] = value.to_s unless value.nil? || ENV.key?(key)
      end
    end

    # ---------- low-level helpers -----------------------------------------

    # Fetch a nested key path from settings, e.g. dig(:provider, :model)
    def dig(*keys)
      keys.reduce(@settings) do |node, key|
        case node
        when Hash then node[key.to_s] || node[key.to_sym]
        else nil
        end
      end
    end

    def profile_dig(*keys)
      keys.reduce(@profile) do |node, key|
        node.is_a?(Hash) ? (node[key.to_s] || node[key.to_sym]) : nil
      end
    end

    def player_identity
      {
        gender: profile_dig(:player, :gender),
        player_class: profile_dig(:player, :class)
      }
    end

    def to_s
      "#<Boukensha::Config root_dir=#{@root_dir} profile_dir=#{@profile_dir} provider=#{provider_type} model=#{model}>"
    end

    def inspect = to_s

    private

    def env_boolean(name, yaml_value, default)
      raw = ENV.key?(name) ? ENV[name] : yaml_value
      return default if raw.nil?
      return raw if raw == true || raw == false
      return true if %w[1 true yes on].include?(raw.to_s.downcase)
      return false if %w[0 false no off].include?(raw.to_s.downcase)

      raise ArgumentError, "#{name} must be true or false"
    end

    def resolve_dir
      raw = ENV.fetch("BOUKENSHA_DIR", nil) || DEFAULT_DIR
      Pathname.new(raw).expand_path.to_s
    end

    def resolve_profile_dir
      raw = ENV["BOUKENSHA_PROFILE_DIR"]
      raw ? Pathname.new(raw).expand_path.to_s : @root_dir
    end

    def load_env
      env_file = File.join(@root_dir, ".env")
      if File.exist?(env_file)
        Dotenv.load(env_file)
      end
    end

    def load_settings
      settings_file = File.join(@root_dir, "settings.yaml")
      if File.exist?(settings_file)
        YAML.safe_load(File.read(settings_file)) || {}
      else
        {}
      end
    end

    def load_profile
      path = File.join(@profile_dir, "profile.yaml")
      return {} unless File.file?(path)

      value = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false) || {}
      raise ArgumentError, "#{path} must contain a YAML mapping" unless value.is_a?(Hash)
      validate_player_identity!(value, path)
      value
    end

    def validate_player_identity!(profile, path)
      player = profile["player"] || profile[:player]
      raise ArgumentError, "#{path}: player must be a mapping; received #{player.inspect}" unless player.is_a?(Hash)

      validate_player_field!(player, path, "gender", PLAYER_GENDERS)
      validate_player_field!(player, path, "class", PLAYER_CLASSES)
    end

    def validate_player_field!(player, path, field, allowed)
      value = player.key?(field) ? player[field] : player[field.to_sym]
      return if value.is_a?(String) && allowed.include?(value)

      raise ArgumentError,
            "#{path}: player.#{field} received #{value.inspect}; allowed values: #{allowed.join(', ')}"
    end

    def apply_profile_mud_env!(env)
      return if @profile.empty?

      name = profile_dig(:player, :name)
      password_env = profile_dig(:player, :password_env)
      env["MUD_NAME"] = name.to_s if name
      if password_env
        password = ENV[password_env.to_s]
        raise ArgumentError, "profile password environment variable #{password_env} is not set" if password.nil? || password.empty?
        env["MUD_PASSWORD"] = password
      end
      host = profile_dig(:overrides, :mud, :host)
      port = profile_dig(:overrides, :mud, :port)
      env["MUD_HOST"] = host.to_s if host
      env["MUD_PORT"] = port.to_s if port
      env["MUD_MANAGER_LOG_DIR"] = File.join(@profile_dir, "manager")
      env["MUD_TELNET_LOG_DIR"] = File.join(@profile_dir, "telnet")
    end
  end
end
