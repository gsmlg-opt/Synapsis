defmodule SynapsisServer.ConfigController do
  use SynapsisServer, :controller

  @max_path_bytes 4_096

  def show(conn, params) do
    project_path = params["project_path"] || "."

    if byte_size(project_path) > @max_path_bytes do
      conn |> put_status(400) |> json(%{error: "project_path too long"})
    else
      config = Synapsis.Config.resolve(project_path)
      safe_config = sanitize_config(config)
      json(conn, %{data: safe_config})
    end
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
