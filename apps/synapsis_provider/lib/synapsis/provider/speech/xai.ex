defmodule Synapsis.Provider.Speech.XAI do
  @moduledoc """
  Explicitly configured buffered xAI speech synthesis.

  Requests use atom keys `:text`, `:target` (`:audio_file`, `:voice_note` or
  `:telephony`), optional `:timeout_ms` and `:provider_overrides`. Config accepts
  `:api_key`, a versioned `:base_url`, `:voice_id`, `:language`, `:speed`,
  `:response_format` and `:max_bytes`. Invocation overrides accept voice, language
  and speed. The service returns opaque audio with file or telephony metadata.

  Call from an execution task. Provider selection, credentials, publication and
  native effect settlement belong to the host; no environment discovery,
  streaming, audio decoding or codec conversion happens here.
  """

  @base_url "https://api.x.ai/v1"
  @request_keys [:text, :target, :timeout_ms, :provider_overrides]
  @config_keys [:api_key, :base_url, :voice_id, :language, :speed, :response_format, :max_bytes]
  @override_keys [:voice_id, :language, :speed]
  @formats ~w(mp3 wav pcm mulaw alaw)
  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024

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
         {:ok, resolved} <- resolve(config, overrides) do
      format =
        case request.target do
          :voice_note -> "mp3"
          :telephony -> "pcm"
          :audio_file -> resolved.format
        end

      body =
        %{
          "text" => request.text,
          "voice_id" => resolved.voice_id,
          "language" => resolved.language,
          "output_format" => %{"codec" => format}
        }
        |> optional("speed", resolved.speed)

      metadata =
        if request.target == :telephony,
          do: %{output_format: format, sample_rate: 24_000},
          else: %{output_format: format, file_extension: "." <> format, voice_compatible: false}

      {:ok,
       Map.merge(metadata, %{
         url: resolved.base_url <> "/tts",
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

  defp resolve(config, overrides) do
    base_url = (trim(config[:base_url]) || @base_url) |> String.trim_trailing("/")

    # Validate source config before applying overrides, as the pinned provider does.
    with true <- is_binary(trim(config[:api_key])),
         {:ok, %URI{scheme: scheme, host: host}}
         when scheme in ["http", "https"] and is_binary(host) <- URI.new(base_url),
         {:ok, config_language} <- language(config[:language]),
         {:ok, format} <- format(config[:response_format]),
         {:ok, override_language} <- language(overrides[:language]) do
      {:ok,
       %{
         base_url: base_url,
         voice_id: trim(overrides[:voice_id]) || trim(config[:voice_id]) || "eve",
         language: override_language || config_language || "en",
         speed: speed(overrides[:speed]) || speed(config[:speed]),
         format: format
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_config}
    end
  end

  defp language(value) do
    case trim(value) do
      nil ->
        {:ok, nil}

      value ->
        value = String.downcase(value)

        if value == "auto" or Regex.match?(~r/^[a-z]{2,3}(?:-[a-z]{2,4})?$/, value),
          do: {:ok, value},
          else: {:error, :invalid_language}
    end
  end

  defp format(value) do
    value = (trim(value) || "mp3") |> String.downcase()
    if value in @formats, do: {:ok, value}, else: {:error, :invalid_format}
  end

  defp speed(value) when is_number(value) and value >= 0.7 and value <= 1.5, do: value
  defp speed(_), do: nil

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
      case String.trim(value) do
        "" -> nil
        value -> value
      end
    end
  end

  defp trim(_), do: nil
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp perform(built, api_key) do
    headers = [{"authorization", "Bearer " <> api_key}, {"content-type", "application/json"}]

    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :post,
      url: built.url,
      headers: headers,
      body: Jason.encode!(built.body),
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built.max_bytes) end,
      retry: false,
      redirect: false,
      receive_timeout: built.timeout_ms,
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
