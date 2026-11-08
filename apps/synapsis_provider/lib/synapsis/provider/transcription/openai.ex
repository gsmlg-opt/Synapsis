defmodule Synapsis.Provider.Transcription.OpenAI do
  @moduledoc """
  Explicit bytes-to-text OpenAI-compatible audio transcription.

  `build_request/2` builds an ordered Req multipart plan. Atom-keyed requests
  contain binary `:audio`, required positive `:timeout_ms`, and optional
  `:filename`, `:mime_type`, `:model`, `:language` and `:prompt`. The pinned
  OpenAI wrapper defaults to `gpt-4o-transcribe`; this does not enable STT or
  select an Agent's provider or model.

  Atom-keyed config supplies `:api_key`, optional versioned API prefix
  `:base_url` (default `https://api.openai.com/v1`) and positive
  `:max_response_bytes` (default 16 MiB of raw JSON). No upload-size cap is
  imposed here. The caller owns attachment admission and audio bytes.

  Call `transcribe/2` from a supervised execution task, never from a session
  or HTTP request process. A linked HTTP task and finite overall deadline own
  pool checkout and response consumption. Chunk idle time is at most 30s.
  There is no retry, provider discovery, configuration lookup, file access,
  storage, tool registration or message mutation.

  Filename, MIME and text normalization follow OpenClaw 488631c: basename and
  AAC upload naming, native Blob's ASCII lowercase type, ECMAScript trimming
  and successful empty silence. Results contain only trimmed `:text` and the
  selected request `:model`. Errors contain tagged reasons, never credentials
  or response bodies. Timeout is bounded by the host timer's 2,147,483,647ms
  limit. This adapter alone does not integrate inbound media into model data.
  """

  @base_url "https://api.openai.com/v1"
  @model "gpt-4o-transcribe"
  @max_response_bytes 16 * 1024 * 1024
  @max_timeout 2_147_483_647
  @chunk_timeout 30_000
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  @type request :: %{
          required(:audio) => binary(),
          required(:timeout_ms) => pos_integer(),
          optional(:filename) => String.t(),
          optional(:mime_type) => String.t(),
          optional(:model) => String.t(),
          optional(:language) => String.t(),
          optional(:prompt) => String.t()
        }

  @spec build_request(request(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config) do
      model = optional_string(request[:model]) || @model
      base_url = optional_string(config[:base_url]) || @base_url
      mime_type = blob_type(request[:mime_type])
      filename = upload_filename(request[:filename], request[:mime_type])
      wire_type = if mime_type == "", do: "application/octet-stream", else: mime_type

      fields =
        [{"model", model}]
        |> optional_field("language", request[:language])
        |> optional_field("prompt", request[:prompt])

      {:ok,
       %{
         url: String.trim_trailing(base_url, "/") <> "/audio/transcriptions",
         model: model,
         timeout_ms: request.timeout_ms,
         max_response_bytes: Map.get(config, :max_response_bytes, @max_response_bytes),
         filename: filename,
         mime_type: mime_type,
         form:
           fields ++
             [{"file", {request.audio, filename: filename, content_type: wire_type}}]
       }}
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec transcribe(request(), map()) ::
          {:ok, %{text: binary(), model: binary()}} | {:error, term()}
  def transcribe(request, config) do
    with {:ok, built} <- build_request(request, config) do
      task = Task.async(fn -> perform(built, config.api_key) end)

      case Task.yield(task, built.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, text}} -> {:ok, %{text: text, model: built.model}}
        {:ok, {:error, reason}} -> {:error, reason}
        nil -> {:error, :timeout}
        {:exit, _reason} -> {:error, :transport}
      end
    end
  end

  defp validate_request(request) do
    cond do
      not is_binary(request[:audio]) ->
        {:error, :invalid_audio}

      not (is_integer(request[:timeout_ms]) and request.timeout_ms > 0 and
               request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      not Enum.all?([:filename, :mime_type, :model, :language, :prompt], fn key ->
        optional_text?(request[key])
      end) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp validate_config(config) do
    limit = Map.get(config, :max_response_bytes, @max_response_bytes)

    cond do
      not is_binary(config[:api_key]) or config[:api_key] == "" ->
        {:error, :missing_credentials}

      not optional_text?(config[:base_url]) ->
        {:error, :invalid_config}

      not (is_integer(limit) and limit > 0) ->
        {:error, :invalid_max_response_bytes}

      true ->
        :ok
    end
  end

  defp optional_text?(nil), do: true
  defp optional_text?(value) when is_binary(value), do: String.valid?(value)
  defp optional_text?(_value), do: false

  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    case trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp optional_field(fields, key, value) do
    case optional_string(value) do
      nil -> fields
      text -> fields ++ [{key, text}]
    end
  end

  defp upload_filename(filename, mime_type) do
    basename =
      case optional_string(filename) do
        nil -> "audio"
        name -> name |> String.split("/", trim: true) |> List.last() || ""
      end

    cond do
      String.ends_with?(String.downcase(basename, :ascii), ".aac") ->
        stem = binary_part(basename, 0, byte_size(basename) - 4)
        if stem == "", do: "audio.m4a", else: stem <> ".m4a"

      extensionless?(basename) and
          String.downcase(optional_string(mime_type) || "", :ascii) == "audio/aac" ->
        if basename == "", do: "audio.m4a", else: basename <> ".m4a"

      true ->
        basename
    end
  end

  defp extensionless?(".."), do: true
  defp extensionless?(basename), do: Path.extname(basename) == ""

  defp blob_type(nil), do: "application/octet-stream"

  defp blob_type(value) do
    if value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E)),
      do: String.downcase(value, :ascii),
      else: ""
  end

  defp perform(built, api_key) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :post,
      url: built.url,
      headers: [{"authorization", "Bearer " <> api_key}],
      form_multipart: built.form,
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built.max_response_bytes) end,
      retry: false,
      redirect: false,
      receive_timeout: min(built.timeout_ms, @chunk_timeout),
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
    {size, chunks} = Req.Response.get_private(response, :transcription_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :transcription_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :transcription_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :transcription_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :transcription_body, {0, []})
        chunks |> Enum.reverse() |> IO.iodata_to_binary() |> decode_text()
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}

  defp decode_text(body) do
    with true <- String.valid?(body),
         {:ok, %{"text" => text}} when is_binary(text) <- Jason.decode(without_bom(body)) do
      {:ok, trim(text)}
    else
      _ -> {:error, :malformed_response}
    end
  end

  defp without_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp without_bom(body), do: body
end
