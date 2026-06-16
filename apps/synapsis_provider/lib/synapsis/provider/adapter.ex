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

  alias Synapsis.Provider.{EventMapper, MessageMapper, ModelRegistry, StreamGuard}
  alias Synapsis.Provider.Transport
  alias SynapsisProvider.Sanitizer

  @anthropic_api_version "2023-06-01"
  @stream_timeout_ms 300_000
  @request_timeout_ms 60_000
  @stream_guard_key :synapsis_stream_guard
  @stream_guard_violation_key :synapsis_stream_guard_violation

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
          discovered_models?(config) ->
            Transport.Anthropic.fetch_models(config)

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

  defp discovered_models?(config) do
    config[:discover_models] == true or config["discover_models"] == true
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
      {:exit, _reason} -> {:error, "completion failed"}
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
        {"anthropic-version", @anthropic_api_version},
        {"content-type", "application/json"}
      ] ++ anthropic_auth_headers(config[:api_key])

    request_id = Ecto.UUID.generate()
    session_id = config[:session_id]
    start_time = System.monotonic_time()
    stream_guard = stream_guard_state(config)

    emit_request_telemetry(
      session_id,
      request_id,
      :post,
      url,
      headers,
      request,
      :anthropic,
      request[:model]
    )

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: request,
          receive_timeout: @stream_timeout_ms,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, resp} ->
            {events, buffer} = Transport.SSE.accumulate_and_parse(data, resp.body || "")
            stream_guard = response_stream_guard(resp, stream_guard)

            case emit_mapped_events(:anthropic, events, caller, stream_guard) do
              {:ok, stream_guard} ->
                {:cont, {req, put_stream_response_state(resp, buffer, stream_guard)}}

              {:violation, stream_guard} ->
                resp =
                  resp
                  |> put_stream_response_state(buffer, stream_guard)
                  |> mark_stream_guard_violation()

                {:halt, {req, resp}}
            end
          end
        )

      resp = finish_stream_guard(resp, caller)

      emit_response_telemetry(session_id, request_id, resp, start_time)

      unless stream_guard_violation?(resp) do
        handle_stream_response(resp, caller)
      end
    rescue
      e in [Req.TransportError, RuntimeError, Jason.DecodeError] ->
        emit_error_telemetry(session_id, request_id, e, start_time)
        send(caller, {:provider_error, Exception.message(e)})
    end
  end

  defp do_stream(:openai, request, config, caller) do
    case do_openai_stream(request, config, caller) do
      {:retry_auth, _resp} ->
        case maybe_refresh_oauth(config) do
          {:ok, new_config} ->
            do_openai_stream(request, new_config, caller)

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
    stream_guard = stream_guard_state(config)

    emit_request_telemetry(session_id, request_id, :post, url, headers, body, :google, model)

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: body,
          receive_timeout: @stream_timeout_ms,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, resp} ->
            {events, buffer} = Transport.SSE.accumulate_and_parse(data, resp.body || "")
            stream_guard = response_stream_guard(resp, stream_guard)

            case emit_mapped_events(:google, events, caller, stream_guard) do
              {:ok, stream_guard} ->
                {:cont, {req, put_stream_response_state(resp, buffer, stream_guard)}}

              {:violation, stream_guard} ->
                resp =
                  resp
                  |> put_stream_response_state(buffer, stream_guard)
                  |> mark_stream_guard_violation()

                {:halt, {req, resp}}
            end
          end
        )

      resp = finish_stream_guard(resp, caller)

      emit_response_telemetry(session_id, request_id, resp, start_time)

      unless stream_guard_violation?(resp) do
        handle_stream_response(resp, caller)
      end
    rescue
      e in [Req.TransportError, RuntimeError, Jason.DecodeError] ->
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

        {openai_chat_completions_url(base_url), headers, request}
      end

    request_id = Ecto.UUID.generate()
    session_id = config[:session_id]
    start_time = System.monotonic_time()
    stream_guard = stream_guard_state(config)

    emit_request_telemetry(
      session_id,
      request_id,
      :post,
      url,
      headers,
      body,
      :openai,
      request[:model]
    )

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: body,
          receive_timeout: @stream_timeout_ms,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, resp} ->
            {events, buffer} = Transport.SSE.accumulate_and_parse(data, resp.body || "")
            stream_guard = response_stream_guard(resp, stream_guard)

            case emit_mapped_events(:openai, events, caller, stream_guard) do
              {:ok, stream_guard} ->
                {:cont, {req, put_stream_response_state(resp, buffer, stream_guard)}}

              {:violation, stream_guard} ->
                resp =
                  resp
                  |> put_stream_response_state(buffer, stream_guard)
                  |> mark_stream_guard_violation()

                {:halt, {req, resp}}
            end
          end
        )

      resp = finish_stream_guard(resp, caller)

      emit_response_telemetry(session_id, request_id, resp, start_time)

      cond do
        stream_guard_violation?(resp) ->
          :ok

        resp.status == 401 and config[:oauth] ->
          {:retry_auth, resp}

        true ->
          handle_stream_response(resp, caller)
      end
    rescue
      e in [Req.TransportError, RuntimeError, Jason.DecodeError] ->
        emit_error_telemetry(session_id, request_id, e, start_time)
        send(caller, {:provider_error, Exception.message(e)})
    end
  end

  # ---------------------------------------------------------------------------
  # Stream response handling — uses accumulated raw data for error extraction
  # ---------------------------------------------------------------------------

  defp emit_mapped_events(provider, events, caller, stream_guard) do
    Enum.reduce_while(events, {:ok, stream_guard}, fn chunk, {:ok, stream_guard} ->
      event = EventMapper.map_event(provider, chunk)

      case emit_provider_event(caller, event, stream_guard) do
        {:ok, stream_guard} -> {:cont, {:ok, stream_guard}}
        {:violation, stream_guard} -> {:halt, {:violation, stream_guard}}
      end
    end)
  end

  defp emit_provider_event(caller, event, nil) do
    send_provider_event(caller, event)
    {:ok, nil}
  end

  defp emit_provider_event(caller, {:events, events}, stream_guard) do
    Enum.reduce_while(events, {:ok, stream_guard}, fn event, {:ok, stream_guard} ->
      case emit_provider_event(caller, event, stream_guard) do
        {:ok, stream_guard} -> {:cont, {:ok, stream_guard}}
        {:violation, stream_guard} -> {:halt, {:violation, stream_guard}}
      end
    end)
  end

  defp emit_provider_event(caller, event, stream_guard) do
    case guarded_delta(event) do
      {:ok, kind, chunk, rebuild} ->
        with {:ok, stream_guard} <- flush_guard_for_kind(caller, stream_guard, kind) do
          scan_and_emit_guarded_delta(caller, stream_guard, kind, chunk, rebuild)
        end

      :skip ->
        with {:ok, stream_guard} <- maybe_flush_guard_before_event(caller, stream_guard, event) do
          send_provider_event(caller, event)
          {:ok, stream_guard}
        end
    end
  end

  defp guarded_delta({:text_delta, text}) when is_binary(text),
    do: {:ok, :text_delta, text, &{:text_delta, &1}}

  defp guarded_delta({:reasoning_delta, text}) when is_binary(text),
    do: {:ok, :reasoning_delta, text, &{:reasoning_delta, &1}}

  defp guarded_delta({:tool_input_delta, json}) when is_binary(json),
    do: {:ok, :tool_input_delta, json, &{:tool_input_delta, &1}}

  defp guarded_delta({:tool_call_delta, index, id, name, args}) when is_binary(args) do
    rebuild = &{:tool_call_delta, index, id, name, &1}
    {:ok, {:tool_call_delta, index, id, name}, args, rebuild}
  end

  defp guarded_delta(_event), do: :skip

  defp flush_guard_for_kind(_caller, %{kind: kind} = stream_guard, kind), do: {:ok, stream_guard}
  defp flush_guard_for_kind(_caller, %{kind: nil} = stream_guard, _kind), do: {:ok, stream_guard}

  defp flush_guard_for_kind(caller, stream_guard, _kind),
    do: flush_stream_guard(caller, stream_guard)

  defp scan_and_emit_guarded_delta(caller, stream_guard, kind, chunk, rebuild) do
    case StreamGuard.scan(stream_guard.scanner, chunk) do
      {:ok, "", scanner} ->
        {:ok, %{stream_guard | scanner: scanner, kind: kind, rebuild: rebuild}}

      {:ok, emit, scanner} ->
        send(caller, {:provider_chunk, rebuild.(emit)})
        {:ok, %{stream_guard | scanner: scanner, kind: kind, rebuild: rebuild}}

      {:violation, rule} ->
        # Redacted: rules may guard secrets and the reason is logged downstream.
        send(caller, {:provider_error, {:stream_violation, StreamGuard.redact(rule)}})
        {:violation, stream_guard}
    end
  end

  defp maybe_flush_guard_before_event(_caller, stream_guard, :ignore), do: {:ok, stream_guard}

  defp maybe_flush_guard_before_event(caller, stream_guard, _event) do
    flush_stream_guard(caller, stream_guard)
  end

  defp flush_stream_guard(_caller, %{rebuild: nil} = stream_guard), do: {:ok, stream_guard}

  defp flush_stream_guard(caller, stream_guard) do
    case StreamGuard.finish(stream_guard.scanner) do
      {:ok, ""} ->
        {:ok, reset_stream_guard(stream_guard)}

      {:ok, emit} ->
        send(caller, {:provider_chunk, stream_guard.rebuild.(emit)})
        {:ok, reset_stream_guard(stream_guard)}

      {:violation, rule} ->
        send(caller, {:provider_error, {:stream_violation, StreamGuard.redact(rule)}})
        {:violation, stream_guard}
    end
  end

  defp reset_stream_guard(stream_guard) do
    scanner = %{stream_guard.scanner | held: <<>>}
    %{stream_guard | scanner: scanner, kind: nil, rebuild: nil}
  end

  defp stream_guard_state(config) do
    config
    |> stream_guard_rules()
    |> case do
      [] -> nil
      rules -> %{scanner: StreamGuard.new(rules), kind: nil, rebuild: nil}
    end
  end

  defp stream_guard_rules(config) do
    rules = config[:stream_guard_rules] || config["stream_guard_rules"] || []

    case rules do
      rules when is_list(rules) ->
        Enum.filter(rules, &(is_binary(&1) and &1 != ""))

      _ ->
        []
    end
  end

  defp response_stream_guard(resp, initial_stream_guard) do
    Map.get(resp.private || %{}, @stream_guard_key, initial_stream_guard)
  end

  defp put_stream_response_state(resp, buffer, stream_guard) do
    private = Map.put(resp.private || %{}, @stream_guard_key, stream_guard)
    %{resp | body: buffer, private: private}
  end

  defp finish_stream_guard(resp, caller) do
    cond do
      stream_guard_violation?(resp) ->
        resp

      stream_guard = Map.get(resp.private || %{}, @stream_guard_key) ->
        case flush_stream_guard(caller, stream_guard) do
          {:ok, stream_guard} ->
            private = Map.put(resp.private || %{}, @stream_guard_key, stream_guard)
            %{resp | private: private}

          {:violation, stream_guard} ->
            resp
            |> put_stream_response_state(resp.body, stream_guard)
            |> mark_stream_guard_violation()
        end

      true ->
        resp
    end
  end

  defp mark_stream_guard_violation(resp) do
    private = Map.put(resp.private || %{}, @stream_guard_violation_key, true)
    %{resp | private: private}
  end

  defp stream_guard_violation?(resp) do
    Map.get(resp.private || %{}, @stream_guard_violation_key, false)
  end

  defp send_provider_event(caller, {:events, events}) do
    Enum.each(events, &send_provider_event(caller, &1))
  end

  defp send_provider_event(caller, event), do: send(caller, {:provider_chunk, event})

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
        {"anthropic-version", @anthropic_api_version},
        {"content-type", "application/json"}
      ] ++ anthropic_auth_headers(config[:api_key])

    case Req.post(url, headers: headers, json: body, receive_timeout: @request_timeout_ms) do
      {:ok, response} ->
        case response.body do
          %{"content" => [%{"text" => text} | _]} ->
            {:ok, text}

          %{"error" => %{"message" => msg}} ->
            {:error, msg}

          _other ->
            {:error, "unexpected response format"}
        end

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp do_complete(:openai, request, config) do
    case do_openai_complete(request, config) do
      {:retry_auth, _} ->
        case maybe_refresh_oauth(config) do
          {:ok, new_config} -> do_openai_complete(request, new_config)
          _ -> {:error, "HTTP 401: Authentication failed"}
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

    case Req.post(url,
           headers: [{"content-type", "application/json"}, {"x-goog-api-key", config[:api_key]}],
           json: body,
           receive_timeout: @request_timeout_ms
         ) do
      {:ok, response} ->
        case response.body do
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => text} | _]}} | _]} ->
            {:ok, text}

          _other ->
            {:error, "unexpected response format"}
        end

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # ---------------------------------------------------------------------------
  # OpenAI complete with 401 retry support
  # ---------------------------------------------------------------------------

  defp do_openai_complete(request, config) do
    base_url = config[:base_url] || Transport.OpenAI.default_base_url()
    url = openai_chat_completions_url(base_url)

    body = Map.merge(request, %{stream: false})

    headers =
      [{"content-type", "application/json"}] ++
        if(config[:api_key], do: [{"authorization", "Bearer #{config[:api_key]}"}], else: [])

    case Req.post(url, headers: headers, json: body, receive_timeout: @request_timeout_ms) do
      {:ok, response} ->
        if response.status == 401 and config[:oauth] do
          {:retry_auth, response}
        else
          case response.body do
            %{"choices" => [%{"message" => %{"content" => text}} | _]} ->
              {:ok, text}

            %{"error" => %{"message" => msg}} ->
              {:error, msg}

            _other ->
              {:error, "unexpected response format"}
          end
        end

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp openai_chat_completions_url(base_url) do
    base_url = base_url |> to_string() |> String.trim_trailing("/")

    if String.ends_with?(base_url, "/v1") do
      "#{base_url}/chat/completions"
    else
      "#{base_url}/v1/chat/completions"
    end
  end

  # ---------------------------------------------------------------------------
  # Error extraction
  # ---------------------------------------------------------------------------

  defp extract_error(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> String.slice(msg, 0, 200)
      {:ok, %{"error" => msg}} when is_binary(msg) -> String.slice(msg, 0, 200)
      _ -> "API request failed"
    end
  end

  defp extract_error(%{body: %{"error" => %{"message" => msg}}}), do: String.slice(msg, 0, 200)

  defp extract_error(%{body: %{"error" => msg}}) when is_binary(msg),
    do: String.slice(msg, 0, 200)

  defp extract_error(%{body: _body}), do: "API request failed"
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
        headers: Sanitizer.redact_headers(headers),
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
        headers: Sanitizer.redact_headers(resp_headers(resp)),
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
    Enum.flat_map(headers, fn
      {k, v} when is_list(v) -> Enum.map(v, &{k, &1})
      {k, v} -> [{k, v}]
    end)
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
