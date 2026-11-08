defmodule Synapsis.Provider.VideoGeneration.XAI do
  @moduledoc """
  Inactive, explicit xAI video generation, editing and extension protocol.

  Atom-keyed requests supply an exact UTF-8 `:prompt` and a positive integer
  `:timeout_ms` (at most 2_147_483_647). The required total budget is a host
  adaptation: it covers submission, every status read, polling waits and the
  final download without resetting. `:model` defaults to `grok-imagine-video`;
  explicit trimmed model identifiers, including 1.5 aliases, are preserved.
  Optional inputs are `:duration_seconds`, `:aspect_ratio`, `:resolution`,
  `:input_images` and `:input_videos`. Images contain a preferred explicit `:url`
  or already-read binary `:data`, optional `:mime_type` (default `image/png`),
  and optional `:role` (`first_frame` or `reference_image`). Video inputs require
  a remote `:url`. No files are read. Other provider options are not forwarded.

  Config supplies `:api_key`, optional versioned `:base_url` (default
  `https://api.x.ai/v1`), `:max_video_bytes` (default 16 MiB) and
  `:max_response_bytes` (default 1 MiB). The latter is an explicit host control
  JSON cap, not a source provider limit. Both caps apply to actual raw chunks
  before decoding. Outputs contain one raw `:data` asset with `:mime_type` and
  `:filename`, the selected model and atom-keyed request/status/URL/mode metadata.

  Call `generate/2` from an already-supervised execution task. One linked task
  owns all HTTP operations and waits; shared Req.Finch uses per-request remaining
  budgets and chunk idle timeouts of at most 30 seconds. Source polling reads
  immediately, waits 5 seconds after each nonterminal result, and allows at most
  120 reads. Only case-insensitive `done` followed by downloaded bytes completes
  generation. A fresh UUID idempotency key is sent on the one submit POST only.
  Downloads use a clean request without provider headers. No requests retry
  automatically; source GET retry and full failure parity are not claimed.

  Abnormal caller exit propagates through the link to the local HTTP owner;
  normal caller exit does not guarantee cleanup. This ownership is source-reviewed,
  not runtime-tested. The source offers no remote cancellation, so local cleanup
  does not guarantee remote job cancellation.
  There is no provider discovery, global configuration, environment lookup,
  registration, persistence, media transcoding or native delivery activation.
  """

  @default_model "grok-imagine-video"
  @default_base "https://api.x.ai/v1"
  @max_timeout 2_147_483_647
  @max_safe_integer 9_007_199_254_740_991
  @chunk_timeout 30_000
  @poll_interval 5_000
  @poll_attempts 120
  @aspect_ratios ~w(1:1 16:9 9:16 4:3 3:4 3:2 2:3)
  @models_15 ~w(grok-imagine-video-1.5 grok-imagine-video-1.5-preview grok-imagine-video-1.5-2026-05-30)
  @failure_statuses ~w(failed error expired cancelled)
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @video_extensions %{
    "video/x-msvideo" => "avi",
    "video/vnd.avi" => "avi",
    "video/x-m4v" => "m4v",
    "video/mp4" => "mp4",
    "video/x-matroska" => "mkv",
    "video/matroska" => "mkv",
    "video/webm" => "webm",
    "video/x-flv" => "flv",
    "video/x-ms-wmv" => "wmv",
    "video/quicktime" => "mov"
  }

  @spec build_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_request(request, config) when is_map(request) and is_map(config) do
    with :ok <- validate_request(request),
         :ok <- validate_config(config),
         {:ok, duration} <- duration(request[:duration_seconds]),
         model = optional_string(request[:model]) || @default_model,
         {:ok, body, mode, endpoint} <- prepare(request, model, duration) do
      base = config |> Map.get(:base_url, @default_base) |> trim() |> String.trim_trailing("/")

      {:ok,
       %{
         url: base <> endpoint,
         model: model,
         mode: mode,
         timeout_ms: request.timeout_ms,
         max_video_bytes: Map.get(config, :max_video_bytes, 16 * 1024 * 1024),
         max_response_bytes: Map.get(config, :max_response_bytes, 1024 * 1024),
         body: body
       }}
    end
  end

  def build_request(_request, _config), do: {:error, :invalid_request}

  @spec generate(map(), map()) :: {:ok, map()} | {:error, term()}
  def generate(request, config) do
    with {:ok, built} <- build_request(request, config) do
      deadline = now_ms() + built.timeout_ms
      task = Task.async(fn -> perform(built, config.api_key, deadline) end)

      case Task.yield(task, max(0, deadline - now_ms())) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _reason} -> {:error, :transport}
      end
    end
  end

  defp validate_request(request) do
    images = request[:input_images] || []
    videos = request[:input_videos] || []

    cond do
      not text?(request[:prompt]) or not optional_text?(request[:model]) ->
        {:error, :invalid_request}

      not (positive_integer?(request[:timeout_ms]) and request.timeout_ms <= @max_timeout) ->
        {:error, :invalid_timeout}

      not is_list(images) or not Enum.all?(images, &image?/1) ->
        {:error, :invalid_images}

      not is_list(videos) or not Enum.all?(videos, &video?/1) ->
        {:error, :invalid_videos}

      length(videos) > 1 or (videos != [] and images != []) ->
        {:error, :unsupported_inputs}

      true ->
        :ok
    end
  end

  defp validate_config(config) do
    cond do
      not text?(config[:api_key]) or optional_string(config[:api_key]) == nil ->
        {:error, :missing_credentials}

      not text?(Map.get(config, :base_url, @default_base)) or
          optional_string(Map.get(config, :base_url, @default_base)) == nil ->
        {:error, :invalid_config}

      not positive_integer?(Map.get(config, :max_video_bytes, 16 * 1024 * 1024)) ->
        {:error, :invalid_max_video_bytes}

      not positive_integer?(Map.get(config, :max_response_bytes, 1024 * 1024)) ->
        {:error, :invalid_max_response_bytes}

      true ->
        :ok
    end
  end

  defp prepare(request, model, duration) do
    images = request[:input_images] || []
    videos = request[:input_videos] || []
    references = Enum.any?(images, &reference?/1)
    body = %{"model" => model, "prompt" => request.prompt}

    cond do
      model in @models_15 and
          (videos != [] or length(images) != 1 or role(hd(images)) not in [nil, "first_frame"]) ->
        {:error, :unsupported_model_inputs}

      references and (length(images) > 7 or not Enum.all?(images, &reference?/1)) ->
        {:error, :unsupported_reference_images}

      not references and length(images) > 1 ->
        {:error, :unsupported_images}

      videos != [] ->
        body = Map.put(body, "video", %{"url" => optional_string(hd(videos)[:url])})

        if duration == nil do
          {:ok, body, "edit", "/videos/edits"}
        else
          {:ok, Map.put(body, "duration", clamp(duration, 2, 10)), "extend", "/videos/extensions"}
        end

      true ->
        image_url = if not references and images != [], do: image_url(hd(images)), else: nil

        body =
          cond do
            references ->
              Map.put(body, "reference_images", Enum.map(images, &%{"url" => image_url(&1)}))

            image_url ->
              Map.put(body, "image", %{"url" => image_url})

            true ->
              body
          end

        ratio = optional_string(request[:aspect_ratio])
        ratio = if ratio in @aspect_ratios, do: ratio, else: nil

        body =
          if ratio || image_url == nil,
            do: Map.put(body, "aspect_ratio", ratio || "16:9"),
            else: body

        body =
          body
          |> Map.put(
            "duration",
            if(duration, do: clamp(duration, 1, if(references, do: 10, else: 15)), else: 8)
          )
          |> Map.put(
            "resolution",
            resolution(request[:resolution], not references and model in @models_15)
          )

        {:ok, body, if(references, do: "referenceToVideo", else: "generate"),
         "/videos/generations"}
    end
  end

  defp duration(nil), do: {:ok, nil}

  defp duration(value) when is_number(value) and value > 0 and value <= @max_safe_integer do
    rounded = round(value)
    if rounded > 0, do: {:ok, rounded}, else: {:error, :invalid_duration}
  end

  defp duration(_value), do: {:error, :invalid_duration}
  defp clamp(value, minimum, maximum), do: max(minimum, min(maximum, value))

  defp resolution(value, allow_1080) do
    case value |> optional_string() |> lowercase() do
      "480p" -> "480p"
      "720p" -> "720p"
      "1080p" when allow_1080 -> "1080p"
      "1080p" -> "720p"
      _ -> "480p"
    end
  end

  defp image?(image) when is_map(image) do
    (optional_string(image[:url]) != nil or is_binary(image[:data])) and
      optional_text?(image[:mime_type]) and optional_text?(image[:role])
  end

  defp image?(_image), do: false
  defp video?(video) when is_map(video), do: optional_string(video[:url]) != nil
  defp video?(_video), do: false
  defp role(image), do: image[:role] |> optional_string() |> lowercase()
  defp reference?(image), do: role(image) == "reference_image"

  defp image_url(image) do
    optional_string(image[:url]) ||
      "data:#{optional_string(image[:mime_type]) || "image/png"};base64,#{Base.encode64(image.data)}"
  end

  defp perform(built, api_key, deadline) do
    headers = [{"authorization", "Bearer " <> api_key}]
    submit_headers = [{"x-idempotency-key", Ecto.UUID.generate()} | headers]

    with {:ok, response} <-
           http(
             :post,
             built.url,
             [headers: submit_headers, json: built.body],
             built.max_response_bytes,
             deadline
           ),
         {:ok, submitted} <- decode_payload(response.body),
         {:ok, request_id} <- request_id(submitted),
         base = String.replace_suffix(built.url, endpoint(built.mode), ""),
         {:ok, completed} <-
           poll(
             base <> "/videos/" <> request_id,
             headers,
             built.max_response_bytes,
             deadline,
             @poll_attempts
           ),
         video_url when is_binary(video_url) <-
           optional_string(get_in(completed, ["video", "url"])),
         {:ok, video} <- http(:get, video_url, [], built.max_video_bytes, deadline) do
      mime =
        optional_string(List.first(Map.get(video.headers, "content-type", []))) || "video/mp4"

      extension = mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
      extension = Map.get(@video_extensions, extension, "mp4")

      {:ok,
       %{
         videos: [%{data: video.body, mime_type: mime, filename: "video-1." <> extension}],
         model: built.model,
         metadata: %{
           request_id: request_id,
           status: optional_string(completed["status"]),
           video_url: video_url,
           mode: built.mode
         }
       }}
    else
      nil -> {:error, :malformed_response}
      {:error, _reason} = error -> error
    end
  rescue
    _exception -> {:error, :transport}
  catch
    :exit, _reason -> {:error, :transport}
  end

  defp endpoint("edit"), do: "/videos/edits"
  defp endpoint("extend"), do: "/videos/extensions"
  defp endpoint(_mode), do: "/videos/generations"

  defp request_id(payload) do
    case optional_string(payload["request_id"]) do
      nil -> {:error, :malformed_response}
      id -> {:ok, id}
    end
  end

  defp poll(_url, _headers, _limit, _deadline, 0), do: {:error, :timeout}

  defp poll(url, headers, limit, deadline, attempts) do
    with {:ok, response} <- http(:get, url, [headers: headers], limit, deadline),
         {:ok, payload} <- decode_payload(response.body),
         :ok <- validate_status(payload) do
      status = payload["status"] |> optional_string() |> lowercase()

      cond do
        status == "done" ->
          {:ok, payload}

        status in @failure_statuses ->
          {:error, {:provider_status, status}}

        true ->
          with :ok <- wait(deadline) do
            poll(url, headers, limit, deadline, attempts - 1)
          end
      end
    end
  end

  defp validate_status(payload) do
    if (payload["video"] == nil or is_map(payload["video"])) and
         (payload["error"] == nil or is_map(payload["error"])) do
      :ok
    else
      {:error, :malformed_response}
    end
  end

  defp wait(deadline) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {:error, :timeout}
    else
      Process.sleep(min(@poll_interval, remaining))
      if now_ms() < deadline, do: :ok, else: {:error, :timeout}
    end
  end

  defp http(method, url, options, limit, deadline) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {:error, :timeout}
    else
      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        options ++
          [
            method: method,
            url: url,
            raw: true,
            compressed: false,
            into: fn event, pair -> collect(event, pair, limit) end,
            retry: false,
            redirect: false,
            receive_timeout: min(remaining, @chunk_timeout),
            request_timeout: remaining,
            finch: [pool_timeout: remaining]
          ]
      )
      |> Req.request()
      |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :video_generation_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :video_generation_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :video_generation_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :video_generation_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :video_generation_body, {0, []})

        {:ok,
         %{body: chunks |> Enum.reverse() |> IO.iodata_to_binary(), headers: response.headers}}
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}

  defp decode_payload(body) do
    body =
      case body do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        other -> other
      end

    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_response}
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp optional_text?(nil), do: true
  defp optional_text?(value), do: text?(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp lowercase(nil), do: nil
  defp lowercase(value), do: String.downcase(value)
  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(value) when is_binary(value) do
    if String.valid?(value) do
      case trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    end
  end

  defp optional_string(_value), do: nil
  defp now_ms, do: System.monotonic_time(:millisecond)
end
