module Api
  module V1
    # Batch test-run reports, read-only.
    #
    # No SSE, and for the same reason KnowledgeController has none rather than
    # the opposite one: a report is written ONCE, when the run finishes. There
    # is no cursor to follow and no partial state to tail, so a stream would be
    # a connection held open to deliver nothing. This is the `knowledge`
    # precedent, not the `journal` one.
    class ReportsController < ApplicationController
      rescue_from ::Report::Store::NotFound, with: :render_not_found

      # GET /reports?profile=
      def index
        reports = store.paths.filter_map do |path|
          doc = store.load(path)
          next if doc.nil?

          summary = ReportSerializer.new(doc, path: path).summary
          next if params[:profile].present? && !summary[:profile].to_s.include?(params[:profile])

          summary
        end

        render json: { reports: reports, dir: reports_dir.to_s }
      end

      # GET /reports/:id
      def show
        path = store.path_for(params[:id])
        doc  = store.load(path)
        return render_unreadable if doc.nil?

        render json: { report: ReportSerializer.new(doc, path: path).detail }
      end

      private

      def store = ::Report::Store.new(dir: reports_dir)

      # Off the boukensha ROOT, not the profile dir: fixtures and the runs that
      # compare them are shared across profiles (§2).
      def reports_dir = profile_config.tests_dir.join("reports")

      def render_not_found
        render json: { error: { code: "not_found", message: "No report #{params[:id]}" } },
               status: :not_found
      end

      def render_unreadable
        render json: { error: { code: "report_unreadable",
                                message: "Report #{params[:id]} is not valid JSON — the run may still be writing it" } },
               status: :service_unavailable
      end
    end
  end
end
