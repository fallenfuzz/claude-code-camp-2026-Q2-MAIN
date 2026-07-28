class ApplicationController < ActionController::API
  before_action :require_profile

  private

  def monitor_config
    Rails.application.config.x.mud_monitor
  end

  def require_profile
    @selected_profile = monitor_config.profile_registry.find(request.cookies["mud_monitor_profile"])
    return if @selected_profile

    render json: {
      error: {
        code: "profile_selection_required",
        message: "Select an available player profile",
        profiles: monitor_config.profile_registry.all.map(&:as_json)
      }
    }, status: :conflict
  end

  def selected_profile
    @selected_profile
  end

  def profile_config
    root = selected_profile.dir
    legacy = selected_profile.id == "legacy"
    ActiveSupport::OrderedOptions.new.tap do |c|
      c.profile = selected_profile.id
      c.boukensha_dir = root
      c.sessions_dir = legacy ? monitor_config.sessions_dir : root.join("sessions")
      c.telnet_dir = legacy ? monitor_config.telnet_dir : root.join("telnet")
      c.manager_dir = legacy ? monitor_config.manager_dir : root.join("manager")
      c.journal_dir = legacy ? monitor_config.journal_dir : root.join("journal")
      c.error_log = legacy ? monitor_config.error_log : root.join("error.log")
      c.knowledge_db = legacy ? monitor_config.knowledge_db : root.join("knowledge.sqlite3")
      c.world_dir = monitor_config.world_dir
      # Test fixtures and run reports hang off the boukensha ROOT, never off a
      # profile dir — scenarios and states are shared across profiles, and a
      # report exists precisely to compare runs that may not have used the same
      # one. Passed through from monitor_config for the same reason world_dir
      # is: it is not the selected profile's to own.
      c.tests_dir = monitor_config.boukensha_dir.join("tests")
      c.live_window = monitor_config.live_window
      c.max_streams = monitor_config.max_streams
      c.stream_idle_timeout = monitor_config.stream_idle_timeout
      c.stream_gate = monitor_config.stream_gate
    end
  end

  # Ensure every profile-backed JSON envelope identifies its source.
  def render(options = nil, extra_options = {}, &block)
    if selected_profile && options.is_a?(Hash) && options[:json].is_a?(Hash)
      options = options.merge(json: options[:json].merge(profile: selected_profile.id))
    end
    super(options, extra_options, &block)
  end
end
