defmodule Synapsis.LSP.Protocol do
  @moduledoc "JSON-RPC encoding/decoding for LSP."

  def encode_request(id, method, params) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    "Content-Length: #{byte_size(msg)}\r\n\r\n#{msg}"
  end

  def encode_notification(method, params) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params
      })

    "Content-Length: #{byte_size(msg)}\r\n\r\n#{msg}"
  end

  def decode_message(data) do
    case extract_json(data) do
      {:ok, json, rest} ->
        case Jason.decode(json) do
          {:ok, msg} -> {:ok, msg, rest}
          {:error, _} -> {:error, :invalid_json}
        end

      :incomplete ->
        :incomplete

      _ ->
        :incomplete
    end
  end

  defp extract_json(data) do
    case Regex.run(~r/Content-Length: (\d+)\r\n\r\n/s, data, return: :index) do
      [{header_start, header_len}, {len_start, len_len}] ->
        content_length = data |> binary_part(len_start, len_len) |> String.to_integer()
        body_start = header_start + header_len
        total_needed = body_start + content_length

        if byte_size(data) >= total_needed do
          json = binary_part(data, body_start, content_length)
          rest = binary_part(data, total_needed, byte_size(data) - total_needed)
          {:ok, json, rest}
        else
          :incomplete
        end

      nil ->
        :incomplete
    end
  end
end
