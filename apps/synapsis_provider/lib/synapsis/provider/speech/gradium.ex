defmodule Synapsis.Provider.Speech.Gradium do
  @moduledoc """
  Explicitly configured, buffered Gradium speech synthesis.

  Atom-key requests contain `:text`, `:target` (`:audio_file`, `:voice_note` or
  `:telephony`), optional `:timeout_ms` and `:provider_overrides`. Config accepts
  `:api_key`, `:base_url`, `:voice_id` and `:max_bytes`; overrides accept voice.
  The host accepts an operator-trusted HTTP(S) API root, including a custom prefix.
  File and note output retain WAV/Opus metadata; telephony returns ulaw_8000/8000.

  Audio remains opaque and bounded, with a default 16 MiB limit. HTTP runs in a
  linked task with finite overall/request deadlines and a 30s idle ceiling through
  shared Req.Finch. Call from an execution task; provider selection, credentials,
  media publication and the native effect lifecycle belong to existing host owners.
  """

  @base_url "https://api.gradium.ai"
  @voice_id "YTpq7expH9539ERJ"
  @voices [
    %{id: "YTpq7expH9539ERJ", name: "Emma"},
    %{id: "LFZvm12tW_z0xfGo", name: "Kent"},
    %{id: "Eu9iL_CYe8N-Gkx_", name: "Tiffany"},
    %{id: "2H4HY2CBNyJHBCrP", name: "Christina"},
    %{id: "jtEKaLYNn6iif5PR", name: "Sydney"},
    %{id: "KWJiFWu2O9nMPYcR", name: "John"},
    %{id: "3jUdJyOi9pgbxBTK", name: "Arthur"}
  ]
  @request_keys [:text, :target, :timeout_ms, :provider_overrides]
  @config_keys [:api_key, :base_url, :voice_id, :max_bytes]
  @override_keys [:voice_id]
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024
  @idle_timeout 30_000
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  @doc "The seven built-in Gradium voices in source catalog order."
  @spec voices() :: [map()]
  def voices, do: @voices

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) do
    with :ok <- options(request, @request_keys, :invalid_request),
         :ok <- options(config, @config_keys, :invalid_config),
         true <- is_binary(request[:text]) and String.valid?(request.text),
         true <- request[:target] in [:audio_file, :voice_note, :telephony],
         {:ok, timeout} <- timeout(request),
         {:ok, limit} <- byte_limit(config),
         overrides = Map.get(request, :provider_overrides, %{}),
         :ok <- options(overrides, @override_keys, :invalid_overrides),
         {:ok, base_url} <- base_url(config) do
      metadata = metadata(request.target)

      body = %{
        "text" => request.text,
        "voice_id" => trim(overrides[:voice_id]) || trim(config[:voice_id]) || @voice_id,
        "only_audio" => true,
        "output_format" => metadata.output_format,
        "json_config" => "{\"padding_bonus\":0}"
      }

      {:ok,
       Map.merge(metadata, %{
         url: base_url <> "/api/post/speech/tts",
         body: body,
         timeout_ms: timeout,
         max_bytes: limit
       })}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  @spec synthesize(map(), map()) :: {:ok, map()} | {:error, term()}
  def synthesize(request, config) do
    with {:ok, built} <- build_request(request, config) do
      task = Task.async(fn -> perform(built, trim(config[:api_key])) end)

      case Task.yield(task, built.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, audio}} ->
          output =
            Map.take(built, [:output_format, :file_extension, :voice_compatible, :sample_rate])

          {:ok, Map.put(output, :audio, audio)}

        {:ok, {:error, reason}} ->
          {:error, reason}

        nil ->
          {:error, :timeout}

        {:exit, _reason} ->
          {:error, :transport}
      end
    end
  end

  defp metadata(:audio_file),
    do: %{output_format: "wav", file_extension: ".wav", voice_compatible: false}

  defp metadata(:voice_note),
    do: %{output_format: "opus", file_extension: ".opus", voice_compatible: true}

  defp metadata(:telephony), do: %{output_format: "ulaw_8000", sample_rate: 8_000}

  defp base_url(config) do
    url = (trim(config[:base_url]) || @base_url) |> String.trim_trailing("/")

    with true <- is_binary(trim(config[:api_key])),
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.new(url) do
      {:ok, url}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp options(value, keys, error) when is_map(value) do
    if Enum.all?(Map.keys(value), &(&1 in keys)), do: :ok, else: {:error, error}
  end

  defp options(_, _, error), do: {:error, error}

  defp timeout(request) do
    case Map.get(request, :timeout_ms, 30_000) do
      value when is_integer(value) and value > 0 and value <= @max_timeout -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end

  defp byte_limit(config) do
    case Map.get(config, :max_bytes, @max_bytes) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, :invalid_max_bytes}
    end
  end

  defp trim(value) when is_binary(value) do
    if String.valid?(value) do
      case Regex.replace(@js_trim, value, "") do
        "" -> nil
        value -> value
      end
    end
  end

  defp trim(_), do: nil

  defp perform(built, api_key) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :post,
      url: built.url,
      headers: [{"x-api-key", api_key}, {"content-type", "application/json"}],
      body: Jason.encode!(built.body),
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built.max_bytes) end,
      retry: false,
      redirect: false,
      receive_timeout: min(built.timeout_ms, @idle_timeout),
      request_timeout: built.timeout_ms,
      finch: [pool_timeout: built.timeout_ms]
    )
    |> Req.request()
    |> response()
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :speech_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :speech_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :speech_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :speech_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :speech_body, {0, []})
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}
end
