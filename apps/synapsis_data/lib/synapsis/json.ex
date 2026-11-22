defmodule Synapsis.JSON do
  @moduledoc "Non-raising Formata encoding for callers that handle invalid data explicitly."

  def encode(value, opts \\ []) do
    with {:ok, iodata} <- encode_to_iodata(value, opts), do: {:ok, IO.iodata_to_binary(iodata)}
  end

  def encode_to_iodata(value, opts \\ []) do
    {:ok, Formata.JSON.encode_to_iodata!(value, opts)}
  rescue
    _ in [ArgumentError, Formata.Error, Protocol.UndefinedError] ->
      {:error, :invalid_json}

    error in ErlangError ->
      case error.original do
        {:invalid_byte, _} -> {:error, :invalid_json}
        _ -> reraise error, __STACKTRACE__
      end
  end
end
