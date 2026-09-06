defmodule Synapsis.Provider.Adapter do
  @moduledoc """
  Host-owned HTTP adapter for Anthropic Messages, OpenAI Chat Completions, and
  Google Gemini GenerateContent.

  Request and response wire semantics are delegated to
  `Backplane.AiProtocol.Codec`. This module owns endpoint selection,
  authentication headers, HTTP execution, timeouts, stream codec state, event
  delivery, OAuth retry, and task cancellation. Transport modules provide only
  model discovery and default endpoint metadata.

  Implements the same public interface consumed by `Session.Stream`:
  - `stream/2` - starts async streaming and returns its PID/monitor handle
  - `cancel/1` - cancels an in-progress stream by handle or PID
  - `models/1` - returns available models
  - `format_request/3` - returns a tagged provider wire-map result

  OpenAI Responses is not a supported client protocol here.
  """

  alias Synapsis.Provider.{EventMapper, MessageMapper, ModelRegistry, StreamGuard, ToolName}
  alias Synapsis.Provider.Transport
  alias SynapsisProvider.Sanitizer

  @anthropic_api_version "2023-06-01"
  @stream_timeout_ms 300_000
  @request_timeout_ms 60_000
  @stream_guard_key :synapsis_stream_guard
  @stream_guard_violation_key :synapsis_stream_guard_violation
  @codec_state_key :synapsis_codec_state
  @codec_error_key :synapsis_codec_error

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a streaming request and returns `{:ok, %{pid: pid, ref: monitor_ref}}`.

  Sends `{:provider_chunk, event}` followed by `:provider_done` on successful
  codec completion, or `{:provider_error, reason}` as the terminal signal on
  failure. A provider error is never followed by `:provider_done`.

  `config` must include `:type` (e.g. "anthropic", "openai", "google").
  """
  def stream({:ok, request}, config), do: stream(request, config)
  def stream({:error, error}, _config), do: {:error, error}

  def stream(request, config) do
    with :ok <- ensure_model_runtime_available(request, config) do
      caller = self()
      transport_type = resolve_transport_type(config[:type] || config["type"])
      {request, tool_aliases} = ToolName.pop_aliases(request)

      task =
        Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
          do_stream(transport_type, request, config, caller, tool_aliases)
        end)

      {:ok, %{pid: task.pid, ref: task.ref}}
    end
  end

  @doc "Cancels an in-progress stream using its returned handle or task PID."
  def cancel(%{pid: pid}) when is_pid(pid) do
    Task.Supervisor.terminate_child(Synapsis.Provider.TaskSupervisor, pid)
    :ok
  end

  def cancel(pid) when is_pid(pid) do
    Task.Supervisor.terminate_child(Synapsis.Provider.TaskSupervisor, pid)
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
  Formats messages and tools as a provider wire request.

  Returns `{:ok, wire_map}` or `{:error, %Backplane.AiProtocol.Error{}}`.
  Successful provider wire maps use string keys. Delegates to
  `MessageMapper.build_request/4`.
  """
  def format_request(messages, tools, opts) do
    provider_type = resolve_transport_type(opts[:provider_type] || opts[:type] || "anthropic")
    MessageMapper.build_request(provider_type, messages, tools, opts)
  end

  @doc """
  Synchronous (non-streaming) single-turn call. Returns `{:ok, text}` or
  `{:error, reason}`. Intended for short auditor/analysis calls where
  the full response is needed before continuing.

  `request` may be the tagged result from `format_request/3` or an already
  unwrapped provider wire map. An `{:error, reason}` input is returned without
  making an HTTP request.
  `config` must include `:type` and `:api_key`.
  """
  def complete({:ok, request}, config), do: complete(request, config)
  def complete({:error, error}, _config), do: {:error, error}

  def complete(request, config) do
    with :ok <- ensure_model_runtime_available(request, config) do
      transport_type = resolve_transport_type(config[:type] || config["type"])
      {request, _tool_aliases} = ToolName.pop_aliases(request)

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
  end

  defp ensure_model_runtime_available(request, config) do
    model = Map.get(request, :model, Map.get(request, "model"))
    Synapsis.Providers.ensure_model_runtime_available(config, model)
  end

  # ---------------------------------------------------------------------------
  # Streaming
  # ---------------------------------------------------------------------------

  defp do_stream(:openai = protocol, request, config, caller, tool_aliases) do
    case perform_stream(protocol, request, config, caller, tool_aliases) do
      {:retry_auth, _response} ->
        case maybe_refresh_oauth(config) do
          {:ok, new_config} ->
            perform_stream(
              protocol,
              request,
              Map.merge(config, new_config),
              caller,
              tool_aliases
            )

          _ ->
            send(caller, {:provider_error, "HTTP 401: Authentication failed"})
        end

      result ->
        result
    end
  end

  defp do_stream(protocol, request, config, caller, tool_aliases),
    do: perform_stream(protocol, request, config, caller, tool_aliases)

  defp perform_stream(protocol, request, config, caller, tool_aliases) do
    {url, headers, body} = request_parts(protocol, request, config, true)
    request_id = Ecto.UUID.generate()
    session_id = config[:session_id] || config["session_id"]
    start_time = System.monotonic_time()

    codec_state =
      Backplane.AiProtocol.Codec.stream_new(protocol, codec_opts(protocol, request, config))

    stream_guard = stream_guard_state(config)

    emit_request_telemetry(
      session_id,
      request_id,
      :post,
      url,
      headers,
      body,
      protocol,
      request["model"] || request[:model]
    )

    try do
      response =
        Req.post!(url,
          headers: headers,
          json: body,
          receive_timeout: @stream_timeout_ms,
          compressed: false,
          retry: false,
          redirect: false,
          into: fn {:data, data}, {req, response} ->
            if response.status in 200..299 do
              state = response_codec_state(response, codec_state)
              guard = response_stream_guard(response, stream_guard)

              case Backplane.AiProtocol.Codec.stream_feed(protocol, state, data) do
                {:ok, state, events} ->
                  case emit_mapped_events(events, caller, guard, tool_aliases) do
                    {:ok, guard} ->
                      {:cont, {req, put_stream_response_state(response, state, guard)}}

                    {:violation, guard} ->
                      response =
                        response
                        |> put_stream_response_state(state, guard)
                        |> mark_stream_guard_violation()

                      {:halt, {req, response}}
                  end

                {:error, error, state} ->
                  response =
                    response
                    |> put_stream_response_state(state, guard)
                    |> put_codec_error(error)

                  {:halt, {req, response}}
              end
            else
              {:cont, {req, %{response | body: (response.body || "") <> data}}}
            end
          end
        )

      emit_response_telemetry(session_id, request_id, response, start_time)
      finish_stream_response(protocol, request, config, response, caller, tool_aliases)
    rescue
      error in [Req.TransportError, RuntimeError, Jason.DecodeError] ->
        emit_error_telemetry(session_id, request_id, error, start_time)
        send(caller, {:provider_error, Exception.message(error)})
    end
  end

  defp finish_stream_response(
         :openai,
         request,
         config,
         %{status: 401} = response,
         caller,
         tool_aliases
       ) do
    if config[:oauth] == true or config["oauth"] == true do
      {:retry_auth, response}
    else
      finish_stream_response_body(:openai, request, config, response, caller, tool_aliases)
    end
  end

  defp finish_stream_response(protocol, request, config, response, caller, tool_aliases) do
    finish_stream_response_body(protocol, request, config, response, caller, tool_aliases)
  end

  defp finish_stream_response_body(protocol, request, config, response, caller, tool_aliases) do
    cond do
      stream_guard_violation?(response) ->
        :ok

      error = Map.get(response.private || %{}, @codec_error_key) ->
        send(caller, {:provider_error, error})

      response.status not in 200..299 ->
        {:error, error} =
          Backplane.AiProtocol.Codec.decode_error(
            protocol,
            response.status,
            resp_headers(response),
            response.body,
            codec_opts(protocol, request, config)
          )

        send(caller, {:provider_error, error})

      true ->
        state =
          response_codec_state(
            response,
            Backplane.AiProtocol.Codec.stream_new(
              protocol,
              codec_opts(protocol, request, config)
            )
          )

        case Backplane.AiProtocol.Codec.stream_finish(protocol, state, :eof) do
          {:ok, _state, events} ->
            guard = response_stream_guard(response, stream_guard_state(config))

            case emit_mapped_events(events, caller, guard, tool_aliases) do
              {:ok, guard} ->
                case flush_stream_guard(caller, guard) do
                  {:ok, _guard} -> send(caller, :provider_done)
                  {:violation, _guard} -> :ok
                end

              {:violation, _guard} ->
                :ok
            end

          {:error, error, _state} ->
            send(caller, {:provider_error, error})
        end
    end
  end

  defp emit_mapped_events(events, caller, stream_guard, tool_aliases) do
    Enum.reduce_while(events, {:ok, stream_guard}, fn event, {:ok, stream_guard} ->
      event = EventMapper.map_event(event, tool_aliases)

      case emit_provider_event(caller, event, stream_guard) do
        {:ok, stream_guard} -> {:cont, {:ok, stream_guard}}
        {:violation, stream_guard} -> {:halt, {:violation, stream_guard}}
      end
    end)
  end

  defp emit_provider_event(caller, {:error, error}, stream_guard) do
    send(caller, {:provider_error, error})
    {:violation, stream_guard}
  end

  defp emit_provider_event(caller, event, nil) do
    if event != :ignore, do: send_provider_event(caller, event)
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
          if event != :ignore, do: send_provider_event(caller, event)
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
  defp flush_stream_guard(_caller, nil), do: {:ok, nil}

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

  defp response_codec_state(response, initial_state) do
    Map.get(response.private || %{}, @codec_state_key, initial_state)
  end

  defp put_stream_response_state(response, codec_state, stream_guard) do
    private =
      response.private
      |> Kernel.||(%{})
      |> Map.put(@codec_state_key, codec_state)
      |> Map.put(@stream_guard_key, stream_guard)

    %{response | private: private}
  end

  defp put_codec_error(response, error) do
    private = Map.put(response.private || %{}, @codec_error_key, error)
    %{response | private: private}
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

  # ---------------------------------------------------------------------------
  # Synchronous complete
  # ---------------------------------------------------------------------------

  defp do_complete(:openai = protocol, request, config) do
    case perform_complete(protocol, request, config) do
      {:retry_auth, _response} ->
        case maybe_refresh_oauth(config) do
          {:ok, new_config} -> perform_complete(protocol, request, Map.merge(config, new_config))
          _ -> {:error, "HTTP 401: Authentication failed"}
        end

      result ->
        result
    end
  end

  defp do_complete(protocol, request, config), do: perform_complete(protocol, request, config)

  defp perform_complete(protocol, request, config) do
    {url, headers, body} = request_parts(protocol, request, config, false)

    case Req.post(url, headers: headers, json: body, receive_timeout: @request_timeout_ms) do
      {:ok, %{status: 401} = response} ->
        if protocol == :openai and (config[:oauth] == true or config["oauth"] == true) do
          {:retry_auth, response}
        else
          decode_complete_response(protocol, request, config, response)
        end

      {:ok, response} ->
        decode_complete_response(protocol, request, config, response)

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp decode_complete_response(protocol, request, config, response) do
    case Backplane.AiProtocol.Codec.decode_response(
           protocol,
           response.status,
           resp_headers(response),
           response.body,
           codec_opts(protocol, request, config)
         ) do
      {:ok, canonical_response} -> response_text(canonical_response.output)
      {:error, error} -> {:error, error_message(error)}
    end
  end

  defp response_text(output) do
    text =
      output
      |> Enum.filter(&(&1.type == :text))
      |> Enum.map_join("", & &1.text)

    if text == "", do: {:error, "unexpected response format"}, else: {:ok, text}
  end

  defp request_parts(:anthropic, request, config, stream?) do
    base_url = config[:base_url] || config["base_url"] || Transport.Anthropic.default_base_url()

    headers =
      [{"anthropic-version", @anthropic_api_version}, {"content-type", "application/json"}] ++
        anthropic_auth_headers(config[:api_key] || config["api_key"])

    {"#{base_url}/v1/messages", headers, Map.put(request, "stream", stream?)}
  end

  defp request_parts(:openai, request, config, stream?) do
    base_url = config[:base_url] || config["base_url"] || Transport.OpenAI.default_base_url()
    body = Map.put(request, "stream", stream?)

    if config[:azure] || config["azure"] do
      model = request["model"] || request[:model] || "gpt-4.1"
      api_version = config[:api_version] || config["api_version"] || "2024-02-15-preview"
      url = "#{base_url}/openai/deployments/#{model}/chat/completions?api-version=#{api_version}"

      headers = [
        {"api-key", config[:api_key] || config["api_key"]},
        {"content-type", "application/json"}
      ]

      {url, headers, Map.drop(body, ["model", :model])}
    else
      headers = [{"content-type", "application/json"}] ++ openai_auth_headers(config)
      {openai_chat_completions_url(base_url), headers, body}
    end
  end

  defp request_parts(:google, request, config, stream?) do
    base_url = config[:base_url] || config["base_url"] || Transport.Google.default_base_url()
    model = request["model"] || request[:model] || "gemini-2.5-flash"
    method = if stream?, do: "streamGenerateContent?alt=sse", else: "generateContent"

    headers = [
      {"content-type", "application/json"},
      {"x-goog-api-key", config[:api_key] || config["api_key"]}
    ]

    body = Map.drop(request, ["model", "stream", :model, :stream])
    {"#{base_url}/v1beta/models/#{model}:#{method}", headers, body}
  end

  defp codec_opts(protocol, request, config) do
    base_url =
      config[:base_url] || config["base_url"] ||
        case protocol do
          :anthropic -> Transport.Anthropic.default_base_url()
          :openai -> Transport.OpenAI.default_base_url()
          :google -> Transport.Google.default_base_url()
        end

    [
      profile:
        config[:provider_name] || config["provider_name"] || config[:name] || config["name"] ||
          Atom.to_string(protocol),
      endpoint: base_url,
      account: config[:account] || config["account"],
      workspace: config[:workspace] || config["workspace"],
      model: request["model"] || request[:model]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp error_message(%{message: message, provider_code: code}) do
    message || code || "API request failed"
  end

  defp error_message(error), do: inspect(error)

  defp openai_auth_headers(config) do
    case config[:api_key] || config["api_key"] do
      api_key when is_binary(api_key) and api_key != "" ->
        [{"authorization", "Bearer #{api_key}"}]

      _other ->
        []
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
