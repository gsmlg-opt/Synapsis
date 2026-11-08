defmodule Synapsis.Provider.ComfyWorkflow do
  @moduledoc false

  @max_response_bytes 16 * 1024 * 1024
  @max_image_bytes 64 * 1024 * 1024
  @max_audio_bytes 16 * 1024 * 1024
  @max_timeout 2_147_000_000
  @chunk_timeout 30_000
  @max_seed 281_474_976_710_655
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")
  @extensions %{
    "image/avif" => "avif",
    "image/heic" => "heic",
    "image/heic-sequence" => "heic",
    "image/heif" => "heif",
    "image/heif-sequence" => "heif",
    "image/bmp" => "bmp",
    "image/jpg" => "jpg",
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/svg+xml" => "svg",
    "image/webp" => "webp",
    "image/gif" => "gif",
    "audio/aiff" => "aiff",
    "audio/x-aiff" => "aiff",
    "audio/ogg" => "ogg",
    "audio/mpeg" => "mp3",
    "audio/mp3" => "mp3",
    "audio/wav" => "wav",
    "audio/wave" => "wav",
    "audio/x-wav" => "wav",
    "audio/flac" => "flac",
    "audio/aac" => "aac",
    "audio/amr" => "amr",
    "audio/opus" => "opus",
    "audio/webm" => "webm",
    "audio/x-m4a" => "m4a",
    "audio/m4a" => "m4a",
    "audio/mp4" => "m4a",
    "audio/x-caf" => "caf",
    "video/x-msvideo" => "avi",
    "video/x-m4v" => "m4v",
    "video/mp4" => "mp4",
    "video/x-matroska" => "mkv",
    "video/webm" => "webm",
    "video/x-flv" => "flv",
    "video/x-ms-wmv" => "wmv",
    "video/quicktime" => "mov",
    "application/pdf" => "pdf",
    "application/json" => "json",
    "application/yaml" => "yaml",
    "application/zip" => "zip",
    "application/gzip" => "gz",
    "application/x-tar" => "tar",
    "application/x-7z-compressed" => "7z",
    "application/vnd.rar" => "rar",
    "application/msword" => "doc",
    "application/vnd.ms-excel" => "xls",
    "application/vnd.ms-powerpoint" => "ppt",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" => "pptx",
    "text/csv" => "csv",
    "text/plain" => "txt",
    "text/markdown" => "md",
    "text/html" => "html",
    "text/xml" => "xml",
    "text/css" => "css",
    "application/xml" => "xml"
  }
  @mime_aliases %{
    "image/apng" => "image/png",
    "text/yaml" => "application/yaml",
    "application/x-yaml" => "application/yaml",
    "application/xml" => "text/xml",
    "video/vnd.avi" => "video/x-msvideo",
    "video/matroska" => "video/x-matroska"
  }

  @spec build_request(map(), map(), :image | :music) :: {:ok, map()} | {:error, term()}
  def build_request(request, config, kind)
      when is_map(request) and is_map(config) and kind in [:image, :music] do
    request = normalize_request(request, kind)

    with :ok <- validate_request(request),
         :ok <- validate_config(config, kind),
         {:ok, graph} <-
           bind_input(
             config.workflow,
             optional_string(config.prompt_node_id),
             optional_string(config[:prompt_input_name]) || "text",
             request.prompt
           ),
         {:ok, graph} <- bind_seed(graph, config),
         {:ok, headers} <- configured_headers(config) do
      base_url = config.base_url |> trim() |> String.trim_trailing("/")
      body = %{"prompt" => graph}

      body =
        if config.mode == :cloud,
          do:
            Map.put(body, "extra_data", %{"api_key_comfy_org" => optional_string(config.api_key)}),
          else: body

      {:ok,
       %{
         url: base_url <> if(config.mode == :cloud, do: "/api/prompt", else: "/prompt"),
         base_url: base_url,
         mode: config.mode,
         body: body,
         headers: headers,
         model: optional_string(request.model),
         timeout_ms: timer_ms(request.timeout_ms),
         poll_interval_ms: poll_interval(config[:poll_interval_ms]),
         max_response_bytes: @max_response_bytes,
         input_image: List.first(request[:input_images] || []),
         input_image_node_id: optional_string(config[:input_image_node_id]),
         input_image_input_name: optional_string(config[:input_image_input_name]) || "image",
         output_node_id: optional_string(config[:output_node_id])
       }
       |> Map.put(limit_key(kind), output_limit(config, kind))}
    end
  end

  def build_request(_request, _config, _kind), do: {:error, :invalid_request}

  @spec generate(map(), map(), :image | :music) :: {:ok, map()} | {:error, term()}
  def generate(request, config, kind) do
    with {:ok, built} <- build_request(request, config, kind) do
      deadline = now_ms() + built.timeout_ms
      task = Task.async(fn -> perform(built, deadline, kind) end)

      case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
        {:exit, _reason} -> {:error, :transport}
      end
    end
  end

  defp normalize_request(request, :image), do: request

  defp normalize_request(request, :music) do
    model = request[:model]

    request =
      if is_nil(model) or is_binary(model),
        do: Map.put(request, :model, optional_string(model) || "workflow"),
        else: request

    case request[:input_images] do
      images when is_list(images) ->
        Map.put(
          request,
          :input_images,
          Enum.map(images, fn
            image when is_map(image) ->
              if is_nil(image[:mime_type]),
                do: Map.put(image, :mime_type, "image/png"),
                else: image

            image ->
              image
          end)
        )

      _ ->
        request
    end
  end

  defp limit_key(:image), do: :max_image_bytes
  defp limit_key(:music), do: :max_audio_bytes
  defp requested_limit(config, :image), do: config[:max_image_bytes] || @max_image_bytes
  defp requested_limit(config, :music), do: Map.get(config, :max_audio_bytes, @max_audio_bytes)

  defp output_limit(config, :image),
    do: max(@max_image_bytes, floor(config[:max_image_bytes] || @max_image_bytes))

  defp output_limit(config, :music),
    do: floor(Map.get(config, :max_audio_bytes, @max_audio_bytes))

  defp validate_request(request) do
    inputs = request[:input_images] || []

    cond do
      not text?(request[:prompt]) or is_nil(optional_string(request[:model])) ->
        {:error, :invalid_request}

      not positive_number?(request[:timeout_ms]) ->
        {:error, :invalid_timeout}

      not is_list(inputs) or length(inputs) > 1 or not Enum.all?(inputs, &input_image?/1) ->
        {:error, :invalid_input_images}

      true ->
        :ok
    end
  end

  defp validate_config(config, kind) do
    cond do
      config[:mode] not in [:local, :cloud] ->
        {:error, :invalid_mode}

      is_nil(optional_string(config[:base_url])) ->
        {:error, :invalid_config}

      not is_map(config[:workflow]) or not json_value?(config[:workflow]) ->
        {:error, :invalid_workflow}

      is_nil(optional_string(config[:prompt_node_id])) ->
        {:error, :invalid_config}

      config.mode == :cloud and is_nil(optional_string(config[:api_key])) ->
        {:error, :missing_credentials}

      not positive_number?(requested_limit(config, kind)) ->
        {:error, if(kind == :image, do: :invalid_max_image_bytes, else: :invalid_max_audio_bytes)}

      true ->
        :ok
    end
  end

  defp input_image?(image) when is_map(image),
    do:
      is_binary(image[:data]) and text?(image[:mime_type]) and
        (is_nil(image[:filename]) or text?(image[:filename]))

  defp input_image?(_image), do: false

  defp json_value?(value) when is_map(value),
    do:
      not is_struct(value) and
        Enum.all?(value, fn {key, value} -> text?(key) and json_value?(value) end)

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value), do: is_number(value) or value in [nil, true, false]
  defp text?(value), do: is_binary(value) and String.valid?(value)
  defp positive_number?(value), do: is_number(value) and value > 0
  defp trim(value), do: Regex.replace(@js_trim, value, "")

  defp optional_string(value) when is_binary(value) do
    if String.valid?(value) do
      case trim(value) do
        "" -> nil
        value -> value
      end
    end
  end

  defp optional_string(_value), do: nil
  defp timer_ms(value), do: value |> floor() |> max(1) |> min(@max_timeout)
  defp poll_interval(value) when is_integer(value) and value > 0, do: timer_ms(value)
  defp poll_interval(_value), do: 1_500

  defp bind_input(graph, node_id, input_name, value) do
    node = graph[node_id]

    if is_map(node) and is_map(node["inputs"]) do
      {:ok,
       Map.put(
         graph,
         node_id,
         Map.put(node, "inputs", Map.put(node["inputs"], input_name, value))
       )}
    else
      {:error, :invalid_workflow_binding}
    end
  end

  defp bind_seed(graph, config) do
    case optional_string(config[:seed_node_id]) do
      nil ->
        {:ok, graph}

      node_id ->
        bind_input(
          graph,
          node_id,
          optional_string(config[:seed_input_name]) || "seed",
          random_seed()
        )
    end
  end

  defp random_seed do
    <<seed::unsigned-big-integer-size(48)>> = :crypto.strong_rand_bytes(6)
    if seed == @max_seed, do: random_seed(), else: seed
  end

  defp configured_headers(config) do
    headers = config[:headers] || %{}

    if is_map(headers) and
         Enum.all?(headers, fn {name, value} ->
           text?(name) and Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, trim(name)) and
             text?(value) and not String.contains?(value, ["\r", "\n", <<0>>])
         end) do
      defaults = %{"content-type" => "application/json"}

      defaults =
        if config.mode == :cloud,
          do: Map.put(defaults, "x-api-key", optional_string(config.api_key)),
          else: defaults

      {:ok,
       Enum.reduce(headers, defaults, fn {name, value}, acc ->
         case optional_string(value) do
           nil -> acc
           value -> Map.put(acc, name |> trim() |> String.downcase(:ascii), value)
         end
       end)}
    else
      {:error, :invalid_headers}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(0, deadline - now_ms())

  defp perform(built, deadline, kind) do
    with {:ok, built} <- upload_input(built, deadline),
         {:ok, submitted} <-
           read_json(:post, built.url, built.headers, [body: Jason.encode!(built.body)], deadline),
         prompt_id when is_binary(prompt_id) <- optional_string(field(submitted, "prompt_id")),
         {:ok, history} <- wait_for_history(built, prompt_id, deadline),
         entry when not is_nil(entry) <- extract_history(history, prompt_id),
         {:ok, outputs} <- select_outputs(entry, built.output_node_id, kind),
         {:ok, images} <- download_outputs(outputs, built, prompt_id, deadline, kind) do
      metadata = %{
        prompt_id: prompt_id,
        output_node_ids: outputs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      }

      metadata =
        if kind == :music,
          do: Map.put(metadata, :input_image_count, if(built.input_image, do: 1, else: 0)),
          else: metadata

      result_key = if kind == :music, do: :tracks, else: :images
      {:ok, %{model: built.model, metadata: metadata} |> Map.put(result_key, images)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp upload_input(%{input_image: nil} = built, _deadline), do: {:ok, built}

  defp upload_input(%{input_image_node_id: nil}, _deadline),
    do: {:error, :missing_input_image_binding}

  defp upload_input(built, deadline) do
    image = built.input_image
    filename = optional_string(image[:filename]) || "input." <> extension(image.mime_type)
    mime = blob_mime(image.mime_type)

    form = [
      {"image",
       {image.data,
        filename: filename,
        content_type: if(mime == "", do: "application/octet-stream", else: mime)}},
      {"type", "input"},
      {"overwrite", "true"}
    ]

    with {:ok, uploaded} <-
           read_json(
             :post,
             route(built, "/upload/image"),
             Map.delete(built.headers, "content-type"),
             [form_multipart: form],
             deadline
           ),
         name when is_binary(name) <-
           optional_string(field(uploaded, "filename")) ||
             optional_string(field(uploaded, "name")),
         {:ok, graph} <-
           bind_input(
             built.body["prompt"],
             built.input_image_node_id,
             built.input_image_input_name,
             name
           ) do
      {:ok, %{built | body: Map.put(built.body, "prompt", graph)}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :malformed_response}
    end
  end

  defp extension(mime) do
    normalized = mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()
    Map.get(@extensions, Map.get(@mime_aliases, normalized, normalized), "bin")
  end

  defp blob_mime(mime) do
    if Enum.all?(:binary.bin_to_list(mime), &(&1 >= 0x20 and &1 <= 0x7E)),
      do: String.downcase(mime, :ascii),
      else: ""
  end

  defp route(built, path),
    do: built.base_url <> if(built.mode == :cloud, do: "/api", else: "") <> path

  defp wait_for_history(%{mode: :local} = built, prompt_id, deadline) do
    with {:ok, history} <-
           read_json(:get, route(built, "/history/" <> prompt_id), built.headers, [], deadline) do
      entry = extract_history(history, prompt_id)

      cond do
        field(field(entry, "status"), "status_str") == "error" ->
          {:error, :workflow_failed}

        field(field(entry, "status"), "completed") == true or
            object_nonempty?(field(entry, "outputs")) ->
          {:ok, entry}

        true ->
          poll_again(built, prompt_id, deadline)
      end
    end
  end

  defp wait_for_history(%{mode: :cloud} = built, prompt_id, deadline) do
    with {:ok, status} <-
           read_json(
             :get,
             route(built, "/job/" <> prompt_id <> "/status"),
             built.headers,
             [],
             deadline
           ) do
      case field(status, "status") do
        "completed" ->
          read_json(:get, route(built, "/history_v2/" <> prompt_id), built.headers, [], deadline)

        terminal when terminal in ["failed", "cancelled"] ->
          {:error, :workflow_failed}

        _ ->
          poll_again(built, prompt_id, deadline)
      end
    end
  end

  defp poll_again(built, prompt_id, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      ms ->
        Process.sleep(min(ms, built.poll_interval_ms))
        wait_for_history(built, prompt_id, deadline)
    end
  end

  defp extract_history(history, prompt_id) do
    cond do
      object?(field(history, "outputs")) -> history
      object?(field(history, prompt_id)) -> field(history, prompt_id)
      true -> nil
    end
  end

  defp select_outputs(entry, selected_node, kind) do
    outputs = field(entry, "outputs")

    nodes =
      if selected_node, do: [selected_node], else: Enum.map(js_entries(outputs), &elem(&1, 0))

    files =
      Enum.flat_map(nodes, fn node_id ->
        case field(field(outputs, node_id), if(kind == :music, do: "audio", else: "images")) do
          images when is_list(images) -> Enum.map(images, &{node_id, &1})
          _ -> []
        end
      end)

    if files == [],
      do: {:error, if(kind == :music, do: :missing_audio_outputs, else: :missing_image_outputs)},
      else: {:ok, files}
  end

  defp download_outputs(outputs, built, prompt_id, deadline, kind) do
    Enum.reduce_while(outputs, {:ok, []}, fn {node_id, file}, {:ok, images} ->
      with filename when is_binary(filename) <-
             optional_string(field(file, "filename")) || optional_string(field(file, "name")),
           query = view_query(filename, file),
           {:ok, response} <-
             http(
               :get,
               route(built, "/view") <> "?" <> query,
               built.headers,
               [],
               Map.fetch!(built, limit_key(kind)),
               :binary,
               deadline
             ),
           mime =
             response.headers
             |> Map.get("content-type", [])
             |> Enum.join(", ")
             |> optional_string(),
           :ok <- binary_content(response.body, mime) do
        image = %{
          data: response.body,
          filename: filename,
          mime_type: mime || "application/octet-stream",
          metadata: %{node_id: node_id, prompt_id: prompt_id}
        }

        image = if kind == :music, do: Map.delete(image, :metadata), else: image
        {:cont, {:ok, [image | images]}}
      else
        {:error, _reason} = error -> {:halt, error}
        _ -> {:halt, {:error, :malformed_response}}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Enum.reverse(images)}
      error -> error
    end
  end

  defp view_query(filename, file) do
    [
      {"filename", filename},
      {"subfolder", optional_string(field(file, "subfolder")) || ""},
      {"type", optional_string(field(file, "type")) || "output"}
    ]
    |> Enum.map_join("&", fn {key, value} -> key <> "=" <> form_component(value) end)
  end

  defp form_component(value) do
    value
    |> URI.encode(fn byte ->
      byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?*, ?-, ?., ?_]
    end)
    |> String.replace("%20", "+")
  end

  defp binary_content(<<>>, _mime), do: {:error, :malformed_response}
  defp binary_content(_body, nil), do: :ok

  defp binary_content(_body, mime) do
    normalized = mime |> String.split(";", parts: 2) |> hd() |> trim() |> String.downcase()

    if normalized == "application/json" or String.ends_with?(normalized, "+json") or
         String.starts_with?(normalized, "text/"),
       do: {:error, :malformed_response},
       else: :ok
  end

  defp read_json(method, url, headers, options, deadline) do
    with {:ok, response} <-
           http(method, url, headers, options, @max_response_bytes, :json, deadline) do
      decode_json(response.body)
    end
  end

  defp decode_json(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: parse_json(rest)

  defp decode_json(body), do: parse_json(body)

  defp parse_json(body) do
    if String.valid?(body) do
      case Jason.decode(body, objects: :ordered_objects) do
        {:ok, payload} -> {:ok, payload}
        _ -> {:error, :malformed_response}
      end
    else
      {:error, :malformed_response}
    end
  end

  defp object?(%Jason.OrderedObject{}), do: true
  defp object?(_value), do: false
  defp object_nonempty?(%Jason.OrderedObject{values: values}), do: values != []
  defp object_nonempty?(_value), do: false

  defp field(%Jason.OrderedObject{values: values}, key) do
    case List.keyfind(Enum.reverse(values), key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp field(_value, _key), do: nil

  defp js_entries(%Jason.OrderedObject{values: values} = object) do
    entries =
      values
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {key, _} -> {key, field(object, key)} end)

    {indices, others} =
      Enum.split_with(entries, fn {key, _value} -> not is_nil(js_index(key)) end)

    Enum.sort_by(indices, fn {key, _value} -> js_index(key) end) ++ others
  end

  defp js_entries(_value), do: []

  defp js_index(key) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 and index <= 4_294_967_294 ->
        if Integer.to_string(index) == key, do: index

      _ ->
        nil
    end
  end

  defp http(method, url, headers, options, limit, kind, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        Req.Request.new()
        |> Req.Steps.attach()
        |> Req.merge(
          options ++
            [
              method: method,
              url: url,
              headers: headers,
              raw: true,
              compressed: false,
              into: fn event, pair -> collect(event, pair, limit) end,
              retry: false,
              redirect: false,
              receive_timeout: if(kind == :json, do: min(timeout, @chunk_timeout), else: timeout),
              request_timeout: timeout,
              finch: [pool_timeout: timeout]
            ]
        )
        |> Req.request()
        |> response()
    end
  end

  defp collect({:data, data}, {request, response}, limit) do
    {size, chunks} = Req.Response.get_private(response, :comfy_image_body, {0, []})

    if size + byte_size(data) <= limit do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :comfy_image_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :comfy_image_limit, true)}}
    end
  end

  defp response({:ok, response}) do
    cond do
      Req.Response.get_private(response, :comfy_image_limit, false) ->
        {:error, :response_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} = Req.Response.get_private(response, :comfy_image_body, {0, []})

        {:ok,
         %{body: chunks |> Enum.reverse() |> IO.iodata_to_binary(), headers: response.headers}}
    end
  end

  defp response({:error, _reason}), do: {:error, :transport}
end
