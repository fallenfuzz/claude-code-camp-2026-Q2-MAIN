require_relative "helper"

# What a tool advertises itself as. Every backend used to build this inline and
# all five got the same thing wrong: `required` was every key, so a parameter
# with a Ruby default was still one the model had to send. That was invisible
# while every tool wanted every argument, and became load-bearing the moment
# `move_to` grew a second objective mode — `destination` and `survey` are
# alternatives, and a schema demanding both would make the tool uncallable.
class TestToolSchema < Minitest::Test
  def tool(parameters)
    Boukensha::Tool.new("t", "a tool", parameters, proc {})
  end

  def test_parameters_are_required_by_default
    schema = tool(destination: { type: "string" }).json_schema

    assert_equal %w[destination], schema[:required]
    assert_equal "object", schema[:type]
  end

  def test_a_parameter_marked_optional_is_advertised_but_not_demanded
    schema = tool(destination: { type: "string", optional: true },
                  scope: { type: "string" }).json_schema

    assert_equal %w[scope], schema[:required]
    assert_includes schema[:properties].keys, :destination, "optional is not the same as absent"
  end

  # `optional` is boukensha's annotation and not JSON Schema's. Leaving it in
  # the advertised properties would put a key no provider understands into every
  # request, so it is stripped on the way out.
  def test_the_optional_marker_never_reaches_the_provider
    schema = tool(survey: { type: "string", optional: true, description: "a question" }).json_schema

    assert_equal({ type: "string", description: "a question" }, schema[:properties][:survey])
  end

  def test_every_backend_advertises_the_same_schema
    context = Boukensha::Context.new(system: "t")
    context.register_tool(tool(destination: { type: "string", optional: true },
                               scope: { type: "string" }))
    tools = context.advertised_tools

    anthropic = Boukensha::Backends::Anthropic.allocate.send(:to_tools, tools).first
    openai    = Boukensha::Backends::OpenAI.allocate.send(:to_tools, tools).first

    assert_equal %w[scope], anthropic[:input_schema][:required]
    assert_equal %w[scope], openai[:parameters][:required]
  end
end
