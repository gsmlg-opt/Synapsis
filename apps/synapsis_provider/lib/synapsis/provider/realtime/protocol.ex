defmodule Synapsis.Provider.Realtime.Protocol do
  @moduledoc "OpenAI Realtime GA events for a server-side audio conversation."

  @pcm %{type: "audio/pcm", rate: 24_000}
  @unsupported_tool_root_keywords ~w(oneOf anyOf allOf enum const not)

  def session_update(agent) do
    %{
      type: "session.update",
      session: %{
        type: "realtime",
        output_modalities: ["audio"],
        audio: %{
          input: %{
            format: @pcm,
            transcription: %{model: "gpt-4o-mini-transcribe"},
            turn_detection: turn_detection(agent.voice_turn_detection)
          },
          output: %{format: @pcm, voice: agent.voice}
        }
      }
    }
  end

  defp turn_detection("manual"), do: nil

  defp turn_detection(mode) when mode in ["server_vad", "semantic_vad"],
    do: %{type: mode, create_response: false, interrupt_response: false}

  def response(attempt, instructions, tools, items) do
    %{
      type: "response.create",
      event_id: "create_" <> attempt,
      response: %{
        metadata: %{attempt: attempt},
        instructions: instructions,
        tools: tools,
        input: Enum.map(items, &%{type: "item_reference", id: &1})
      }
    }
  end

  def tools(tools) do
    Enum.map_reduce(tools, %{}, fn tool, names ->
      name = tool.name

      wire =
        if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, name) and
             not String.starts_with?(name, "synapsis_") do
          name
        else
          "synapsis_" <> Base.url_encode64(:crypto.hash(:sha256, name), padding: false)
        end

      {%{
         type: "function",
         name: wire,
         description: tool.description,
         # Realtime rejects these keywords at the root of function parameters.
         # Conversation still validates calls against the original descriptor schema.
         parameters: Map.drop(tool.parameters, @unsupported_tool_root_keywords)
       }, Map.put(names, wire, name)}
    end)
  end

  def append(pcm), do: %{type: "input_audio_buffer.append", audio: Base.encode64(pcm)}
  def commit, do: %{type: "input_audio_buffer.commit"}
  def clear, do: %{type: "input_audio_buffer.clear"}
  def cancel(id), do: %{type: "response.cancel", response_id: id}

  def truncate(%{item_id: id, content_index: index, audio_end_ms: ms}) do
    %{
      type: "conversation.item.truncate",
      item_id: id,
      content_index: index,
      audio_end_ms: ms
    }
  end

  def text_item(id, text) do
    input_item(id, [%{type: :text, text: text}])
  end

  def input_item(id, content) do
    item(%{id: id, type: "message", role: "user", content: Enum.map(content, &input_part/1)})
  end

  defp input_part(%{type: :text, text: text}), do: %{type: "input_text", text: text}

  defp input_part(%{type: :image, media_type: media_type, data: data}),
    do: %{type: "input_image", image_url: "data:#{media_type};base64,#{data}"}

  def output_item(id, call_id, result),
    do: item(%{id: id, type: "function_call_output", call_id: call_id, output: result})

  defp item(item),
    do: %{type: "conversation.item.create", event_id: "put_" <> item.id, item: item}

  def finish(%{"status" => "completed", "output" => output} = response, names, _reason)
      when is_list(output) do
    with {:ok, calls} <- calls(output, names) do
      blocks =
        for %{"type" => "message", "id" => item, "content" => content} <- output,
            is_binary(item) and is_list(content),
            {block, index} <- Enum.with_index(content),
            is_map(block),
            text = block["transcript"] || block["text"],
            is_binary(text) do
          if block["type"] == "output_audio" and is_binary(response["id"]) do
            %{
              type: :spoken_audio,
              item_id: item,
              response_id: response["id"],
              content_index: index,
              text: text
            }
          else
            %{type: :text, text: text}
          end
        end

      {:ok, calls,
       %{
         type: :response_completed,
         message: %{role: :assistant, content: blocks},
         usage: usage(response["usage"])
       }}
    end
  end

  def finish(%{"status" => "cancelled"} = response, _names, reason) when is_binary(reason),
    do: {:ok, [], %{type: :response_interrupted, reason: reason, usage: usage(response["usage"])}}

  def finish(_, _, _), do: {:error, :realtime_response_failed}

  defp calls(output, names) do
    output
    |> Enum.filter(&match?(%{"type" => "function_call"}, &1))
    |> Enum.reduce_while({:ok, [], %{}}, fn item, {:ok, calls, seen} ->
      with %{"call_id" => id, "name" => wire, "arguments" => args, "status" => "completed"} <-
             item,
           true <- is_binary(id) and id != "" and byte_size(id) <= 256,
           name when is_binary(name) <- names[wire],
           true <- is_binary(args) and byte_size(args) <= 256_000,
           {:ok, arguments} when is_map(arguments) <- JSON.decode(args),
           call = %{id: id, name: name, arguments: arguments} do
        case Map.fetch(seen, id) do
          :error -> {:cont, {:ok, [call | calls], Map.put(seen, id, call)}}
          {:ok, ^call} -> {:cont, {:ok, calls, seen}}
          _ -> {:halt, {:error, :invalid_function_call}}
        end
      else
        _ -> {:halt, {:error, :invalid_function_call}}
      end
    end)
    |> case do
      {:ok, calls, _} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  defp usage(usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      cached_tokens: get_in(usage, ["input_token_details", "cached_tokens"])
    }
    |> Map.filter(fn {_key, value} -> is_integer(value) and value >= 0 end)
  end

  defp usage(_), do: %{}
end
