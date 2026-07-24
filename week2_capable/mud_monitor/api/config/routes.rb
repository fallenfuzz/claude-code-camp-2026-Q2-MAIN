Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      get "profiles", to: "profiles#index"
      get "health", to: "health#show"
      resources :sessions, only: %i[index show] do
        member do
          get "events"
          get "stream"
          get "messages"
        end
      end

      get "manager", to: "manager#index"
      get "manager/stream", to: "manager#stream"

      get "telnet", to: "telnet#index"
      get "telnet/stream", to: "telnet#stream"

      # The agent's progression log. Append-only with a per-record seq, so unlike
      # knowledge it streams (SSE) — #index folds the day into graphable series,
      # #stream tails new records after a cursor.
      get "journal", to: "journal#index"
      get "journal/stream", to: "journal#stream"

      get "diffs/dropped", to: "diffs#dropped"

      # The agent's world memory. A snapshot, not a log — no /stream sibling,
      # because there is no cursor to follow (see KnowledgeController).
      get "knowledge",           to: "knowledge#show"
      get "knowledge/rooms",     to: "knowledge#rooms"
      # Named explicitly: auto-naming derives `knowledge_rooms` from the static
      # segments here too, collides with the line above, and silently leaves
      # this route with no helper at all.
      get "knowledge/rooms/:id", to: "knowledge#room", as: :knowledge_room, constraints: { id: /\d+/ }
      get "knowledge/entities",  to: "knowledge#entities"
      get "knowledge/player",    to: "knowledge#player"
      get "knowledge/frontier",  to: "knowledge#frontier"
    end
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
