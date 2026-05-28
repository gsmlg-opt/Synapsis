defmodule Synapsis.Workspace.Tools do
  @moduledoc "Registers workspace tools in the tool registry."

  @tools []

  def register_all do
    for mod <- @tools do
      Synapsis.Tool.Registry.register_module(mod.name(), mod,
        timeout: 10_000,
        description: mod.description(),
        parameters: mod.parameters()
      )
    end

    :ok
  end
end
