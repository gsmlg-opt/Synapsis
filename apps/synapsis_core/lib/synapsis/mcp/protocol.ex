defmodule Synapsis.MCP.Protocol do
  @moduledoc "JSON-RPC encoding/decoding for MCP (Model Context Protocol)."

  def encode_request(id, method, params \\ %{}) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    "#{msg}\n"
  end

  def encode_notification(method, params \\ %{}) do
    msg =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params
      })

    "#{msg}\n"
  end

  def decode_message(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce({[], ""}, fn line, {messages, _rest} ->
      case Jason.decode(line) do
        {:ok, msg} -> {[msg | messages], ""}
        {:error, _} -> {messages, line}
      end
    end)
    |> then(fn {messages, rest} -> {Enum.reverse(messages), rest} end)
  end
end
