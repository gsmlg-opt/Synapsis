defmodule Synapsis.Tool.WebSearch do
  @moduledoc "Search the web using a configurable search API."
  use Synapsis.Tool

  @impl true
  def name, do: "web_search"

  @impl true
  def description, do: "Search the web for information. Returns titles, URLs, and snippets."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Search query"},
        "max_results" => %{
          "type" => "integer",
          "description" => "Maximum results to return (default: 5)"
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def permission_level, do: :read

  @impl true
  def category, do: :web

  @impl true
  def execute(input, _context) do
    query = input["query"]
    max_results = min(input["max_results"] || 5, 20)

    api_key =
      System.get_env("BRAVE_SEARCH_API_KEY") ||
        Application.get_env(:synapsis_core, :brave_search_api_key)

    if is_nil(api_key) do
      {:error,
       "Web search API key not configured. Set BRAVE_SEARCH_API_KEY environment variable."}
    else
      search(query, max_results, api_key)
    end
  end

  @default_base_url "https://api.search.brave.com"

  defp search(query, max_results, api_key) do
    base_url =
      Application.get_env(:synapsis_core, :brave_search_base_url, @default_base_url)

    url = "#{base_url}/res/v1/web/search"

    case Req.get(url,
           params: [q: query, count: max_results],
           headers: [{"X-Subscription-Token", api_key}, {"Accept", "application/json"}],
           receive_timeout: 10_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        results = parse_brave_results(body)
        {:ok, Jason.encode!(results)}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, parsed} ->
            results = parse_brave_results(parsed)
            {:ok, Jason.encode!(results)}

          {:error, _} ->
            {:ok, body}
        end

      {:ok, %{status: status}} ->
        {:error, "Search API returned HTTP #{status}"}

      {:error, _reason} ->
        {:error, "Search request failed"}
    end
  end

  defp parse_brave_results(body) do
    web_results = get_in(body, ["web", "results"]) || []

    Enum.map(web_results, fn result ->
      %{
        "title" => result["title"] || "",
        "url" => result["url"] || "",
        "snippet" => result["description"] || ""
      }
    end)
  end
end
