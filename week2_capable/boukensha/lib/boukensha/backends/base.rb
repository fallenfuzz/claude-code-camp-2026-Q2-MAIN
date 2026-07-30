require_relative "../errors"

module Boukensha
  module Backends
    # Common base for all provider backends.
    #
    # Normalized response contract
    # ----------------------------
    # Every backend's #parse_response returns:
    #
    #   { stop_reason: "tool_use" | "end_turn",
    #     content: [ <block>, <block>, ... ] }
    #
    # where each block is one of:
    #
    #   { "type" => "reasoning",
    #     "text"      => "<human-readable reasoning, may be empty>",
    #     "signature" => "<opaque provider token, optional>",  # round-trip only
    #     "redacted"  => true | false }                        # optional
    #
    #   { "type" => "text", "text" => "..." }
    #
    #   { "type" => "tool_use", "id" => ..., "name" => ..., "input" => {...} }
    #
    # Reasoning blocks come FIRST in content, before text and tool_use (matching
    # Anthropic's native ordering). `text` is what the viewer renders and may be
    # empty (redacted/omitted reasoning). `signature`/`redacted` are opaque
    # carry-through for providers that require the block echoed back unchanged
    # (Anthropic thinking signatures, Gemini thoughtSignature) — consumers never
    # interpret them. Backends that don't accept reasoning back in a request drop
    # these blocks when rebuilding assistant turns.
    class Base
      attr_reader :model

      def self.models
        const_get(:MODELS)
      rescue NameError
        raise NotImplementedError, "#{self} must define MODELS"
      end

      def self.model_info(model)
        models[model.to_s]
      end

      def self.validate_model!(model)
        model = model.to_s
        return model if model_info(model)

        supported = models.keys.sort.join(", ")
        raise UnsupportedModelError, "#{name} does not support model #{model.inspect}. Supported models: #{supported}"
      end

      def model_info
        @model_info
      end

      def context_window
        model_info.fetch(:context_window)
      end

      def input_token_cost_per_million
        model_info.fetch(:cost_per_million).fetch(:input)
      end

      def output_token_cost_per_million
        model_info.fetch(:cost_per_million).fetch(:output)
      end

      def usage_unit
        model_info.fetch(:usage_unit)
      end

      def usage_level
        model_info[:usage_level]
      end

      # "Anthropic" => "anthropic", "OllamaCloud" => "ollama_cloud". The one
      # place this is computed — Logger#execution_metadata and
      # Agent#call_model's `llm.generate` span both want the same string on the
      # same backend and must not drift into disagreeing spellings.
      def provider_name
        self.class.name.split("::").last.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      # A staged answer, in THIS provider's wire shape — the inverse of
      # `parse_response`, and the one thing the test harness's staging layer
      # needs from a backend (mocking_messages.md §3).
      #
      # It lives here rather than in the harness because the wire shape is the
      # backend's own business: a body assembled by the harness would be an
      # Anthropic body by accident, and would parse to empty content on any
      # provider whose response is shaped differently — a staged run that
      # silently measured nothing.
      #
      # `usage` is zero rather than invented. Nothing was spent, and the report's
      # cost column should say so.
      def staged_response(text: nil, tools: [])
        raise NotImplementedError,
              "#{provider_name} cannot answer a staged model call: Backends::#{self.class.name.split('::').last} " \
              "does not implement #staged_response, so there is no way to hand the agent a response in the " \
              "shape it parses. Run this scenario on a backend that does, or implement it."
      end

      def estimate_cost(input_tokens:, output_tokens:)
        return nil unless input_token_cost_per_million && output_token_cost_per_million

        ((input_tokens * input_token_cost_per_million) +
          (output_tokens * output_token_cost_per_million)) / 1_000_000.0
      end

      private

      def configure_model(model)
        @model = self.class.validate_model!(model)
        @model_info = self.class.model_info(@model)
      end
    end
  end
end
