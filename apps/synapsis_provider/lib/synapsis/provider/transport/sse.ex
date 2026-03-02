defmodule Synapsis.Provider.Transport.SSE do
  @moduledoc """
  SSE (Server-Sent Events) parser with buffer accumulation.

  HTTP chunks can split SSE events at arbitrary byte boundaries. This module
  handles partial lines by carrying a buffer between chunks, inspired by
  the `req_llm` / `server_sent_events` approach.
  """

  @doc """
  Parse raw SSE data combined with a buffer of leftover bytes from the
  previous HTTP chunk. Returns `{parsed_events, remaining_buffer}`.

  The remaining buffer should be passed as the second argument on the
  next invocation to handle lines that were split across HTTP chunks.
  """
  @spec accumulate_and_parse(binary(), binary()) :: {[map() | String.t()], binary()}
  def accumulate_and_parse(chunk, buffer) do
    combined = buffer <> chunk

    # Split on double-newline (SSE event boundary) to find complete events.
    # The last segment may be incomplete — carry it forward as the new buffer.
    case String.split(combined, "\n\n") do
      [incomplete] ->
        # No complete event yet — everything is buffer
        {[], incomplete}

      segments ->
        {complete, [tail]} = Enum.split(segments, -1)

        events =
          complete
          |> Enum.flat_map(fn segment ->
            segment
            |> String.split("\n", trim: true)
            |> Enum.flat_map(&parse_line/1)
          end)

        {events, tail}
    end
  end

  @doc """
  Stateless parse — splits raw data by newlines and decodes data: lines.
  Kept for backwards compatibility with tests and non-streaming callers.
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
