defmodule Synapsis.Agent.Runtime.BackplaneSchemaCompatibilityTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Daemon.Toolsets
  alias Synapsis.Tool.Registry

  @profiles ~w(assistant_basic assistant_workspace assistant_coding assistant_dream
    assistant_dream_todo read_only reflect heartbeat coding maintenance)

  for profile <- @profiles do
    test "#{profile} built-ins retain compatible schemas" do
      {:ok, names} = Toolsets.resolve(unquote(profile))
      builtins = Enum.reject(names, &String.starts_with?(&1, "mcp:"))
      assert "skill" in builtins

      for name <- builtins do
        assert {:ok, {:module, module, opts}} = Registry.lookup(name)
        schema = opts[:parameters] || module.parameters()
        assert :ok = InputSchema.validate_schema(schema), "#{unquote(profile)}/#{name}"
      end
    end
  end

  test "skill anyOf keeps sibling constraints and accepts either or both identifiers" do
    schema = Synapsis.Tool.Skill.parameters()

    for input <- [
          %{"locator" => "skill:a"},
          %{"name" => "review"},
          %{"locator" => "skill:a", "name" => "review"}
        ] do
      assert {:ok, ^input} = InputSchema.validate(schema, input)
    end

    for input <- [%{}, %{"locator" => 123}, %{"name" => "review", "extra" => true}] do
      assert {:error, %Error{class: :validation}} = InputSchema.validate(schema, input)
    end
  end
end
