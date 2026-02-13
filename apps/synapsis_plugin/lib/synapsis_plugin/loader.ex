defmodule SynapsisPlugin.Loader do
  @moduledoc "Reads plugin_configs from DB and starts auto_start plugins."
  require Logger

  def start_auto_plugins do
    try do
      configs = load_plugin_configs()

      for config <- configs, config.auto_start do
        plugin_module = module_for_type(config.type)

        case SynapsisPlugin.start_plugin(plugin_module, config.name, config_to_map(config)) do
          {:ok, _pid} ->
            Logger.info("plugin_auto_started", name: config.name, type: config.type)

          {:error, reason} ->
            Logger.warning("plugin_auto_start_failed",
              name: config.name,
              reason: inspect(reason)
            )
        end
      end

      :ok
    rescue
      e ->
        Logger.warning("plugin_loader_error", error: Exception.message(e))
        :ok
    end
  end

  defp load_plugin_configs do
    import Ecto.Query
    Synapsis.Repo.all(from(p in Synapsis.PluginConfig, where: p.auto_start == true))
  rescue
    _ -> []
  end

  defp module_for_type("mcp"), do: SynapsisPlugin.MCP
  defp module_for_type("lsp"), do: SynapsisPlugin.LSP
  defp module_for_type(_), do: SynapsisPlugin.MCP

  defp config_to_map(%{} = config) do
    %{
      name: config.name,
      type: config.type,
      transport: config.transport,
      command: config.command,
      args: config.args || [],
      url: config.url,
      root_path: config.root_path,
      env: config.env || %{},
      settings: config.settings || %{}
    }
  end
end
