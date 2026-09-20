defmodule Synapsis.Provider.MessageMapper do
  @moduledoc """
  Converts Synapsis domain messages into canonical Backplane requests and
  delegates provider wire encoding to `Backplane.AiProtocol.Codec`.
  """

  alias Backplane.AiProtocol.{Codec, Error, Request}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Provider.Transport

  @limits %{
    max_bytes: 32 * 1024 * 1024,
    max_string_bytes: 32 * 1024 * 1024,
    max_depth: 64
  }

  @spec build_request(atom(), list(), list(), map()) :: {:ok, map()} | {:error, Error.t()}
  def build_request(protocol, messages, tools, opts) do
    model =
      option(opts, :model) ||
        Synapsis.Providers.default_model(option(opts, :provider_name) || Atom.to_string(protocol))

    with {:ok, input} <- canonical_messages(messages),
         {:ok, request} <-
           Request.new(
             %{
               model: model,
               input: system_message(opts) ++ input,
               tools: Enum.map(tools, &canonical_tool(&1, protocol)),
               settings: settings(protocol, opts),
               extensions: extensions(protocol, opts)
             },
             limits: @limits
           ) do
      Codec.encode_request(protocol, request, codec_opts(protocol, model, opts))
    end
  end

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

    with {:ok, content} <- canonical_parts(content_parts) do
      messages = if content == [], do: [], else: [%{role: role, content: content}]

      tool_results =
        Enum.map(results, fn result ->
          %{
            role: :tool,
            tool_call_id: result.tool_use_id,
            status: if(result.is_error, do: :error, else: :success),
            content: [%{type: :text, text: result.content}]
          }
        end)

      {:ok, messages ++ tool_results}
    end
  end

  defp canonical_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case canonical_part(part) do
        {:ok, blocks} -> {:cont, {:ok, acc ++ List.wrap(blocks)}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp canonical_part(%Synapsis.Part.Text{content: content}),
    do: {:ok, %{type: :text, text: content}}

  defp canonical_part(%Synapsis.Part.Image{media_type: media_type, data: data}) do
    {:ok,
     %{
       type: :image,
       data: %{"source" => "base64", "media_type" => media_type, "data" => data}
     }}
  end

  defp canonical_part(%Synapsis.Part.ToolUse{} = part) do
    with {:ok, json} <- Jason.encode(part.input) do
      {:ok,
       %{
         type: :tool_call,
         tool_call: %{
           id: part.tool_use_id,
           native_id: part.tool_use_id,
           name: ToolName.encode(part.tool),
           raw_arguments: {:json, json}
         }
       }}
    else
      {:error, error} ->
        Error.invalid("Tool call arguments are not JSON encodable: #{Exception.message(error)}")
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
        "maxOutputTokens" => option(opts, :max_tokens),
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
