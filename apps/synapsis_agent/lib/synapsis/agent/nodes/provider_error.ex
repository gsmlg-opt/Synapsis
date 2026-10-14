defmodule Synapsis.Agent.Nodes.ProviderError do
  @moduledoc "Formats safe provider failures for transcript and session notifications."

  alias Backplane.AiProtocol.Error

  @spec message(term()) :: String.t()
  def message(reason) when is_binary(reason), do: "Provider error: #{reason}"

  def message(%Error{message: message, http_status: status}) do
    description =
      if is_binary(message) and String.trim(message) != "",
        do: message,
        else: "Provider request failed"

    prefix =
      if is_integer(status) and status in 100..599,
        do: "Provider error (HTTP #{status})",
        else: "Provider error"

    "#{prefix}: #{description}"
  end

  def message(_reason), do: "Provider error: Provider request failed"
end
