defmodule Synapsis.SessionHistory do
  @moduledoc """
  Bounded public pages of durable session turns, without live Worker calls.

  Metadata existence and the selected turn page share one absolute deadline of
  at most five seconds. Linked readers follow caller cancellation. Each page
  observes current durable state, not a snapshot across pages; current in-flight
  tool calls are absent. Typed omissions preserve the distinction between text
  and unsupported or intentionally excluded content. No tools are replayed.
  """
  alias Synapsis.Session.Store
  @output_limit 65_536
  @errors ~w(not_found timeout scan_limit stale_page invalid_record payload_too_large storage_unavailable)a

  @doc "Read a captured standalone source-projected window with exact JavaScript JSON text."
  def read_rendered(input, context, opts \\ []),
    do: Synapsis.SessionHistory.Window.read(input, context, opts)

  def validate_window(input), do: Synapsis.SessionHistory.Window.validate(input)

  def read(input, context, opts \\ []) do
    with :ok <- validate(input),
         :ok <- context_valid(context),
         {:ok, deadline} <- deadline(opts),
         id = Map.get(input, "session_id", context.session_id),
         {:ok, page} <- bounded_read(id, input, deadline),
         {:ok, turns} <- project_turns(page.turns, Map.get(input, "include_tools", false)),
         :ok <- remaining(deadline),
         result =
           Map.merge(Map.take(page, [:has_more, :next_cursor, :truncated]), %{
             source: "durable",
             session_id: id,
             turns: turns
           }),
         {:ok, json} <- Jason.encode(result),
         true <- byte_size(json) <= @output_limit do
      {:ok, result}
    else
      false -> {:error, :output_limit}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :malformed_history}
    end
  end

  def validate(input) when is_map(input) and not is_struct(input) do
    if Map.keys(input) -- ~w(session_id cursor limit include_tools) == [] and
         optional?(input, "session_id", &uuid?/1) and
         optional?(input, "cursor", &(is_integer(&1) and &1 in 0..999_999_999_999)) and
         optional?(input, "limit", &(is_integer(&1) and &1 in 1..100)) and
         optional?(input, "include_tools", &is_boolean/1),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate(_), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == [:agent_id, :session_id] and uuid?(context[:session_id]) and
         is_binary(context[:agent_id]) and byte_size(context.agent_id) in 1..256 and
         String.valid?(context.agent_id) and String.trim(context.agent_id) != "",
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp deadline(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      ceiling = now() + 5_000
      value = Keyword.get(opts, :deadline, ceiling)
      if is_integer(value), do: {:ok, min(value, ceiling)}, else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp deadline(_), do: {:error, :invalid_input}

  defp bounded_read(id, input, deadline) do
    with :ok <- remaining(deadline) do
      task =
        Task.async(fn ->
          try do
            with :ok <- remaining(deadline),
                 {:ok, meta} <- Store.get_meta(id, timeout: max(deadline - now(), 1)),
                 true <- is_map(meta) and not is_struct(meta) and field(meta, :id) === id,
                 :ok <- remaining(deadline) do
              options = [
                deadline: deadline,
                limit: Map.get(input, "limit", 20),
                max_bytes: 1_048_576
              ]

              options =
                if Map.has_key?(input, "cursor"),
                  do: Keyword.put(options, :cursor, input["cursor"]),
                  else: options

              Store.list_turn_page(id, options)
            else
              false -> {:error, :malformed_metadata}
              {:error, reason} when reason in @errors -> {:error, reason}
              _ -> {:error, :storage_unavailable}
            end
          rescue
            _ -> {:error, :storage_unavailable}
          catch
            _, _ -> {:error, :storage_unavailable}
          end
        end)

      case Task.yield(task, max(deadline - now(), 0)) do
        {:ok, {:ok, page}} ->
          with :ok <- remaining(deadline), do: {:ok, page}

        {:ok, {:error, reason}} when reason in @errors or reason == :malformed_metadata ->
          {:error, reason}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}

        _ ->
          {:error, :storage_unavailable}
      end
    end
  end

  defp project_turns(turns, include_tools) do
    map_all(turns, fn %{index: index, turn: turn} ->
      role = field(turn, :role)
      parts = field(turn, :parts)

      if role in ["user", "assistant", "system", "tool", :user, :assistant, :system, :tool] and
           is_list(parts) do
        with {:ok, projected} <- map_all(parts, &project_part(&1, include_tools)) do
          {:ok,
           %{
             index: index,
             role: to_string(role),
             parts: Enum.reject(projected, &(&1 == :tool_omitted)),
             omitted_tool_parts: Enum.count(projected, &(&1 == :tool_omitted))
           }}
        end
      else
        {:error, :malformed_history}
      end
    end)
  end

  defp project_part(part, include_tools) when is_map(part) and not is_struct(part) do
    case field(part, :type) do
      "text" ->
        text = field(part, :text)

        if is_binary(text) and String.valid?(text),
          do: {:ok, %{type: "text", text: text}},
          else: {:error, :malformed_history}

      "tool_result" when not include_tools ->
        {:ok, :tool_omitted}

      "tool_use" ->
        with {:ok, input} <- public_value(field(part, :input)) do
          if is_binary(field(part, :id)) and is_binary(field(part, :name)),
            do:
              {:ok,
               %{type: "tool_use", id: field(part, :id), name: field(part, :name), input: input}},
            else: {:error, :malformed_history}
        end

      "tool_result" ->
        tool_result(part)

      type when type in ["image", "file"] ->
        metadata =
          for key <- [:path, :media_type],
              is_binary(field(part, key)),
              into: %{},
              do: {key, field(part, key)}

        {:ok, Map.merge(metadata, %{type: type, omitted: true, reason: "content_not_included"})}

      "reasoning" ->
        {:ok, %{type: "reasoning", omitted: true, reason: "content_not_included"}}

      type when is_binary(type) ->
        {:ok, %{type: type, omitted: true, reason: "unsupported_part"}}

      _ ->
        {:error, :malformed_history}
    end
  end

  defp project_part(_, _), do: {:error, :malformed_history}

  defp tool_result(part) do
    content = field(part, :content)
    id = field(part, :tool_use_id)
    error = field(part, :is_error)

    if is_binary(content) and String.valid?(content) and is_binary(id) and is_boolean(error) do
      result = %{type: "tool_result", tool_use_id: id, content: content, is_error: error}

      case field(part, :projection) do
        nil ->
          {:ok, result}

        %{"version" => 1, "result" => public} = projection
        when map_size(projection) == 2 and is_map(public) ->
          with {:ok, projection} <- public_value(projection, 0, true),
               do: {:ok, Map.put(result, :projection, projection)}

        _ ->
          {:error, :unsupported_projection}
      end
    else
      {:error, :malformed_history}
    end
  end

  # Tool inputs remain portable JSON values. Within retained result projections,
  # typed media blocks become descriptive markers instead of model media replay.
  # Other structured fields retain their names and values, including user arguments.
  defp public_value(value, depth \\ 0, omit_media \\ false)
  defp public_value(_, depth, _) when depth > 24, do: {:error, :unsupported_projection}

  defp public_value(%{"type" => type} = value, depth, true)
       when type in ["image", "audio", "video", "file"] do
    source = Map.get(value, "data")
    media_type = if is_map(source), do: source["media_type"], else: value["media_type"]
    summary = %{"type" => type, "omitted" => true, "reason" => "media_not_included"}

    summary =
      if is_binary(media_type), do: Map.put(summary, "media_type", media_type), else: summary

    public_value(summary, depth, false)
  end

  defp public_value(value, depth, omit_media)
       when is_map(value) and not is_struct(value) and map_size(value) <= 1_000 do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if is_binary(key) and String.valid?(key) do
        case public_value(value, depth + 1, omit_media) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          error -> {:halt, error}
        end
      else
        {:halt, {:error, :unsupported_projection}}
      end
    end)
  end

  defp public_value(value, depth, omit_media) when is_list(value) do
    if length(value) <= 1_000,
      do: map_all(value, &public_value(&1, depth + 1, omit_media)),
      else: {:error, :unsupported_projection}
  end

  defp public_value(value, _, _) when is_binary(value) do
    if byte_size(value) <= @output_limit and String.valid?(value),
      do: {:ok, value},
      else: {:error, :output_limit}
  end

  defp public_value(value, _, _) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp public_value(_, _, _), do: {:error, :unsupported_projection}

  defp map_all(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp optional?(input, key, check), do: not Map.has_key?(input, key) or check.(input[key])
  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false
  defp remaining(deadline), do: if(deadline > now(), do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)
end
