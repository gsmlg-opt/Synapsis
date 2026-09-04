defmodule Synapsis.Backplane.Client do
  @moduledoc "Bounded client for Backplane capability discovery surfaces."

  alias Synapsis.Backplane.Connection

  @default_timeout 5_000

  @callback fetch_models(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_skills(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_skill(Connection.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback list_tools(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}

  def fetch_models(%Connection{} = connection, opts \\ []) do
    with {:ok, %{"data" => models}} when is_list(models) <-
           get_json(connection.base_url <> "/v1/models", auth_headers(connection), opts) do
      {:ok, models}
    else
      {:ok, _body} -> {:error, :invalid_models_response}
      error -> error
    end
  end

  def list_skills(%Connection{} = connection, opts \\ []) do
    with {:ok, %{"data" => skills}} when is_list(skills) <-
           get_json(connection.base_url <> "/skills", auth_headers(connection), opts) do
      {:ok, skills}
    else
      {:ok, _body} -> {:error, :invalid_skills_response}
      error -> error
    end
  end

  def fetch_skill(%Connection{} = connection, slug, opts \\ []) when is_binary(slug) do
    get_json(
      connection.base_url <> "/skills/" <> URI.encode(slug),
      auth_headers(connection),
      opts
    )
  end

  def list_tools(%Connection{} = connection, opts \\ []) do
    url = connection.base_url <> "/mcp"
    auth_headers = auth_headers(connection)

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "synapsis", "version" => "0.1.0"}
      }
    }

    with {:ok, response} <- post_json(url, initialize, auth_headers, opts),
         :ok <- mcp_result(response.body),
         headers <- session_header(response),
         {:ok, listed} <-
           post_json(
             url,
             %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
             auth_headers ++ headers,
             opts
           ),
         {:ok, tools} <- tools_result(listed.body) do
      {:ok, tools}
    end
  end

  defp get_json(url, headers, opts) do
    case Req.get(url, [headers: headers] ++ request_opts(opts)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_json(url, body, headers, opts) do
    request_opts = [json: body, headers: headers] ++ request_opts(opts)

    case Req.post(url, request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_opts(opts) do
    [receive_timeout: Keyword.get(opts, :timeout, @default_timeout), retry: false]
  end

  defp mcp_result(%{"result" => _result}), do: :ok
  defp mcp_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp mcp_result(_body), do: {:error, :invalid_initialize_response}

  defp tools_result(%{"result" => %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
  defp tools_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp tools_result(_body), do: {:error, :invalid_tools_response}

  defp session_header(response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [session_id | _] -> [{"mcp-session-id", session_id}]
      [] -> []
    end
  end

  defp auth_headers(%Connection{credential: credential}) when is_binary(credential),
    do: [{"authorization", "Bearer " <> credential}]

  defp auth_headers(_connection), do: []
end
