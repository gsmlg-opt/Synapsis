defmodule Synapsis.Agent.Runtime.ProviderMessages do
  @moduledoc "Plain runtime history ↔ Synapsis domain parts, without provider wire formats."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.Part.{Audio, DeliveredImage, Image, Reasoning, Text, ToolResult, ToolUse, Video}

  def to_host(messages) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, [], %{}}, fn message, {:ok, host, calls} ->
      with {:ok, converted} <- host_message(message, calls) do
        {:cont, {:ok, host ++ List.wrap(converted), remember_calls(converted, calls)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, host, _calls} -> {:ok, host}
      error -> error
    end
  end

  def to_host(_), do: unsupported("Expected a list of messages or blocks")
  def from_host(messages), do: map_all(messages, &runtime_message/1)

  @doc "Builds a public host result, retaining rich native data and redacting diagnostic errors."
  def tool_result_part(id, result, tool_name \\ nil) do
    result = if tool_name == "apply_patch", do: result, else: safe_result(result)

    if legacy_result?(result) do
      {:ok,
       %ToolResult{
         tool_use_id: id,
         content: result.content,
         is_error: Map.get(result, :is_error, false)
       }}
    else
      with {:ok, part} <- ResultProjection.to_part(id, result, tool_name: tool_name),
           content when is_binary(content) or is_list(content) <-
             part.projection["result"]["content"] do
        {:ok, part}
      else
        {:error, _} = error -> error
        _ -> unsupported("Tool result has no supported public content")
      end
    end
  end

  defp host_message(%{role: :tool, tool_call_id: id, result: result} = message, calls) do
    with {:ok, name} <- result_name(message, calls[id]),
         {:ok, part} <- tool_result_part(id, result, name),
         do: {:ok, %{role: :tool, parts: [part]}}
  end

  defp host_message(message, _calls), do: host_message(message)

  defp result_name(message, expected) do
    case Map.fetch(message, :name) do
      :error ->
        {:ok, expected}

      {:ok, name} when is_binary(name) ->
        if String.valid?(name) and String.trim(name) != "" and
             (is_nil(expected) or expected == name),
           do: {:ok, name},
           else: unsupported("Tool result name does not match its call")

      _ ->
        unsupported("Tool result name is invalid")
    end
  end

  defp remember_calls(%{role: :assistant, parts: parts}, calls) do
    Enum.reduce(parts, calls, fn
      %ToolUse{tool_use_id: id, tool: name}, acc -> Map.put(acc, id, name)
      _, acc -> acc
    end)
  end

  defp remember_calls(_, calls), do: calls

  defp legacy_result?(%{content: content} = result) when is_binary(content) do
    Map.keys(result) -- [:content, :is_error] == [] and
      is_boolean(Map.get(result, :is_error, false))
  end

  defp legacy_result?(_), do: false

  defp safe_result(%{is_error: true, error: %Error{} = error} = result) do
    {:ok, text} = tool_result_text(%{is_error: true, error: error})

    %{result | error: %{error | message: text, details: %{}, cause: nil}}
    |> Map.put_new(:content, text)
  end

  defp safe_result(%{is_error: true, error: error}) when not is_map(error),
    do: %{is_error: true, content: "Tool execution failed"}

  defp safe_result(result), do: result

  defp host_message(%{role: role, content: content} = message)
       when role in [:system, :developer, :user, :assistant] do
    blocks = if is_binary(content), do: [%{type: :text, text: content}], else: content
    calls = Enum.map(Map.get(message, :tool_calls, []), &Map.put(&1, :type, :tool_call))
    blocks = blocks ++ calls

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
       when is_binary(id) and is_binary(name) and (is_map(args) or is_binary(args)),
       do: {:ok, %ToolUse{tool_use_id: id, tool: name, input: args}}

  defp host_part(_), do: unsupported("Unsupported runtime content block")

  defp runtime_message(%{role: role, parts: parts}) when is_list(parts) do
    {results, content} = Enum.split_with(parts, &match?(%ToolResult{}, &1))

    with {:ok, role} <- runtime_role(role),
         {:ok, blocks} <- map_all(content, &runtime_part/1),
         {:ok, tools} <- map_all(results, &runtime_result/1) do
      messages = if blocks == [], do: [], else: [%{role: role, content: blocks}]
      {:ok, messages ++ tools}
    end
  end

  defp runtime_message(_), do: unsupported("Unsupported host message")

  defp runtime_result(%ToolResult{projection: nil, content: content, is_error: is_error} = part)
       when is_binary(content) and is_boolean(is_error) do
    {:ok,
     %{
       role: :tool,
       tool_call_id: part.tool_use_id,
       result: %{content: content, is_error: is_error}
     }}
  end

  defp runtime_result(part) do
    with {:ok, %{"result" => public}} <- ResultProjection.from_part(part) do
      result =
        Enum.reduce(
          [{"content", :content}, {"is_error", :is_error}, {"error", :error}],
          public,
          fn {key, atom}, acc ->
            case Map.pop(acc, key) do
              {nil, _} -> acc
              {value, rest} -> Map.put(rest, atom, value)
            end
          end
        )

      {:ok, %{role: :tool, tool_call_id: part.tool_use_id, result: result}}
    end
  end

  for role <- [:system, :developer, :user, :assistant, :tool] do
    defp runtime_role(unquote(role)), do: {:ok, unquote(role)}
    defp runtime_role(unquote(Atom.to_string(role))), do: {:ok, unquote(role)}
  end

  defp runtime_role(_), do: unsupported("Unsupported host message role")

  defp runtime_part(%Text{content: text}), do: {:ok, %{type: :text, text: text}}

  defp runtime_part(%DeliveredImage{} = part),
    do: {:ok, %{type: :text, text: DeliveredImage.summary(part)}}

  defp runtime_part(%Video{} = part), do: {:ok, %{type: :text, text: Video.summary(part)}}

  defp runtime_part(%Audio{} = part), do: {:ok, %{type: :text, text: Audio.summary(part)}}

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

  @doc "Formats runtime tool results for provider history and live events, redacting diagnostic errors."
  def tool_result_text(%{content: content}) when is_binary(content), do: {:ok, content}

  def tool_result_text(%{is_error: true, error: %Error{class: :forbidden}}),
    do: {:ok, "Tool denied by capability policy"}

  def tool_result_text(%{
        is_error: true,
        error: %Error{class: :resource_conflict, message: "Tool registration changed"}
      }),
      do: {:ok, "Tool registration changed"}

  def tool_result_text(%{
        is_error: true,
        error: %Error{class: :not_found, message: "tool is not registered"}
      }),
      do: {:ok, "Tool denied: tool is not in this run catalog"}

  def tool_result_text(%{is_error: true}), do: {:ok, "Tool execution failed"}

  def tool_result_text(%{content: content} = result) when is_list(content),
    do: projected_text(result, nil)

  def tool_result_text(_), do: unsupported("Tool result has no supported public text")

  @doc "Formats supported public native results using their original tool identity."
  def tool_result_text(result, tool_name), do: projected_text(result, tool_name)

  defp projected_text(result, tool_name) do
    with {:ok, part} <- live_result_part(result, tool_name) do
      case part.projection do
        nil ->
          {:ok, part.content}

        %{"result" => %{"content" => content}} when is_binary(content) ->
          {:ok, part.content}

        %{"result" => %{"content" => content}} when is_list(content) ->
          if (tool_name == "view_image" and not part.is_error) or
               Enum.all?(
                 content,
                 &match?(%{"type" => "text", "text" => text} when is_binary(text), &1)
               ),
             do: {:ok, part.content},
             else: unsupported("Tool result contains unsupported display media")

        _ ->
          unsupported("Tool result has no supported public text")
      end
    end
  end

  # History has no provenance distinguishing old text from a fresh text map.
  # Keep its legacy path intact; exact-name live image summaries are stricter.
  defp live_result_part(result, "view_image"),
    do: ResultProjection.to_part("display", safe_result(result), tool_name: "view_image")

  defp live_result_part(result, tool_name),
    do: tool_result_part("display", result, tool_name)

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
