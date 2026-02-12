defmodule Synapsis.Tool.Diagnostics do
  @moduledoc "LSP diagnostics tool - queries active LSP servers for errors/warnings."
  @behaviour Synapsis.Tool.Behaviour

  @impl true
  def name, do: "diagnostics"

  @impl true
  def description, do: "Get current diagnostics (errors, warnings) from language servers."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File path to get diagnostics for (optional, returns all if omitted)"
        }
      },
      "required" => []
    }
  end

  @impl true
  def call(input, context) do
    project_path = context[:project_path] || "."

    # Use apply/3 to avoid cross-umbrella compile-time reference warning
    case apply(Synapsis.LSP.Manager, :get_all_diagnostics, [project_path]) do
      {:ok, diagnostics} ->
        filtered =
          case input["path"] do
            nil ->
              diagnostics

            path ->
              uri = "file://#{Path.expand(path, project_path)}"
              Map.take(diagnostics, [uri])
          end

        if map_size(filtered) == 0 do
          {:ok, "No diagnostics found."}
        else
          result =
            filtered
            |> Enum.flat_map(fn {uri, diags} ->
              file = String.replace_prefix(uri, "file://", "")

              Enum.map(diags, fn d ->
                line = get_in(d, ["range", "start", "line"]) || 0
                severity = severity_label(d["severity"])
                "#{file}:#{line + 1}: #{severity}: #{d["message"]}"
              end)
            end)
            |> Enum.join("\n")

          {:ok, result}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp severity_label(1), do: "error"
  defp severity_label(2), do: "warning"
  defp severity_label(3), do: "info"
  defp severity_label(4), do: "hint"
  defp severity_label(_), do: "unknown"
end
