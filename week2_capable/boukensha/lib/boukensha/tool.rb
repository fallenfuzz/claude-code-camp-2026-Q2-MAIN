module Boukensha
  Tool = Struct.new(:name, :description, :parameters, :block) do
    def to_s
      "#<Tool name=#{name} description=#{description.to_s[0..40]} params=#{parameters.keys}>"
    end

    # The JSON Schema every backend advertises this tool as. It exists because
    # all five of them used to build the same two lines inline, and all five got
    # the same thing wrong: `required` was every key, so a parameter with a Ruby
    # default was still one the model had to send.
    #
    # `optional: true` on a parameter marks it as genuinely optional and is
    # stripped before the schema goes out — it is boukensha's annotation, not
    # JSON Schema's. Absent, the parameter is required, which keeps every tool
    # written before this existed advertising exactly what it did.
    def json_schema
      properties = parameters.to_h do |name, spec|
        [name, spec.is_a?(Hash) ? spec.reject { |k, _| k.to_s == "optional" } : spec]
      end
      { type: "object", properties: properties, required: required_parameters }
    end

    def required_parameters
      parameters.reject { |_, spec| spec.is_a?(Hash) && (spec[:optional] || spec["optional"]) }
                .keys.map(&:to_s)
    end
  end
end
