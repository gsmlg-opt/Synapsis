defmodule Synapsis.Tool.Builtin do
  @moduledoc "Registers all built-in tools on startup."

  @tools [
    Synapsis.Tool.FileRead,
    Synapsis.Tool.FileEdit,
    Synapsis.Tool.FileWrite,
    Synapsis.Tool.Bash,
    Synapsis.Tool.Grep,
    Synapsis.Tool.Glob,
    Synapsis.Tool.Fetch,
    Synapsis.Tool.Diagnostics,
    Synapsis.Tool.ListDir,
    Synapsis.Tool.FileDelete,
    Synapsis.Tool.FileMove
  ]

  def register_all do
    for mod <- @tools do
      Synapsis.Tool.Registry.register_module(mod.name(), mod,
        timeout: default_timeout(mod.name()),
        description: mod.description(),
        parameters: mod.parameters()
      )
    end

    :ok
  end

  defp default_timeout("bash"), do: 30_000
  defp default_timeout("fetch"), do: 15_000
  defp default_timeout("grep"), do: 10_000
  defp default_timeout("file_edit"), do: 10_000
  defp default_timeout("file_write"), do: 10_000
  defp default_timeout("file_read"), do: 5_000
  defp default_timeout("glob"), do: 5_000
  defp default_timeout("list_dir"), do: 5_000
  defp default_timeout("file_delete"), do: 5_000
  defp default_timeout("file_move"), do: 5_000
  defp default_timeout(_), do: 10_000
end
