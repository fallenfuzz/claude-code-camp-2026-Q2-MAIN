module Api
  module V1
    class ProfilesController < ApplicationController
      skip_before_action :require_profile

      def index
        render json: { profiles: monitor_config.profile_registry.all.map(&:as_json) }
      end
    end
  end
end
