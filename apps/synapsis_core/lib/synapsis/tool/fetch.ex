defmodule Synapsis.Tool.Fetch do
  @moduledoc "Fetch content from a URL."
  @behaviour Synapsis.Tool.Behaviour

  @impl true
  def name, do: "fetch"

  @impl true
  def description, do: "Fetch content from a URL for documentation or reference."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "The URL to fetch"}
      },
      "required" => ["url"]
    }
  end

  @impl true
  def call(input, _context) do
    url = input["url"]

    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        truncated = String.slice(body, 0, 50_000)
        {:ok, truncated}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
