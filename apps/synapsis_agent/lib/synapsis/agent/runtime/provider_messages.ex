defmodule Synapsis.Agent.Runtime.ProviderMessages do
  @moduledoc "Plain runtime history ↔ Synapsis domain parts, without provider wire formats."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Part.{Image, Reasoning, Text, ToolResult, ToolUse}

  def to_host(messages), do: map_all(messages, &host_message/1)
  def from_host(messages), do: map_all(messages, &runtime_message/1)

  defp host_message(%{role: :tool, tool_call_id: id, result: result}) do
    with {:ok, content} <- result_text(result) do
      {:ok,
       %{
         role: :tool,
         parts: [
           %ToolResult{
             tool_use_id: id,
             content: content,
             is_error: Map.get(result, :is_error, false)
           }
         ]
       }}
    end
  end

  defp host_message(%{role: role, content: content})
       when role in [:system, :developer, :user, :assistant] do
    blocks = if is_binary(content), do: [%{type: :text, text: content}], else: content

    with {:ok, parts} <- map_all(blocks, &host_part/1),
         do: {:ok, %{role: role, parts: parts}}
  end

  defp host_message(_), do: unsupported("Unsupported runtime message")

  defp host_part(%{type: :text, text: text}) when is_binary(text),
    do: {:ok, %Text{content: text}}

  defp host_part(%{type: :reasoning, text: text} = block) when is_binary(text),
    do:
      {:ok,
       %Reasoning{
         content: text,
         signature: block[:signature],
         provider_states: Map.get(block, :provider_states, [])
       }}

  defp host_part(%{type: :image, media_type: media_type, data: data} = block)
       when is_binary(media_type) and is_binary(data),
       do: {:ok, %Image{media_type: media_type, data: data, path: block[:path]}}

  defp host_part(%{type: :tool_call, id: id, name: name, arguments: args})
       when is_binary(id) and is_binary(name) and is_map(args),
       do: {:ok, %ToolUse{tool_use_id: id, tool: name, input: args}}

  defp host_part(_), do: unsupported("Unsupported runtime content block")

  defp runtime_message(%{role: role, parts: parts}) when is_list(parts) do
    {results, content} = Enum.split_with(parts, &match?(%ToolResult{}, &1))

    with {:ok, role} <- runtime_role(role),
         {:ok, blocks} <- map_all(content, &runtime_part/1) do
      messages = if blocks == [], do: [], else: [%{role: role, content: blocks}]

      tools =
        Enum.map(results, fn part ->
          %{
            role: :tool,
            tool_call_id: part.tool_use_id,
            result: %{content: part.content, is_error: part.is_error}
          }
        end)

      {:ok, messages ++ tools}
    end
  end

  defp runtime_message(_), do: unsupported("Unsupported host message")

  for role <- [:system, :developer, :user, :assistant, :tool] do
    defp runtime_role(unquote(role)), do: {:ok, unquote(role)}
    defp runtime_role(unquote(Atom.to_string(role))), do: {:ok, unquote(role)}
  end

  defp runtime_role(_), do: unsupported("Unsupported host message role")

  defp runtime_part(%Text{content: text}), do: {:ok, %{type: :text, text: text}}

  defp runtime_part(%Reasoning{} = part),
    do:
      {:ok,
       %{
         type: :reasoning,
         text: part.content || "",
         signature: part.signature,
         provider_states: part.provider_states
       }}

  defp runtime_part(%Image{} = part),
    do: {:ok, %{type: :image, media_type: part.media_type, data: part.data, path: part.path}}

  defp runtime_part(%ToolUse{} = part),
    do: {:ok, %{type: :tool_call, id: part.tool_use_id, name: part.tool, arguments: part.input}}

  defp runtime_part(_), do: unsupported("Unsupported host content part")

  defp result_text(%{content: content}) when is_binary(content), do: {:ok, content}

  defp result_text(%{content: content}) do
    case Jason.encode(content) do
      {:ok, text} -> {:ok, text}
      _ -> unsupported("Tool result is not JSON encodable")
    end
  end

  defp result_text(%{is_error: true}), do: {:ok, "Tool execution failed"}
  defp result_text(_), do: unsupported("Tool result has no content")

  defp map_all(items, fun) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, acc ++ List.wrap(value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp map_all(_, _), do: unsupported("Expected a list of messages or blocks")
  defp unsupported(message), do: {:error, Error.new(:unsupported_capability, message)}
end
