defmodule Synapsis.Provider.MusicGeneration.OpenRouter do
  @moduledoc """
  Explicit, inactive OpenRouter streamed music generation protocol.

  Atom-keyed requests contain UTF-8 `:prompt` and required positive finite
  `:timeout_ms` (at most 2,147,483,647). Unlike the source's optional 180s
  timeout, the host requires an explicit whole HTTP budget. Optional inputs
  are `:model`, `:format` (`wav` or `mp3`), `:lyrics`, `:instrumental`,
  `:duration_seconds` and at most one `:input_images` entry with a preferred
  `:url` or already-read binary `:data` and optional `:mime_type`.

  Config supplies `:api_key`, optional versioned `:base_url` (default
  `https://openrouter.ai/api/v1`) and positive `:max_audio_bytes` (16 MiB).
  The cap independently bounds decoded audio and UTF-8 transcript bytes.
  Raw SSE lines are bounded by ceil(cap / 3) * 4 + cap + 64 KiB before JSON
  decoding. Only the first choice's delta.audio is consumed. Base64 slices
  belong to one stream; incomplete quartets survive events. Transcript
  whitespace is preserved. A final `[DONE]`, even without newline, is required.

  Call `generate/2` from an already-supervised execution task. One linked
  HTTP task owns pool checkout and response consumption under the total
  budget; shared Req.Finch has a chunk idle timeout of at most 30 seconds.
  There is no retry, discovery, environment/config lookup, file access,
  persistence, transcoding, job/tool registration or delivery activation.
  Results contain one raw track, requested model, optional lyrics and request
  metadata. Protocol bytes do not establish codec validity or music quality.
  Error and abnormal-owner paths are source-reviewed, not execution-tested.
  """

  @base "https://openrouter.ai/api/v1"
  @model "google/lyria-3-pro-preview"
  @max_timeout 2_147_483_647
  @max_safe_integer 9_007_199_254_740_991
  @default_cap 16 * 1024 * 1024
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request), :ok <- validate_config(config) do
      model = optional_string(request[:model]) || @model
      format = request[:format] || "wav"
      images = request[:input_images] || []
      instrumental = request[:instrumental] == true
      prompt = compose_prompt(request)

      content =
        if images == [],
          do: prompt,
          else: [%{"type" => "text", "text" => prompt}, image_part(hd(images))]

      {:ok,
       %{
         url:
           String.trim_trailing(optional_string(config[:base_url]) || @base, "/") <>
             "/chat/completions",
         model: model,
         format: format,
         input_image_count: length(images),
         instrumental: instrumental,
         timeout_ms: request.timeout_ms,
         max_audio_bytes: Map.get(config, :max_audio_bytes, @default_cap),
         body: %{
           "model" => model,
           "messages" => [%{"role" => "user", "content" => content}],
           "modalities" => ["text", "audio"],
           "audio" => %{"format" => format},
           "stream" => true
         }
       }}
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    with {:ok, built} <- build_request(request, config) do
      task = Task.async(fn -> perform(built, config.api_key) end)

      case Task.yield(task, built.timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _reason} -> {:error, :transport}
      end
    end
  end

  defp validate_request(request) do
    images = request[:input_images] || []

    cond do
      not text?(request[:prompt]) or
          not Enum.all?([:model, :lyrics], &optional_text?(request[&1])) ->
        {:error, :invalid_request}

      not (positive_integer?(request[:timeout_ms]) and request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      request[:format] not in [nil, "wav", "mp3"] ->
        {:error, :invalid_format}

      request[:instrumental] not in [nil, true, false] ->
        {:error, :invalid_request}

      not duration?(request[:duration_seconds]) ->
        {:error, :invalid_duration}

      not is_list(images) or length(images) > 1 or not Enum.all?(images, &image?/1) ->
        {:error, :invalid_images}

      true ->
        :ok
    end
  end

  defp validate_config(config) do
    cond do
      not text?(config[:api_key]) or config.api_key == "" ->
        {:error, :missing_credentials}

      not optional_text?(config[:base_url]) ->
        {:error, :invalid_config}

      not positive_integer?(Map.get(config, :max_audio_bytes, @default_cap)) ->
        {:error, :invalid_max_audio_bytes}

      true ->
        :ok
    end
  end

  defp text?(text), do: is_binary(text) and String.valid?(text)
  defp optional_text?(nil), do: true
  defp optional_text?(text), do: text?(text)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp duration?(nil), do: true
  defp duration?(value), do: is_number(value) and value > 0 and value <= @max_safe_integer
  defp trim(text), do: Regex.replace(@js_trim, text, "")
  defp optional_string(nil), do: nil

  defp optional_string(text) do
    case trim(text) do
      "" -> nil
      value -> value
    end
  end

  defp image?(image) when is_map(image) do
    optional_text?(image[:url]) and optional_text?(image[:mime_type]) and
      (optional_string(image[:url]) != nil or is_binary(image[:data]))
  end

  defp image?(_image), do: false

  defp image_part(image) do
    url =
      optional_string(image[:url]) ||
        "data:#{optional_string(image[:mime_type]) || "image/png"};base64,#{Base.encode64(image.data)}"

    %{"type" => "image_url", "image_url" => %{"url" => url}}
  end

  defp compose_prompt(request) do
    parts = [trim(request.prompt)]

    parts =
      if request[:instrumental] == true,
        do: parts ++ ["Instrumental only. No vocals, no sung lyrics, no spoken word."],
        else: parts

    parts =
      case optional_string(request[:lyrics]) do
        nil -> parts
        lyrics -> parts ++ ["Lyrics:\n" <> lyrics]
      end

    parts =
      case request[:duration_seconds] do
        nil -> parts
        value -> parts ++ ["Target duration: about #{round(value)} seconds."]
      end

    Enum.join(parts, "\n\n")
  end

  defp perform(built, api_key) do
    Req.Request.new()
    |> Req.Steps.attach()
    |> Req.merge(
      method: :post,
      url: built.url,
      headers: [{"authorization", "Bearer " <> api_key}],
      json: built.body,
      raw: true,
      compressed: false,
      into: fn event, pair -> collect(event, pair, built.max_audio_bytes) end,
      retry: false,
      redirect: false,
      receive_timeout: min(built.timeout_ms, 30_000),
      request_timeout: built.timeout_ms,
      finch: [pool_timeout: built.timeout_ms]
    )
    |> Req.request()
    |> response(built)
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp initial_state do
    %{
      fragments: [],
      line_bytes: 0,
      audio: [],
      audio_bytes: 0,
      remainder: "",
      transcript: [],
      transcript_bytes: 0,
      done: false,
      error: nil
    }
  end

  defp collect({:data, data}, {request, response}, cap) do
    if response.status in 200..299 do
      state = Req.Response.get_private(response, :music_stream, initial_state())
      state = consume(data, state, cap)
      response = Req.Response.put_private(response, :music_stream, state)
      {if(state.done or state.error, do: :halt, else: :cont), {request, response}}
    else
      {:halt, {request, response}}
    end
  end

  defp consume(data, state, cap) do
    pieces = :binary.split(data, "\n", [:global])
    line_cap = div(cap + 2, 3) * 4 + cap + 65_536
    sizes = Enum.map(pieces, &byte_size/1)
    [first_size | rest_sizes] = sizes

    # The source checks every raw byte of a network chunk before processing DONE.
    if first_size + state.line_bytes > line_cap or Enum.any?(rest_sizes, &(&1 > line_cap)) do
      %{state | error: :event_too_large}
    else
      consume_lines(pieces, state, cap)
    end
  end

  defp consume_lines([last], state, _cap) do
    %{state | fragments: [last | state.fragments], line_bytes: state.line_bytes + byte_size(last)}
  end

  defp consume_lines([line | rest], state, cap) do
    whole = state.fragments |> Enum.reverse([line]) |> IO.iodata_to_binary()
    next = process_line(whole, %{state | fragments: [], line_bytes: 0}, cap)
    if next.done or next.error, do: next, else: consume_lines(rest, next, cap)
  end

  defp process_line(line, state, cap) do
    if String.valid?(line) do
      case trim(line) do
        "data:" <> data -> process_data(trim(data), state, cap)
        _other -> state
      end
    else
      %{state | error: :malformed_response}
    end
  end

  defp process_data("", state, _cap), do: state

  defp process_data("[DONE]", state, cap) do
    case append_decoded(state.remainder, %{state | remainder: ""}, cap) do
      %{error: nil} = next -> %{next | done: true}
      next -> next
    end
  end

  defp process_data(data, state, cap) do
    case Jason.decode(data) do
      {:ok, %{"error" => error}} when is_map(error) ->
        %{state | error: :provider_stream}

      {:ok, %{"choices" => [%{"delta" => %{"audio" => audio}} | _]}} when is_map(audio) ->
        state |> append_audio(audio["data"], cap) |> append_transcript(audio["transcript"], cap)

      {:ok, _other} ->
        state

      {:error, _reason} ->
        %{state | error: :malformed_response}
    end
  end

  defp append_audio(%{error: error} = state, _data, _cap) when error != nil, do: state

  defp append_audio(state, data, cap) when is_binary(data) do
    combined = state.remainder <> (optional_string(data) || "")
    length = byte_size(combined) - rem(byte_size(combined), 4)
    <<complete::binary-size(length), remainder::binary>> = combined
    append_decoded(complete, %{state | remainder: remainder}, cap)
  end

  defp append_audio(state, _data, _cap), do: state

  defp append_decoded("", state, _cap), do: state

  defp append_decoded(data, state, cap) do
    cleaned = Regex.replace(~r/[\x00-\x20]/, data, "")
    padding = rem(4 - rem(byte_size(cleaned), 4), 4)
    canonical = cleaned <> String.duplicate("=", padding)
    suffix_padding = byte_size(canonical) - byte_size(String.trim_trailing(canonical, "="))
    estimated_bytes = max(0, div(byte_size(canonical) * 3, 4) - suffix_padding)

    cond do
      cleaned == "" -> %{state | error: :malformed_audio}
      estimated_bytes > cap - state.audio_bytes -> %{state | error: :audio_too_large}
      true -> decode_audio(canonical, state, cap)
    end
  end

  defp decode_audio(canonical, state, cap) do
    case Base.decode64(canonical) do
      {:ok, bytes} ->
        cond do
          Base.encode64(bytes) != canonical ->
            %{state | error: :malformed_audio}

          state.audio_bytes + byte_size(bytes) > cap ->
            %{state | error: :audio_too_large}

          true ->
            %{
              state
              | audio: [bytes | state.audio],
                audio_bytes: state.audio_bytes + byte_size(bytes)
            }
        end

      :error ->
        %{state | error: :malformed_audio}
    end
  end

  defp append_transcript(%{error: error} = state, _text, _cap) when error != nil, do: state
  defp append_transcript(state, "", _cap), do: state

  defp append_transcript(state, text, cap) when is_binary(text) do
    if state.transcript_bytes + byte_size(text) <= cap,
      do: %{
        state
        | transcript: [text | state.transcript],
          transcript_bytes: state.transcript_bytes + byte_size(text)
      },
      else: %{state | error: :transcript_too_large}
  end

  defp append_transcript(state, _text, _cap), do: state

  defp response({:ok, response}, built) do
    state = Req.Response.get_private(response, :music_stream, initial_state())

    state =
      if state.done or state.error,
        do: state,
        else:
          process_line(
            state.fragments |> Enum.reverse() |> IO.iodata_to_binary(),
            state,
            built.max_audio_bytes
          )

    cond do
      response.status not in 200..299 -> {:error, {:http_status, response.status}}
      state.error != nil -> {:error, state.error}
      not state.done -> {:error, :incomplete_stream}
      state.audio_bytes == 0 -> {:error, :missing_audio}
      true -> {:ok, result(state, built)}
    end
  end

  defp response({:error, _reason}, _built), do: {:error, :transport}

  defp result(state, built) do
    result = %{
      tracks: [
        %{
          data: state.audio |> Enum.reverse() |> IO.iodata_to_binary(),
          mime_type: if(built.format == "mp3", do: "audio/mpeg", else: "audio/wav"),
          filename: "track-1.#{built.format}"
        }
      ],
      model: built.model,
      metadata: %{
        input_image_count: built.input_image_count,
        instrumental: built.instrumental,
        requested_format: built.format
      }
    }

    lyrics = state.transcript |> Enum.reverse() |> IO.iodata_to_binary()
    if lyrics == "", do: result, else: Map.put(result, :lyrics, [lyrics])
  end
end
