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

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: request,
          receive_timeout: 300_000,
          into: fn {:data, data}, {req, resp} ->
            for chunk <- Transport.SSE.parse_lines(data) do
              event = EventMapper.map_event(:anthropic, chunk)
              send(caller, {:provider_chunk, event})
            end

            {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
          end
        )

      handle_stream_response(resp, caller)
    rescue
      e ->
        send(caller, {:provider_error, Exception.message(e)})
    end
  end

  defp do_stream(:openai, request, config, caller) do
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

    try do
      resp =
        Req.post!(url,
          headers: headers,
          json: body,
          receive_timeout: 300_000,
          into: fn {:data, data}, {req, resp} ->
            for chunk <- Transport.SSE.parse_lines(data) do
              event = EventMapper.map_event(:openai, chunk)
              send(caller, {:provider_chunk, event})
            end

            {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
          end
        )

      handle_stream_response(resp, caller)
    rescue
      e ->
        send(caller, {:provider_error, Exception.message(e)})
    end
  end

  defp do_stream(:google, request, config, caller) do
    base_url = config[:base_url] || Transport.Google.default_base_url()
    model = request[:model] || "gemini-2.5-flash"

    url = "#{base_url}/v1beta/models/#{model}:streamGenerateContent?alt=sse"

    body = Map.drop(request, [:model, :stream])

    try do
      resp =
        Req.post!(url,
          headers: [{"content-type", "application/json"}, {"x-goog-api-key", config[:api_key]}],
          json: body,
          receive_timeout: 300_000,
          into: fn {:data, data}, {req, resp} ->
            for chunk <- Transport.SSE.parse_lines(data) do
              event = EventMapper.map_event(:google, chunk)
              send(caller, {:provider_chunk, event})
            end

            {:cont, {req, %{resp | body: (resp.body || "") <> data}}}
          end
        )

      handle_stream_response(resp, caller)
    rescue
      e ->
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
    base_url = config[:base_url] || Transport.OpenAI.default_base_url()
    url = "#{base_url}/v1/chat/completions"

    body = Map.merge(request, %{stream: false})

    headers =
      [{"content-type", "application/json"}] ++
        if(config[:api_key], do: [{"authorization", "Bearer #{config[:api_key]}"}], else: [])

    response = Req.post!(url, headers: headers, json: body, receive_timeout: 60_000)

    case response.body do
      %{"choices" => [%{"message" => %{"content" => text}} | _]} ->
        {:ok, text}

      %{"error" => %{"message" => msg}} ->
        {:error, msg}

      other ->
        {:error, "unexpected response: #{inspect(other)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
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
