defmodule SynapsisServer.ConfigController do
  use SynapsisServer, :controller

  def show(conn, params) do
    project_path = params["project_path"] || "."
    config = Synapsis.Config.resolve(project_path)

    safe_config = sanitize_config(config)
    json(conn, %{data: safe_config})
  end

  defp sanitize_config(config) do
    providers =
      (config["providers"] || %{})
      |> Enum.map(fn {name, provider_config} ->
        {name, Map.drop(provider_config, ["apiKey"])}
      end)
      |> Map.new()

    Map.put(config, "providers", providers)
  end
end
