defmodule Synapsis.Provider.Adapter do
  @moduledoc """
  Unified entry point for all provider interactions. Replaces the per-provider
  module pattern (`Anthropic`, `OpenAICompat`, `Google`) with a single adapter
  that delegates to transport plugins and uses event/message mappers.

  Implements the same public interface consumed by `Session.Stream`:
  - `stream/2` — starts async streaming, sends events to caller
  - `cancel/1` — cancels an in-progress stream
  - `models/1` — returns available models
  - `format_request/3` — builds provider-specific request body
  """

  alias Synapsis.Provider.{EventMapper, MessageMapper, ModelRegistry}
  alias Synapsis.Provider.Transport

  require Logger

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a streaming request. Sends `{:provider_chunk, event}` and
  `:provider_done` to the calling process.

  `config` must include `:type` (e.g. "anthropic", "openai", "google").
  """
  def stream(request, config) do
    caller = self()
    transport_type = resolve_transport_type(config[:type] || config["type"])

    task =
      Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
        do_stream(transport_type, request, config, caller)
      end)

    {:ok, task.ref}
  end

  @doc "Cancel an in-progress stream."
  def cancel(ref) do
    Task.Supervisor.terminate_child(Synapsis.Provider.TaskSupervisor, ref)
    :ok
  end

  @doc "List available models for the given provider config."
  def models(config) do
    transport_type = resolve_transport_type(config[:type] || config["type"])
    base_url = config[:base_url] || config["base_url"] || ""

    case transport_type do
      :openai ->
        Transport.OpenAI.fetch_models(config)

      :anthropic ->
        cond do
          String.contains?(base_url, "moonshot") ->
            {:ok, ModelRegistry.list(:moonshot)}

          String.contains?(base_url, "bigmodel") or String.contains?(base_url, "z.ai") ->
            {:ok, ModelRegistry.list(:zhipu)}

          String.contains?(base_url, "minimax") ->
            {:ok, ModelRegistry.list(:minimax)}

          true ->
            {:ok, ModelRegistry.list(:anthropic)}
        end

      :google ->
        {:ok, ModelRegistry.list(:google)}
    end
  end

  @doc """
  Format messages and tools into provider-specific request format.
  Delegates to `MessageMapper.build_request/4`.
  """
  def format_request(messages, tools, opts) do
    provider_type = resolve_transport_type(opts[:provider_type] || opts[:type] || "anthropic")
    MessageMapper.build_request(provider_type, messages, tools, opts)
  end

  @doc """
  Synchronous (non-streaming) single-turn call. Returns `{:ok, text}` or
  `{:error, reason}`. Intended for short auditor/analysis calls where
  the full response is needed before continuing.

  `request` is a provider-format map (from `format_request/3`).
  `config` must include `:type` and `:api_key`.
  """
  def complete(request, config) do
    transport_type = resolve_transport_type(config[:type] || config["type"])

    task =
      Task.Supervisor.async_nolink(
        Synapsis.Provider.TaskSupervisor,
        fn -> do_complete(transport_type, request, config) end,
        timeout: 60_000
      )

    case Task.yield(task, 60_000) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, "auditor timeout"}
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming — inline SSE parse + event mapping per transport
  # ---------------------------------------------------------------------------

  defp do_stream(:anthropic, request, config, caller) do
    base_url = config[:base_url] || Transport.Anthropic.default_base_url()
    url = "#{base_url}/v1/messages"

    # Send both auth headers: official Anthropic uses x-api-key,
    # compatible proxies (MiniMax, Moonshot, ZhipuAI) require Bearer.
    headers =
      [
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ] ++ anthropic_auth_headers(config[:api_key])

    request_id = Ecto.UUID.generate()
    session_id = config[:session_id]
    start_time = System.monotonic_time()

    emit_request_telemetry(session_id, request_id, :post, url, headers, request, :anthropic, request[:model])

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: request,
          receive_timeout: 300_000,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, resp} ->
            {events, buffer} = Transport.SSE.accumulate_and_parse(data, resp.body || "")

            for chunk <- events do
              event = EventMapper.map_event(:anthropic, chunk)
              send(caller, {:provider_chunk, event})
            end

            {:cont, {req, %{resp | body: buffer}}}
          end
        )

      emit_response_telemetry(session_id, request_id, resp, start_time)
      handle_stream_response(resp, caller)
    rescue
      e ->
        emit_error_telemetry(session_id, request_id, e, start_time)
        send(caller, {:provider_error, Exception.message(e)})
    end
  end

  defp do_stream(:openai, request, config, caller) do
    case do_openai_stream(request, config, caller) do
      {:retry_auth, _resp} ->
        case maybe_refresh_oauth(config) do
          {:ok, new_config} ->
            case do_openai_stream(request, new_config, caller) do
              {:retry_auth, _} ->
                send(caller, {:provider_error, "HTTP 401: Authentication failed after token refresh"})

              _ ->
                :ok
            end

          _ ->
            send(caller, {:provider_error, "HTTP 401: Authentication failed"})
        end

      _ ->
        :ok
    end
  end

  defp do_stream(:google, request, config, caller) do
    base_url = config[:base_url] || Transport.Google.default_base_url()
    model = request[:model] || "gemini-2.5-flash"

    url = "#{base_url}/v1beta/models/#{model}:streamGenerateContent?alt=sse"

    headers = [{"content-type", "application/json"}, {"x-goog-api-key", config[:api_key]}]
    body = Map.drop(request, [:model, :stream])

    request_id = Ecto.UUID.generate()
    session_id = config[:session_id]
    start_time = System.monotonic_time()

    emit_request_telemetry(session_id, request_id, :post, url, headers, body, :google, model)

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: body,
          receive_timeout: 300_000,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, resp} ->
            {events, buffer} = Transport.SSE.accumulate_and_parse(data, resp.body || "")

            for chunk <- events do
              event = EventMapper.map_event(:google, chunk)
              send(caller, {:provider_chunk, event})
            end

            {:cont, {req, %{resp | body: buffer}}}
          end
        )

      emit_response_telemetry(session_id, request_id, resp, start_time)
      handle_stream_response(resp, caller)
    rescue
      e ->
        emit_error_telemetry(session_id, request_id, e, start_time)
        send(caller, {:provider_error, Exception.message(e)})
    end
  end

  # ---------------------------------------------------------------------------
  # OpenAI stream/complete with 401 retry support
  # ---------------------------------------------------------------------------

  defp do_openai_stream(request, config, caller) do
    base_url = config[:base_url] || Transport.OpenAI.default_base_url()

    {url, headers, body} =
      if config[:azure] do
        model = request[:model] || "gpt-4.1"
        api_version = config[:api_version] || "2024-02-15-preview"

        url =
          "#{base_url}/openai/deployments/#{model}/chat/completions?api-version=#{api_version}"

        headers = [
          {"api-key", config[:api_key]},
          {"content-type", "application/json"}
        ]

        {url, headers, Map.drop(request, [:model])}
      else
        headers =
          [{"content-type", "application/json"}] ++
            if(config[:api_key], do: [{"authorization", "Bearer #{config[:api_key]}"}], else: [])

        {"#{base_url}/v1/chat/completions", headers, request}
      end

    request_id = Ecto.UUID.generate()
    session_id = config[:session_id]
    start_time = System.monotonic_time()

    emit_request_telemetry(session_id, request_id, :post, url, headers, body, :openai, request[:model])

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: body,
          receive_timeout: 300_000,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, resp} ->
            {events, buffer} = Transport.SSE.accumulate_and_parse(data, resp.body || "")

            for chunk <- events do
              event = EventMapper.map_event(:openai, chunk)
              send(caller, {:provider_chunk, event})
            end

            {:cont, {req, %{resp | body: buffer}}}
          end
        )

      emit_response_telemetry(session_id, request_id, resp, start_time)

      if resp.status == 401 and config[:oauth] do
        {:retry_auth, resp}
      else
        handle_stream_response(resp, caller)
      end
    rescue
      e ->
        emit_error_telemetry(session_id, request_id, e, start_time)
        send(caller, {:provider_error, Exception.message(e)})
    end
  end

  # ---------------------------------------------------------------------------
  # Stream response handling — uses accumulated raw data for error extraction
  # ---------------------------------------------------------------------------

  defp handle_stream_response(resp, caller) do
    if resp.status >= 400 do
      error_msg = extract_error(resp)
      send(caller, {:provider_error, "HTTP #{resp.status}: #{error_msg}"})
    else
      send(caller, :provider_done)
    end
  end

  # ---------------------------------------------------------------------------
  # Synchronous complete (auditor path)
  # ---------------------------------------------------------------------------

  defp do_complete(:anthropic, request, config) do
    base_url = config[:base_url] || Transport.Anthropic.default_base_url()
    url = "#{base_url}/v1/messages"

    body = Map.merge(request, %{stream: false})

    headers =
      [
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ] ++ anthropic_auth_headers(config[:api_key])

    response = Req.post!(url, headers: headers, json: body, receive_timeout: 60_000)

    case response.body do
      %{"content" => [%{"text" => text} | _]} ->
        {:ok, text}

      %{"error" => %{"message" => msg}} ->
        {:error, msg}

      other ->
        {:error, "unexpected response: #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp do_complete(:openai, request, config) do
    case do_openai_complete(request, config) do
      {:retry_auth, _} ->
        case maybe_refresh_oauth(config) do
          {:ok, new_config} ->
            case do_openai_complete(request, new_config) do
              {:retry_auth, _} -> {:error, "HTTP 401: Authentication failed after token refresh"}
              result -> result
            end

          _ ->
            {:error, "HTTP 401: Authentication failed"}
        end

      result ->
        result
    end
  end

  defp do_complete(:google, request, config) do
    base_url = config[:base_url] || Transport.Google.default_base_url()
    model = request[:model] || "gemini-2.5-flash"
    url = "#{base_url}/v1beta/models/#{model}:generateContent"

    body = Map.drop(request, [:model, :stream])

    response =
      Req.post!(url,
        headers: [{"content-type", "application/json"}, {"x-goog-api-key", config[:api_key]}],
        json: body,
        receive_timeout: 60_000
      )

    case response.body do
      %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]} ->
        {:ok, text}

      other ->
        {:error, "unexpected response: #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # OpenAI complete with 401 retry support
  # ---------------------------------------------------------------------------

  defp do_openai_complete(request, config) do
    base_url = config[:base_url] || Transport.OpenAI.default_base_url()
    url = "#{base_url}/v1/chat/completions"

    body = Map.merge(request, %{stream: false})

    headers =
      [{"content-type", "application/json"}] ++
        if(config[:api_key], do: [{"authorization", "Bearer #{config[:api_key]}"}], else: [])

    response = Req.post!(url, headers: headers, json: body, receive_timeout: 60_000)

    if response.status == 401 and config[:oauth] do
      {:retry_auth, response}
    else
      case response.body do
        %{"choices" => [%{"message" => %{"content" => text}} | _]} ->
          {:ok, text}

        %{"error" => %{"message" => msg}} ->
          {:error, msg}

        other ->
          {:error, "unexpected response: #{inspect(other)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Error extraction
  # ---------------------------------------------------------------------------

  defp extract_error(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> msg
      {:ok, %{"error" => msg}} when is_binary(msg) -> msg
      _ -> String.slice(body, 0, 200)
    end
  end

  defp extract_error(%{body: %{"error" => %{"message" => msg}}}), do: msg
  defp extract_error(%{body: %{"error" => msg}}) when is_binary(msg), do: msg
  defp extract_error(%{body: body}) when is_map(body), do: inspect(body) |> String.slice(0, 200)
  defp extract_error(_), do: "unknown error"

  # Sends both x-api-key (official Anthropic) and Authorization: Bearer
  # (required by MiniMax, Moonshot, ZhipuAI and other Anthropic-compat proxies).
  defp anthropic_auth_headers(nil), do: []

  defp anthropic_auth_headers(api_key) do
    [
      {"x-api-key", api_key},
      {"authorization", "Bearer #{api_key}"}
    ]
  end

  # ---------------------------------------------------------------------------
  # OAuth token refresh
  # ---------------------------------------------------------------------------

  defp maybe_refresh_oauth(%{oauth: true, provider_id: provider_id}) do
    case Synapsis.Providers.refresh_oauth(provider_id) do
      {:ok, provider} ->
        # Rebuild the runtime config with fresh tokens
        new_key =
          Synapsis.Provider.OAuth.OpenAI.access_token_from_config(provider.config) ||
            provider.api_key_encrypted

        {:ok, %{api_key: new_key, oauth: true, provider_id: provider_id}}

      error ->
        error
    end
  end

  defp maybe_refresh_oauth(_config), do: {:error, :not_oauth}

  # ---------------------------------------------------------------------------
  # Telemetry emission — unconditional, zero overhead when no handler attached
  # ---------------------------------------------------------------------------

  defp emit_request_telemetry(session_id, request_id, method, url, headers, body, provider, model) do
    :telemetry.execute(
      [:synapsis, :provider, :request],
      %{system_time: System.system_time()},
      %{
        session_id: session_id,
        request_id: request_id,
        method: method,
        url: url,
        headers: headers,
        body: body,
        provider: provider,
        model: model
      }
    )
  end

  defp emit_response_telemetry(session_id, request_id, resp, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:synapsis, :provider, :response],
      %{duration: duration, system_time: System.system_time()},
      %{
        session_id: session_id,
        request_id: request_id,
        status: resp.status,
        headers: resp_headers(resp),
        body: resp_body(resp),
        complete: resp.status < 400
      }
    )
  end

  defp emit_error_telemetry(session_id, request_id, exception, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:synapsis, :provider, :response],
      %{duration: duration, system_time: System.system_time()},
      %{
        session_id: session_id,
        request_id: request_id,
        status: 0,
        headers: [],
        body: nil,
        complete: false,
        error: %{reason: :exception, message: Exception.message(exception)}
      }
    )
  end

  defp resp_headers(%{headers: headers}) when is_list(headers), do: headers
  defp resp_headers(%{headers: headers}) when is_map(headers) do
    Enum.flat_map(headers, fn {k, v} when is_list(v) -> Enum.map(v, &{k, &1}); {k, v} -> [{k, v}] end)
  end
  defp resp_headers(_), do: []

  defp resp_body(%{body: body}) when is_binary(body), do: body
  defp resp_body(%{body: body}) when is_map(body), do: Jason.encode!(body)
  defp resp_body(_), do: nil

  # ---------------------------------------------------------------------------
  # Transport resolution
  # ---------------------------------------------------------------------------

  @doc false
  def resolve_transport_type(type) when is_binary(type) do
    case type do
      "anthropic" -> :anthropic
      "openai" -> :openai
      "openai_compat" -> :openai
      "local" -> :openai
      "openrouter" -> :openai
      "groq" -> :openai
      "deepseek" -> :openai
      "google" -> :google
      _ -> :openai
    end
  end

  def resolve_transport_type(nil), do: :openai
  def resolve_transport_type(type) when type in [:anthropic, :openai, :google], do: type
  def resolve_transport_type(_), do: :openai
end
