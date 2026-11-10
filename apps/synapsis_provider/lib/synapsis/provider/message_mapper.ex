defmodule Synapsis.Provider.MessageMapper do
  @moduledoc """
  Converts Synapsis domain messages into canonical Backplane requests and
  delegates provider wire encoding to `Backplane.AiProtocol.Codec`.
  """

  alias Backplane.AiProtocol.{Codec, ContentBlock, Error, Request, Validation}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Provider.Transport

  @limits %{
    max_bytes: 32 * 1024 * 1024,
    max_string_bytes: 32 * 1024 * 1024,
    max_depth: 64
  }

  @skill_projection_names ~w(synapsis::skills_search synapsis::skills_read synapsis::skill synapsis::skill_workshop)
  @code_projection_names ~w(exec wait)
  @v2_projection_names @skill_projection_names ++ @code_projection_names ++ ["synapsis::read"]

  @spec build_request(atom(), list(), list(), map()) :: {:ok, map()} | {:error, Error.t()}
  def build_request(protocol, messages, tools, opts) do
    model =
      option(opts, :model) ||
        Synapsis.Providers.default_model(option(opts, :provider_name) || Atom.to_string(protocol))

    with {:ok, input} <- canonical_messages(messages),
         {:ok, input} <- project_history(input, protocol, model, opts),
         {:ok, request} <-
           Request.new(
             %{
               model: model,
               input: system_message(opts) ++ protocol_tool_results(input, protocol),
               tools: Enum.map(tools, &canonical_tool(&1, protocol)),
               settings: settings(protocol, opts),
               extensions: extensions(protocol, opts)
             },
             limits: @limits
           ),
         {:ok, wire_request} <-
           Codec.encode_request(protocol, request, codec_opts(protocol, model, opts)) do
      {:ok, ToolName.put_aliases(wire_request, Enum.map(tools, & &1.name))}
    end
  end

  defp project_history(input, protocol, model, opts) do
    if option(opts, :history_projection) == :portable do
      Synapsis.Provider.RequestHistory.project(input, protocol, codec_opts(protocol, model, opts))
    else
      {:ok, input}
    end
  end

  # Responses `function_call_output` has no error flag, so failed tool results
  # are sent as plain output (as Codex does); the error text stays in content.
  defp protocol_tool_results(input, :openai_responses) do
    Enum.map(input, fn
      %{role: :tool, content: content} = message ->
        %{message | content: Enum.map(content, &responses_tool_image/1)}
        |> Map.put(:status, :success)

      message ->
        message
    end)
  end

  defp protocol_tool_results(input, _protocol), do: input

  # Adapt validated tool projections to the Responses native image contract.
  # Other protocols and user attachments retain their existing representation.
  defp responses_tool_image(
         %{
           type: :image,
           data: %{"source" => "base64", "media_type" => mime, "data" => data}
         } = block
       ),
       do: %{block | data: %{"mime_type" => mime, "data" => data}}

  defp responses_tool_image(block), do: block

  defp canonical_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case canonical_message(message) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp canonical_message(message) do
    role = message |> field(:role) |> normalize_role()
    parts = field(message, :parts) || []
    {results, content_parts} = Enum.split_with(parts, &match?(%Synapsis.Part.ToolResult{}, &1))

    with {:ok, content} <- canonical_parts(content_parts),
         {:ok, tool_results} <- canonical_tool_results(results) do
      messages = if content == [], do: [], else: [%{role: role, content: content}]
      {:ok, messages ++ tool_results}
    end
  end

  defp canonical_tool_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case canonical_tool_result(result) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp canonical_tool_result(%Synapsis.Part.ToolResult{projection: nil} = result) do
    {:ok,
     %{
       role: :tool,
       tool_call_id: result.tool_use_id,
       status: if(result.is_error, do: :error, else: :success),
       content: [%{type: :text, text: result.content}]
     }}
  end

  defp canonical_tool_result(result) do
    with {:ok, public} <- projected_result(result),
         {:ok, content} <- projected_content(public["content"]) do
      {:ok,
       %{
         role: :tool,
         tool_call_id: result.tool_use_id,
         status: if(result.is_error, do: :error, else: :success),
         content: content
       }}
    end
  end

  # Validate the whole public projection with native budgets. Sidecars such as
  # structured data, artifacts and metadata are retained-only: none are sent to
  # the model. Only the finite content shapes below become protocol blocks.
  # V2 is a display contract, not execution provenance. Validate its exact
  # known-name envelope with the same finite budgets as the host Part reader.
  defp projected_result(%{
         projection: %{"version" => 2, "tool_name" => name, "result" => result} = projection,
         is_error: is_error
       })
       when map_size(projection) == 3 and
              name in @v2_projection_names do
    limits =
      cond do
        name in @skill_projection_names ->
          %{max_bytes: 32 * 1_024 * 1_024, max_string_bytes: 4 * 1_024 * 1_024}

        name in @code_projection_names ->
          %{max_bytes: 8 * 1_024 * 1_024, max_string_bytes: 1_024 * 1_024}

        name == "synapsis::read" ->
          %{max_bytes: 11_010_048, max_string_bytes: 5_767_168}
      end

    with true <- is_map(result) and not is_struct(result),
         true <- is_boolean(is_error) and result["is_error"] === is_error,
         false <- Map.has_key?(result, :is_error) or Map.has_key?(result, :content),
         true <- name != "synapsis::read" or filesystem_image?(result),
         :ok <- Validation.term(projection, limits) do
      {:ok, result}
    else
      _ -> invalid_projection()
    end
  end

  defp projected_result(%{projection: projection, is_error: is_error}) do
    with %{"version" => 1, "result" => result} when map_size(projection) == 2 <- projection,
         true <- is_map(result) and not is_struct(result),
         true <- is_boolean(is_error) and result["is_error"] === is_error,
         false <- Map.has_key?(result, :is_error) or Map.has_key?(result, :content),
         :ok <- Validation.term(projection) do
      {:ok, result}
    else
      _ -> invalid_projection()
    end
  rescue
    _ -> invalid_projection()
  end

  # Match the same display-only source image shape as ResultProjection. Only
  # content reaches the provider; details retain the matching text and MIME.
  defp filesystem_image?(
         %{"is_error" => false, "content" => [text, image], "details" => details} = result
       )
       when map_size(result) == 3 do
    with %{"type" => "text", "text" => summary}
         when map_size(text) == 2 and is_binary(summary) and summary != "" <- text,
         %{"type" => "image", "data" => data, "mimeType" => mime}
         when map_size(image) == 3 and is_binary(data) and data != "" and
                mime in ~w(image/png image/jpeg image/gif image/webp) <- image,
         %{"kind" => "image", "content" => ^summary, "mimeType" => ^mime}
         when map_size(details) == 3 <- details do
      true
    else
      _ -> false
    end
  end

  defp filesystem_image?(_), do: false

  defp projected_content(text) when is_binary(text) and text != "",
    do: {:ok, [%{type: :text, text: text}]}

  defp projected_content([_ | _] = blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn block, {:ok, acc} ->
      case projected_block(block) do
        {:ok, content} -> {:cont, {:ok, [content | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, content} -> {:ok, Enum.reverse(content)}
      error -> error
    end
  end

  defp projected_content(_), do: unsupported_projection()

  defp projected_block(%{"type" => "text", "text" => text} = block)
       when is_binary(text) and text != "" do
    with :ok <- projected_metadata(block, ~w(type text)),
         do: {:ok, %{type: :text, text: text}}
  end

  defp projected_block(
         %{
           "type" => "image",
           "data" => %{"source" => "base64", "media_type" => media_type, "data" => data} = image
         } = block
       )
       when map_size(image) == 3 and
              is_binary(media_type) and media_type != "" and is_binary(data) and data != "",
       do: canonical_image(block, image, ~w(type data))

  defp projected_block(%{"type" => "image", "data" => data, "mimeType" => mime} = block)
       when is_binary(data) and data != "" and is_binary(mime) and mime != "" do
    image = %{"source" => "base64", "media_type" => mime, "data" => data}
    canonical_image(block, image, ~w(type data mimeType))
  end

  defp projected_block(%{"type" => type}) when type in ["text", "image"],
    do: invalid_projection()

  # TODO(upstream): gsmlg-opt/backplane#108 — canonical media is retained;
  # lossless provider encoding of these types in tool results is still pending.
  defp projected_block(%{"type" => type, "data" => data} = block)
       when type in ["audio", "resource", "resource_link"] and is_map(data) do
    with :ok <- projected_metadata(block, ~w(type data extensions)),
         {:ok, extensions} <- media_extensions(block) do
      block
      |> Map.drop(~w(annotations _meta))
      |> Map.put("extensions", extensions)
      |> ContentBlock.new(limits: @limits)
    end
  end

  defp projected_block(%{"type" => "audio", "mimeType" => mime, "data" => data} = block) do
    with :ok <- projected_metadata(block, ~w(type mimeType data)) do
      native_media(:audio, %{"mime_type" => mime, "data" => data}, block)
    end
  end

  defp projected_block(%{"type" => "resource", "resource" => resource} = block)
       when is_map(resource) do
    with :ok <- projected_metadata(block, ~w(type resource)),
         :ok <- projected_metadata(resource, ~w(uri mimeType text blob)),
         :ok <- resource_mime(resource) do
      data =
        resource
        |> Map.drop(~w(annotations _meta))
        |> Map.new(fn
          {"mimeType", value} -> {"mime_type", value}
          {"blob", value} -> {"data", value}
          entry -> entry
        end)

      metadata = Map.take(resource, ~w(annotations _meta))

      extensions =
        if metadata == %{}, do: %{}, else: %{"mcp::resource_metadata" => metadata}

      native_media(:resource, data, block, extensions)
    end
  end

  defp projected_block(%{"type" => "resource_link"} = block) do
    with :ok <- projected_metadata(block, ~w(type uri name mimeType title description size)) do
      data =
        block
        |> Map.drop(~w(type annotations _meta))
        |> Map.new(fn
          {"mimeType", value} -> {"mime_type", value}
          entry -> entry
        end)

      native_media(:resource_link, data, block)
    end
  end

  defp projected_block(%{"type" => type}) when is_binary(type),
    do: unsupported_projection()

  defp projected_block(_), do: invalid_projection()

  defp canonical_image(block, image, keys) do
    with :ok <- projected_metadata(block, keys), do: {:ok, %{type: :image, data: image}}
  end

  defp resource_mime(%{"mimeType" => _mime}), do: :ok

  defp resource_mime(_resource),
    do: Error.incompatible("Projected resource requires an explicit MIME type")

  defp native_media(type, data, block, extensions \\ %{}) do
    with {:ok, metadata} <- media_extensions(block) do
      ContentBlock.new(
        %{type: type, data: data, extensions: Map.merge(metadata, extensions)},
        limits: @limits
      )
    end
  end

  # New primary media kinds preserve MCP presentation metadata in native
  # namespaced extensions. The codecs decide whether that metadata is encodable.
  defp media_extensions(block) do
    metadata =
      block
      |> Map.take(~w(annotations _meta))
      |> Map.new(fn
        {"annotations", value} -> {"mcp::annotations", value}
        {"_meta", value} -> {"mcp::meta", value}
      end)

    extensions = Map.get(block, "extensions", %{})

    if is_map(extensions) and
         not Enum.any?(Map.keys(metadata), &Map.has_key?(extensions, &1)),
       do: {:ok, Map.merge(extensions, metadata)},
       else: invalid_projection()
  end

  # Check recognized MCP fields before conversion; unknown extra content is
  # rejected instead of discarded. The original projection stays unchanged.
  defp projected_metadata(block, keys) do
    if Map.keys(block) -- (keys ++ ~w(annotations _meta)) == [] and
         Enum.all?(~w(annotations _meta), fn key ->
           not Map.has_key?(block, key) or is_map(block[key])
         end),
       do: :ok,
       else: invalid_projection()
  end

  defp invalid_projection, do: Error.invalid("Invalid projected tool result")
  defp unsupported_projection, do: Error.incompatible("Unsupported projected tool result content")

  defp canonical_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case canonical_part(part) do
        {:ok, blocks} -> {:cont, {:ok, acc ++ List.wrap(blocks)}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  # Invocation-local official values: no persisted Synapsis resource part is introduced.
  defp canonical_part(
         %ContentBlock{
           type: :resource,
           data: %{"uri" => uri, "mime_type" => "application/pdf", "data" => data} = resource,
           extensions: extensions
         } = block
       )
       when map_size(resource) == 3 and extensions == %{} and is_binary(uri) and is_binary(data),
       do: ContentBlock.new(block, limits: @limits)

  defp canonical_part(%Synapsis.Part.Text{content: content}),
    do: {:ok, %{type: :text, text: content}}

  defp canonical_part(%Synapsis.Part.DeliveredImage{} = part),
    do: {:ok, %{type: :text, text: Synapsis.Part.DeliveredImage.summary(part)}}

  defp canonical_part(%Synapsis.Part.Video{} = part),
    do: {:ok, %{type: :text, text: Synapsis.Part.Video.summary(part)}}

  defp canonical_part(%Synapsis.Part.Audio{} = part),
    do: {:ok, %{type: :text, text: Synapsis.Part.Audio.summary(part)}}

  defp canonical_part(%Synapsis.Part.Image{media_type: media_type, data: data}) do
    {:ok,
     %{
       type: :image,
       data: %{"source" => "base64", "media_type" => media_type, "data" => data}
     }}
  end

  defp canonical_part(%Synapsis.Part.ToolUse{} = part) do
    with {:ok, arguments} <- tool_arguments(part.input) do
      {:ok,
       %{
         type: :tool_call,
         tool_call: %{
           id: part.tool_use_id,
           native_id: part.tool_use_id,
           name: ToolName.encode(part.tool),
           raw_arguments: arguments
         }
       }}
    end
  end

  defp canonical_part(%Synapsis.Part.Reasoning{} = part) do
    states = Map.get(part, :provider_states, []) || []

    cond do
      part.signature not in [nil, ""] and states == [] ->
        Error.incompatible("Signed reasoning cannot be replayed without provider origin metadata")

      true ->
        reasoning =
          if part.content in [nil, ""] or signed_state_only?(states),
            do: [],
            else: [%{type: :reasoning, data: part.content}]

        with {:ok, provider_states} <- canonical_provider_states(states) do
          {:ok, reasoning ++ Enum.map(provider_states, &%{type: :provider_state, state: &1})}
        end
    end
  end

  defp canonical_part(%Synapsis.Part.ToolResult{}) do
    Error.invalid("Tool results must be encoded as tool messages")
  end

  defp canonical_part(part) do
    name = if is_map(part) and Map.has_key?(part, :__struct__), do: part.__struct__, else: part
    Error.incompatible("Unsupported message part: #{inspect(name)}")
  end

  defp tool_arguments(input) when is_binary(input), do: {:ok, {:custom, input}}

  defp tool_arguments(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} ->
        {:ok, {:json, json}}

      {:error, error} ->
        Error.invalid("Tool call arguments are not JSON encodable: #{Exception.message(error)}")
    end
  end

  defp tool_arguments(_), do: Error.invalid("Tool call arguments must be a map or custom text")

  defp canonical_provider_states(states) do
    Enum.reduce_while(states, {:ok, []}, fn state, {:ok, acc} ->
      attrs = %{
        source_profile: field(state, :source_profile),
        source_protocol: field(state, :source_protocol),
        kind: field(state, :kind),
        affinity: affinity_attrs(field(state, :affinity)),
        payload: field(state, :payload),
        payload_reference: field(state, :payload_reference),
        constraints: field(state, :constraints) || %{},
        extensions: field(state, :extensions) || %{}
      }

      case Backplane.AiProtocol.ProviderState.new(attrs, limits: @limits) do
        {:ok, provider_state} -> {:cont, {:ok, acc ++ [provider_state]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp signed_state_only?([]), do: false

  defp signed_state_only?(states) do
    Enum.all?(states, fn state ->
      field(state, :kind) in ["anthropic_signed_thinking", "google_thought_signature"]
    end)
  end

  defp affinity_attrs(nil), do: %{}

  defp affinity_attrs(affinity) do
    [:profile, :protocol, :endpoint, :account, :workspace, :model]
    |> Enum.reduce(%{}, fn key, acc ->
      case field(affinity, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp canonical_tool(%{type: type} = tool, _protocol) when type in [:custom, "custom"] do
    %{
      name: ToolName.encode(tool.name),
      description: tool.description,
      input_kind: :custom,
      input_schema: Map.get(tool, :parameters),
      format: Map.get(tool, :format)
    }
  end

  defp canonical_tool(tool, _protocol) do
    %{
      name: ToolName.encode(tool.name),
      description: tool.description,
      input_schema: tool.parameters
    }
  end

  defp system_message(opts) do
    case option(opts, :system_prompt) do
      prompt when prompt in [nil, ""] -> []
      prompt -> [%{role: :system, content: [%{type: :text, text: prompt}]}]
    end
  end

  defp settings(:anthropic, opts),
    do:
      compact(%{
        "max_tokens" => option(opts, :max_tokens) || 8192,
        "temperature" => option(opts, :temperature)
      })

  defp settings(:openai, opts),
    do:
      compact(%{
        "max_tokens" => option(opts, :max_tokens),
        "temperature" => option(opts, :temperature)
      })

  defp settings(:google, opts),
    do:
      compact(%{
        "max_output_tokens" => option(opts, :max_tokens),
        "temperature" => option(opts, :temperature),
        "thinking_config" => option(opts, :thinking_config)
      })

  defp settings(:openai_responses, opts),
    do:
      compact(%{
        "max_output_tokens" => option(opts, :max_output_tokens) || option(opts, :max_tokens),
        "temperature" => option(opts, :temperature)
      })

  defp extensions(:openai, opts) do
    reasoning_split = option(opts, :reasoning_split)

    if is_boolean(reasoning_split) or minimax?(opts) do
      %{
        "minimax::reasoning_split" =>
          if(is_boolean(reasoning_split), do: reasoning_split, else: true)
      }
    else
      %{}
    end
  end

  defp extensions(_protocol, _opts), do: %{}

  defp codec_opts(protocol, model, opts) do
    [
      stream: option(opts, :stream) != false,
      profile: option(opts, :provider_name) || Atom.to_string(protocol),
      endpoint: option(opts, :endpoint) || option(opts, :base_url) || default_base_url(protocol),
      account: option(opts, :account),
      workspace: option(opts, :workspace),
      model: model,
      limits: @limits
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp minimax?(opts) do
    [:provider_name, :base_url, :endpoint, :model]
    |> Enum.map(&option(opts, &1))
    |> Enum.any?(fn
      value when is_binary(value) -> String.contains?(String.downcase(value), "minimax")
      _ -> false
    end)
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp default_base_url(:anthropic), do: Transport.Anthropic.default_base_url()
  defp default_base_url(:openai), do: Transport.OpenAI.default_base_url()
  defp default_base_url(:openai_responses), do: Transport.OpenAI.default_base_url()
  defp default_base_url(:google), do: Transport.Google.default_base_url()

  defp normalize_role(role) when role in [:system, :developer, :user, :assistant, :tool], do: role
  defp normalize_role("system"), do: :system
  defp normalize_role("developer"), do: :developer
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role("tool"), do: :tool
  defp normalize_role(_), do: :user

  defp option(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(opts, Atom.to_string(key))
    end
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
