defmodule Synapsis.Agent.QueryLoop do
  @moduledoc """
  CCB-style tail-recursive agentic loop.
  Runs: user message -> LLM stream -> tool dispatch -> tool results -> LLM again -> completion.
  Events are sent to `context.subscriber` as `{:query_event, event}`.
  """

  require Logger
  alias __MODULE__.{State, Context, Executor}
  alias Synapsis.Agent.StreamingExecutor

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
      {:ok, assistant_msg, tool_blocks, pre_results} when pre_results != [] ->
        # Streaming executor already ran the tools
        new_state = State.append_messages(state, [assistant_msg])
        notify(ctx, {:stream_end, assistant_msg})

        if tool_blocks == [] do
          {:terminal, :completed, new_state}
        else
          # Notify tool results from streaming executor
          Enum.each(pre_results, fn result ->
            notify(ctx, {:tool_result, result.tool_use_id, result})
          end)

          tool_result_msg = %{
            role: "user",
            content:
              Enum.map(pre_results, fn r ->
                %{
                  type: "tool_result",
                  tool_use_id: r.tool_use_id,
                  content: r.content,
                  is_error: r.is_error
                }
              end)
          }

          new_state = State.append_messages(new_state, [tool_result_msg])
          {:continue, new_state}
        end

      {:ok, assistant_msg, tool_blocks, []} ->
        # Streaming path but no pre-results — fall through to batch
        handle_batch_result(state, assistant_msg, tool_blocks, ctx)

      {:ok, assistant_msg, tool_blocks} ->
        # Batch path (streaming_tools_enabled = false)
        handle_batch_result(state, assistant_msg, tool_blocks, ctx)

      {:error, reason} ->
        Logger.warning("query_loop_model_error", reason: inspect(reason))
        {:terminal, :model_error, state}
    end
  end

  defp handle_batch_result(state, assistant_msg, tool_blocks, ctx) do
    new_state = State.append_messages(state, [assistant_msg])
    notify(ctx, {:stream_end, assistant_msg})

    if tool_blocks == [] do
      {:terminal, :completed, new_state}
    else
      execute_and_continue(new_state, tool_blocks, ctx)
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
      :ok -> collect_with_streaming(ctx)
      {:ok, _ref} -> collect_with_streaming(ctx)
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_stream(request, config) do
    Synapsis.Provider.Adapter.stream(request, config)
  end

  # Dispatches to streaming or batch collect loop based on ctx.streaming_tools_enabled.
  # Streaming path returns {:ok, msg, blocks, results} (4-tuple).
  # Batch path returns {:ok, msg, blocks} (3-tuple).
  defp collect_with_streaming(ctx) do
    if ctx.streaming_tools_enabled do
      tool_modules = ctx.agent_config[:tool_modules] || build_tool_map(ctx.tools)

      executor =
        StreamingExecutor.new(tool_modules, %{
          session_id: ctx.session_id,
          project_path: ctx.project_path,
          working_dir: ctx.working_dir
        })

      collect_loop_streaming(ctx, %{text: "", tools: [], building_tool: nil}, executor)
    else
      collect_loop(ctx, %{text: "", tools: [], building_tool: nil})
    end
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

  # Streaming collect loop — same as collect_loop but feeds completed tool blocks
  # to a StreamingExecutor for eager dispatch. Returns 4-tuple.
  defp collect_loop_streaming(ctx, acc, executor) do
    receive do
      {:provider_chunk, :done} ->
        flush_provider_done()
        # Wait for all in-flight tools to complete
        {results, _exec} = StreamingExecutor.get_remaining_results(executor)
        assistant_msg = build_assistant_message(acc.text, acc.tools)
        {:ok, assistant_msg, acc.tools, results}

      :provider_done ->
        {results, _exec} = StreamingExecutor.get_remaining_results(executor)
        assistant_msg = build_assistant_message(acc.text, acc.tools)
        {:ok, assistant_msg, acc.tools, results}

      {:provider_chunk, {:text_delta, text}} ->
        notify(ctx, {:stream_chunk, {:text_delta, text}})
        collect_loop_streaming(ctx, %{acc | text: acc.text <> text}, executor)

      {:provider_chunk, {:tool_use_start, name, id}} ->
        notify(ctx, {:stream_chunk, {:tool_use_start, name, id}})
        collect_loop_streaming(ctx, %{acc | building_tool: %{name: name, id: id, json: ""}}, executor)

      {:provider_chunk, {:tool_input_delta, json}} ->
        case acc.building_tool do
          nil -> collect_loop_streaming(ctx, acc, executor)
          tool -> collect_loop_streaming(ctx, %{acc | building_tool: %{tool | json: tool.json <> json}}, executor)
        end

      {:provider_chunk, {:tool_use_complete, name, args}} ->
        tool_id =
          if acc.building_tool,
            do: acc.building_tool.id,
            else: "tu_#{System.unique_integer([:positive])}"

        block = %{id: tool_id, name: name, input: args}
        executor = StreamingExecutor.add_tool(executor, block)
        collect_loop_streaming(ctx, %{acc | tools: acc.tools ++ [block], building_tool: nil}, executor)

      {:provider_chunk, :content_block_stop} ->
        case acc.building_tool do
          nil ->
            collect_loop_streaming(ctx, acc, executor)

          %{name: name, id: id, json: json} ->
            if Enum.any?(acc.tools, &(&1.id == id)) do
              collect_loop_streaming(ctx, %{acc | building_tool: nil}, executor)
            else
              args =
                case Jason.decode(json) do
                  {:ok, parsed} -> parsed
                  _ -> %{}
                end

              block = %{id: id, name: name, input: args}
              executor = StreamingExecutor.add_tool(executor, block)
              collect_loop_streaming(ctx, %{acc | tools: acc.tools ++ [block], building_tool: nil}, executor)
            end
        end

      {:provider_chunk, {:error, reason}} ->
        {:error, reason}

      {:provider_chunk, _other} ->
        collect_loop_streaming(ctx, acc, executor)
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
