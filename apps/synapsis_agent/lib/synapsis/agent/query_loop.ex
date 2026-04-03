defmodule Synapsis.Agent.QueryLoop do
  @moduledoc """
  CCB-style tail-recursive agentic loop.
  Runs: user message -> LLM stream -> tool dispatch -> tool results -> LLM again -> completion.
  Events are sent to `context.subscriber` as `{:query_event, event}`.
  """

  require Logger
  alias __MODULE__.{State, Context, Executor}

  @type terminal_reason :: :completed | :max_turns | :aborted | :model_error

  @max_depth 3
  @read_only_levels [:none, :read]

  @doc """
  Creates a scoped child context for subagent execution.
  Inherits project/working dir, gets restricted tools, custom prompt.
  """
  @spec fork(Context.t(), keyword()) :: Context.t()
  def fork(%Context{} = parent, opts) do
    subscriber = Keyword.fetch!(opts, :subscriber)
    system_prompt = Keyword.fetch!(opts, :system_prompt)
    tools = filter_fork_tools(parent.tools, Keyword.get(opts, :tool_names, :read_only))

    %Context{
      session_id: parent.session_id,
      system_prompt: system_prompt,
      tools: tools,
      model: Keyword.get(opts, :model, parent.model),
      provider_config: parent.provider_config,
      subscriber: subscriber,
      abort_ref: make_ref(),
      project_path: parent.project_path,
      working_dir: parent.working_dir,
      depth: parent.depth + 1,
      streaming_tools_enabled: parent.streaming_tools_enabled,
      agent_config: parent.agent_config
    }
  end

  @doc "Returns true if depth allows spawning subagents."
  @spec can_fork?(Context.t()) :: boolean()
  def can_fork?(%Context{depth: d}), do: d < @max_depth

  @spec run(State.t(), Context.t()) :: {:ok, terminal_reason(), State.t()}
  def run(%State{} = state, %Context{} = ctx) do
    cond do
      State.max_turns_reached?(state) ->
        notify(ctx, {:terminal, :max_turns, state})
        {:ok, :max_turns, state}

      not Process.alive?(ctx.subscriber) ->
        {:ok, :aborted, state}

      true ->
        case do_turn(state, ctx) do
          {:continue, next_state} ->
            next_state = State.increment_turn(next_state)
            notify(ctx, {:turn_complete, next_state.turn_count})
            run(next_state, ctx)

          {:terminal, reason, final_state} ->
            final_state = State.increment_turn(final_state)
            notify(ctx, {:terminal, reason, final_state})
            {:ok, reason, final_state}
        end
    end
  end

  defp do_turn(state, ctx) do
    ctx = prepare_context(state, ctx)
    notify(ctx, {:stream_start})

    case stream_model(state, ctx) do
      {:ok, assistant_msg, tool_blocks} ->
        new_state = State.append_messages(state, [assistant_msg])
        notify(ctx, {:stream_end, assistant_msg})

        if tool_blocks == [] do
          {:terminal, :completed, new_state}
        else
          # Tool execution placeholder -- Task 6 implements this
          execute_and_continue(new_state, tool_blocks, ctx)
        end

      {:error, reason} ->
        Logger.warning("query_loop_model_error", reason: inspect(reason))
        {:terminal, :model_error, state}
    end
  end

  defp execute_and_continue(state, tool_blocks, ctx) do
    tool_modules = ctx.agent_config[:tool_modules] || build_tool_map(ctx.tools)

    # Notify tool starts
    Enum.each(tool_blocks, fn %{id: id, name: name, input: input} ->
      notify(ctx, {:tool_start, id, name, input})
    end)

    # Execute with concurrency partitioning
    results = Executor.run(tool_blocks, tool_modules, %{
      session_id: ctx.session_id,
      project_path: ctx.project_path,
      working_dir: ctx.working_dir
    })

    # Notify tool results
    Enum.each(results, fn result ->
      notify(ctx, {:tool_result, result.tool_use_id, result})
    end)

    # Build tool_result user message
    tool_result_msg = %{
      role: "user",
      content: Enum.map(results, fn r ->
        %{
          type: "tool_result",
          tool_use_id: r.tool_use_id,
          content: r.content,
          is_error: r.is_error
        }
      end)
    }

    new_state = State.append_messages(state, [tool_result_msg])
    {:continue, new_state}
  end

  defp prepare_context(state, %Context{system_prompt: :dynamic} = ctx) do
    user_message = state.messages |> Enum.reverse() |> Enum.find(& &1.role == "user")
    user_text = if user_message, do: extract_text(user_message.content), else: ""

    prompt = Synapsis.Agent.ContextBuilder.build_system_prompt(
      ctx.agent_config[:agent_type] || :conversational,
      project_id: ctx.agent_config[:project_id],
      session_id: ctx.session_id,
      user_message: user_text,
      agent_config: ctx.agent_config
    )

    %{ctx | system_prompt: prompt}
  end

  defp prepare_context(_state, ctx), do: ctx

  defp extract_text(content) when is_binary(content), do: content
  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1[:type] == "text"))
    |> Enum.map_join(" ", & &1[:text])
  end
  defp extract_text(_), do: ""

  defp build_tool_map(tools) do
    Enum.reduce(tools, %{}, fn tool, acc ->
      name = tool[:name] || Map.get(tool, "name")
      case name && Synapsis.Tool.Registry.lookup(name) do
        {:ok, {:module, mod, _opts}} -> Map.put(acc, name, mod)
        _ -> acc
      end
    end)
  end

  defp stream_model(state, ctx) do
    request = build_request(state, ctx)
    stream_fn = ctx.agent_config[:stream_fn] || (&default_stream/2)

    case stream_fn.(request, ctx.provider_config) do
      :ok -> collect_stream_events(ctx)
      {:ok, _ref} -> collect_stream_events(ctx)
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_stream(request, config) do
    Synapsis.Provider.Adapter.stream(request, config)
  end

  # Collect stream events from mailbox. Accumulates text and tool_use blocks.
  # Returns {:ok, assistant_message, tool_blocks} or {:error, reason}
  defp collect_stream_events(ctx) do
    collect_loop(ctx, %{text: "", tools: [], building_tool: nil})
  end

  defp collect_loop(ctx, acc) do
    receive do
      {:provider_chunk, :done} ->
        flush_provider_done()
        assistant_msg = build_assistant_message(acc.text, acc.tools)
        {:ok, assistant_msg, acc.tools}

      :provider_done ->
        assistant_msg = build_assistant_message(acc.text, acc.tools)
        {:ok, assistant_msg, acc.tools}

      {:provider_chunk, {:text_delta, text}} ->
        notify(ctx, {:stream_chunk, {:text_delta, text}})
        collect_loop(ctx, %{acc | text: acc.text <> text})

      {:provider_chunk, {:tool_use_start, name, id}} ->
        notify(ctx, {:stream_chunk, {:tool_use_start, name, id}})
        collect_loop(ctx, %{acc | building_tool: %{name: name, id: id, json: ""}})

      {:provider_chunk, {:tool_input_delta, json}} ->
        case acc.building_tool do
          nil -> collect_loop(ctx, acc)
          tool -> collect_loop(ctx, %{acc | building_tool: %{tool | json: tool.json <> json}})
        end

      {:provider_chunk, {:tool_use_complete, name, args}} ->
        tool_id =
          if acc.building_tool,
            do: acc.building_tool.id,
            else: "tu_#{System.unique_integer([:positive])}"

        block = %{id: tool_id, name: name, input: args}
        collect_loop(ctx, %{acc | tools: acc.tools ++ [block], building_tool: nil})

      {:provider_chunk, :content_block_stop} ->
        case acc.building_tool do
          nil ->
            collect_loop(ctx, acc)

          %{name: name, id: id, json: json} ->
            if Enum.any?(acc.tools, &(&1.id == id)) do
              collect_loop(ctx, %{acc | building_tool: nil})
            else
              args =
                case Jason.decode(json) do
                  {:ok, parsed} -> parsed
                  _ -> %{}
                end

              block = %{id: id, name: name, input: args}
              collect_loop(ctx, %{acc | tools: acc.tools ++ [block], building_tool: nil})
            end
        end

      {:provider_chunk, {:error, reason}} ->
        {:error, reason}

      {:provider_chunk, _other} ->
        collect_loop(ctx, acc)
    after
      300_000 -> {:error, :stream_timeout}
    end
  end

  defp flush_provider_done do
    receive do
      :provider_done -> :ok
    after
      0 -> :ok
    end
  end

  defp build_assistant_message(text, tools) do
    content =
      case {text, tools} do
        {"", []} -> []
        {t, []} when t != "" -> [%{type: "text", text: t}]
        {"", ts} -> Enum.map(ts, &tool_content_block/1)
        {t, ts} -> [%{type: "text", text: t} | Enum.map(ts, &tool_content_block/1)]
      end

    %{role: "assistant", content: content}
  end

  defp tool_content_block(%{id: id, name: name, input: input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp build_request(state, ctx) do
    tool_defs =
      Enum.map(ctx.tools, fn
        %{name: n, description: d, parameters: p} -> %{name: n, description: d, input_schema: p}
        other -> other
      end)

    %{
      model: ctx.model,
      system: ctx.system_prompt,
      messages: state.messages,
      tools: tool_defs,
      max_tokens: 8192,
      stream: true
    }
  end

  defp filter_fork_tools(tools, :read_only) do
    Enum.filter(tools, fn tool ->
      level = tool[:permission_level] || Map.get(tool, "permission_level", :write)
      level in @read_only_levels
    end)
  end

  defp filter_fork_tools(tools, names) when is_list(names) do
    name_set = MapSet.new(names)

    Enum.filter(tools, fn tool ->
      name = tool[:name] || Map.get(tool, "name")
      name in name_set
    end)
  end

  defp notify(%Context{subscriber: pid}, event) do
    if Process.alive?(pid), do: send(pid, {:query_event, event})
  end
end
