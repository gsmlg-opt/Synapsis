defmodule Synapsis.Web.Fetch do
  @moduledoc """
  Readable native HTTP documents. Acquisition, source computation and normal
  retirement share one live deadline. Only successful complete documents cache
  inside a native run; standalone callbacks always acquire their own bytes.
  """
  @behaviour Backplane.AgentRuntime.Codex.Web.ReadableFetch
  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Backplane.AgentRuntime.Codex.Web.ReadableFetch
  alias Synapsis.Web.Fetch.{Cache, Document}
  alias Synapsis.Web.Transport

  @fields %{
    "finalUrl" => "final_url",
    "contentType" => "content_type",
    "extractMode" => "extract_mode",
    "externalContent" => "external_content",
    "rawLength" => "raw_length"
  }
  @headers_version "source488631c-accept-language-useragent-v1"
  @pin "488631c18fae7cc541ba8fc8beff6cbb0438787b"

  @impl true
  def fetch(arguments, opts) do
    started = now()

    with {:ok, ^arguments} <- InputSchema.validate(ReadableFetch.schema(), arguments),
         {:ok, ceiling} <- ceiling(opts, started),
         {:ok, _uri} <- authorize(arguments["url"], opts),
         {:ok, live} <- deadline(opts, ceiling) do
      controls = %{
        "extractMode" => Map.get(arguments, "extract_mode", "markdown"),
        "maxChars" => arguments |> Map.get("max_chars", 20_000) |> max(100) |> min(20_000)
      }

      key = cache_key(arguments, controls, opts)

      case cached(key, live) do
        {:ok, result} ->
          hit = Map.put(result, "cached", true)

          with :ok <- validate_public(hit, opts),
               {:ok, _} <- deadline(opts, ceiling),
               do: {:ok, hit}

        :miss ->
          acquire(arguments, controls, opts, ceiling, started, key)

        {:error, reason} ->
          failure(:timeout, "Document cache lookup could not complete", reason)
      end
    end
  end

  defp acquire(arguments, controls, opts, ceiling, started, key) do
    with {:ok, response, final_url} <- follow(arguments["url"], opts, ceiling, 3),
         {:ok, live} <- deadline(opts, ceiling),
         metadata =
           Map.merge(controls, %{
             "url" => arguments["url"],
             "finalUrl" => final_url,
             "status" => response.status,
             "contentType" => header(response.headers, "content-type")
           }),
         {:ok, document} <-
           Document.prepare(
             response.body,
             metadata,
             opts
             |> Keyword.take([:node_executable, :helper_path, :observer_pid])
             |> Keyword.put(:deadline, live)
           ),
         {:ok, _} <- deadline(opts, ceiling),
         result =
           document
           |> Map.new(fn {key, value} -> {Map.get(@fields, key, key), value} end)
           |> Map.put(
             "fetched_at",
             DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
           )
           |> Map.put("took_ms", now() - started),
         :ok <- validate_public(result, opts),
         {:ok, _} <- deadline(opts, ceiling) do
      with :ok <- publish(key, result, opts, ceiling),
           {:ok, _} <- deadline(opts, ceiling),
           do: {:ok, result}
    else
      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        failure(:execution_failure, "Readable document computation failed", reason)
    end
  end

  defp follow(url, opts, ceiling, redirects) do
    with {:ok, uri} <- authorize(url, opts),
         {:ok, live} <- deadline(opts, ceiling),
         {:ok, response} <- Transport.document(uri, live - now()),
         {:ok, _} <- deadline(opts, ceiling) do
      cond do
        response.status in [301, 302, 303, 307, 308] and redirects > 0 ->
          case header(response.headers, "location") do
            location when is_binary(location) and location != "" ->
              follow(URI.merge(uri, location) |> URI.to_string(), opts, ceiling, redirects - 1)

            _ ->
              failure(:malformed_result, "Document redirect has no destination")
          end

        response.status in 200..299 ->
          {:ok, response, url}

        true ->
          failure(:transient_transport, "Document response was unsuccessful")
      end
    end
  end

  defp authorize(url, opts) when is_binary(url) do
    uri = URI.parse(url)
    hosts = Keyword.get(opts, :allowed_hosts, [])

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.fragment) and
         (hosts == :all or (is_list(hosts) and uri.host in hosts)),
       do: {:ok, uri},
       else: failure(:forbidden, "Document URL is not authorized")
  end

  defp ceiling(opts, started) do
    case Keyword.get(opts, :timeout, 5_000) do
      value when is_integer(value) and value > 0 -> {:ok, started + min(value, 5_000)}
      _ -> failure(:validation, "Document timeout must be positive")
    end
  end

  defp deadline(opts, ceiling) do
    case Keyword.get(opts, :runtime_context) do
      %{effect_deadline: accessor} when is_function(accessor, 0) ->
        case accessor.() do
          {:ok, %{deadline_ms: live, remaining_ms: remaining}}
          when is_integer(live) and is_integer(remaining) and remaining > 0 ->
            current(min(ceiling, min(live, now() + remaining)))

          {:error, %Error{}} = error ->
            error

          _ ->
            failure(:timeout, "Document runtime deadline is unavailable")
        end

      nil ->
        current(ceiling)

      _ ->
        failure(:validation, "Document runtime context is invalid")
    end
  end

  defp current(value),
    do:
      if(value > now(), do: {:ok, value}, else: failure(:timeout, "Document deadline exhausted"))

  defp cache_key(arguments, controls, opts) do
    case {Keyword.get(opts, :cache_scope), Keyword.get(opts, :runtime_context)} do
      {scope,
       %{identity: %{session_binding_identity: binding, run_id: run, incarnation: incarnation}}}
      when is_map(scope) and not is_nil(binding) and is_binary(run) and is_integer(incarnation) ->
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(
            {@pin, :readable_document_1,
             %{"readability" => "0.6.0", "linkedom" => "0.18.13", "entities" => "8.1.0"}, scope,
             binding, run, incarnation, arguments["url"], controls, arguments["instructions"],
             @headers_version},
            [:deterministic]
          )
        )

      _ ->
        nil
    end
  end

  defp cached(nil, _deadline), do: :miss
  defp cached(key, deadline), do: Cache.get(key, deadline)

  defp publish(nil, _result, _opts, _ceiling), do: :ok

  defp publish(key, result, opts, ceiling) do
    with {:ok, live} <- deadline(opts, ceiling),
         :ok <- Cache.put(key, result, live) do
      :ok
    else
      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        failure(:timeout, "Document cache publication could not complete", reason)
    end
  end

  # Check the final model presentation as well as the structured document before
  # cache publication. Existing native/projection budgets remain independent.
  defp validate_public(result, opts) do
    limit = Keyword.get(opts, :result_limit, 1_048_576)

    with true <- is_integer(limit) and limit > 0,
         {:ok, content} <- Jason.encode(result),
         true <-
           byte_size(content) <= 262_144 and
             :erlang.external_size(
               Map.merge(result, %{"content" => content, "is_error" => false})
             ) <= min(limit, 1_048_576) do
      :ok
    else
      _ -> failure(:budget_exceeded, "Document presentation exceeds the public bound")
    end
  end

  defp header(headers, key),
    do:
      Enum.find_value(headers, fn {name, value} -> if String.downcase(name) == key, do: value end)

  defp failure(class, message, reason \\ nil),
    do: {:error, Error.new(class, message, details: %{reason: reason})}

  defp now, do: System.monotonic_time(:millisecond)
end
