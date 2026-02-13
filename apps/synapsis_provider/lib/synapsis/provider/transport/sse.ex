defmodule Synapsis.Provider.Transport.SSE do
  @moduledoc """
  Shared SSE line parser. Pure functions for splitting raw HTTP response data
  into decoded JSON events. Used by all transport plugins.
  """

  @doc """
  Parse raw SSE data into a list of decoded JSON maps or sentinel strings.

  Handles:
  - `data: [DONE]` sentinel (returned as the string `"[DONE]"`)
  - `data: {json}` lines (decoded to maps)
  - Partial/incomplete JSON lines (silently dropped)
  - Non-data lines like `event:` or blank lines (ignored)
  """
  @spec parse_lines(binary()) :: [map() | String.t()]
  def parse_lines(data) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line("data: [DONE]" <> _), do: ["[DONE]"]

  defp parse_line("data:" <> rest) do
    json_str = String.trim_leading(rest)

    case Jason.decode(json_str) do
      {:ok, parsed} -> [parsed]
      _ -> []
    end
  end

  defp parse_line(_), do: []
end
