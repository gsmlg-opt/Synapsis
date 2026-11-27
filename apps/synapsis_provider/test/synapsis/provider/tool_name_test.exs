defmodule Synapsis.Provider.ToolNameTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.ToolName

  test "skill names have readable wire names distinct from matching literal tools" do
    for suffix <- ~w(skill skill_workshop skills_create skills_read skills_search) do
      native = "synapsis::" <> suffix
      literal = "synapsis__" <> suffix
      assert ToolName.encode(native) == literal
      assert ToolName.decode(literal) == native
      assert ToolName.decode("syn_" <> Base.url_encode64(native, padding: false)) == native
      refute ToolName.encode(literal) == literal

      event = %Backplane.AiProtocol.StreamEvent{
        type: :tool_call_start,
        index: 0,
        name: ToolName.encode(literal)
      }

      assert {:tool_call_delta, 0, nil, ^literal, ""} =
               Synapsis.Provider.EventMapper.map_event(event, %{})
    end
  end

  test "long unsafe names receive bounded deterministic collision-resistant aliases" do
    name = "mcp:agent-note:" <> String.duplicate("nested-namespace:", 8) <> "list_notes"
    other_name = name <> "_other"

    alias_name = ToolName.encode(name)

    assert byte_size(alias_name) <= 64
    assert ToolName.openai_safe?(alias_name)
    assert alias_name == ToolName.encode(name)
    refute alias_name == ToolName.encode(other_name)
  end

  test "request-local aliases restore long names without leaking metadata to providers" do
    name = "mcp:agent-note:" <> String.duplicate("nested-namespace:", 8) <> "list_notes"
    alias_name = ToolName.encode(name)

    request =
      %{model: "test-model"}
      |> ToolName.put_aliases([name, "file_read"])

    assert {%{model: "test-model"}, aliases} = ToolName.pop_aliases(request)
    assert ToolName.decode(alias_name, aliases) == name
    assert ToolName.decode("file_read", aliases) == "file_read"
  end
end
