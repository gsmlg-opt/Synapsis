defmodule Synapsis.Tool.Fetch do
  @moduledoc "Fetch content from a URL."
  use Synapsis.Tool

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

  @blocked_hosts ~w(localhost 127.0.0.1 0.0.0.0 ::1 169.254.169.254 metadata.google.internal)

  @impl true
  def execute(input, _context) do
    url = input["url"]

    with :ok <- validate_url(url) do
      fetch_url(url)
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, "Only http and https URLs are allowed"}

      %URI{host: host} when is_binary(host) ->
        if host in @blocked_hosts or private_ip?(host) or resolves_to_private?(host) do
          {:error, "Access to internal/private addresses is not allowed"}
        else
          :ok
        end

      _ ->
        {:error, "Invalid URL"}
    end
  end

  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, addr} -> private_addr?(addr)
      _ -> false
    end
  end

  defp resolves_to_private?(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, addr} -> private_addr?(addr)
      _ -> false
    end
  end

  defp private_addr?({10, _, _, _}), do: true
  defp private_addr?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_addr?({192, 168, _, _}), do: true
  defp private_addr?({127, _, _, _}), do: true
  defp private_addr?({0, 0, 0, 0}), do: true
  defp private_addr?({169, 254, _, _}), do: true
  defp private_addr?(_), do: false

  defp fetch_url(url) do
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
