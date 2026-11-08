defmodule Synapsis.Workflow.Machine do
  @moduledoc """
  Pure, defunctionalized tool-mode pipeline interpreter foundation.

  State is JSON data, saved together with its version-1 Value heap. The stack
  records construction, demand, post-yield, return and stage-finalization work;
  buffered iterators never acquire array identity. Head, pick, json, ask, sort,
  dedupe, groupBy, map, where, table, template, invoke and state continuations are implemented.
  No native execution, persistence, transport, file reader, template renderer or
  schema validator is installed here. Trusted host drivers fulfill schema,
  invoke, sort, state, template file-content and lazy per-item template-render requests.

  A checkpoint's `command_input` is a string-key pending/history record whose
  schema, subject, suspended state and response fields are tagged heap roots.
  The request envelope contains an independently constructed tagged object with
  the reference commandInput shape. Resume creates a fresh sliced segment.

  Runtime strings retain exact UTF-16 code units. Diagnostic `stdout` contains
  UTF-8 text after each complete source write passes through Node Writable's
  encoding semantics; only that sink replaces unpaired surrogate units.
  """

  alias Synapsis.Workflow.{JSON, Number, State, Value}

  @edge_whitespace ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u
  # Capture edge whitespace too; trim/1 applies the source's ECMAScript trim
  # after the same nonempty, first-closing-braces placeholder match.
  @map_template ~r/\{\{([^}]+?)\}\}/u
  @where_predicate ~r/\A([a-zA-Z0-9_.]+)[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*(==|=|!=|<=|>=|<|>)[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*([^\n\r\x{2028}\x{2029}]+)\z/u
  @default_schema ~s({"type":"object","properties":{"decision":{"type":"string","enum":["approve","reject","redraft"]},"feedback":{"type":"string","description":"Feedback for redraft"}},"required":["decision"]})

  @doc "Creates an unstarted machine over trusted parsed stages and tagged input."
  def new(program, input, heap, options \\ %{})

  def new(program, %{"kind" => kind, "items" => items}, heap, options)
      when is_list(program) and kind in ["array", "iterator_items"] and is_list(items) and
             is_map(options) do
    {:ok,
     %{
       "version" => 1,
       "phase" => "construct",
       "stage_index" => 0,
       "heap" => heap,
       "program" => program,
       "options" => options,
       "frames" => [],
       "streams" => %{"s0" => buffered(kind, items)},
       "input_stream" => "s0",
       "current_stream" => "s0",
       "next_stream" => 1,
       "next_request" => 1,
       "segment" => 0,
       "stack" => [%{"op" => "construct"}],
       "signal" => nil,
       "pending_request" => nil,
       "resume_input" => nil,
       "items" => [],
       "rendered" => false,
       "rendered_items" => [],
       "pipeline_output_started" => false,
       "stdout" => ""
     }}
  end

  def new(_program, _input, _heap, _options), do: {:error, :invalid_machine_input}

  @doc "Performs one finite transition; pending driver requests are stable."
  def advance(state, event \\ nil) do
    {transition, _observations} = advance_observed(state, event)
    transition
  end

  @doc "Returns a transition and its volatile host observations without changing Machine state."
  def advance_observed(state, event \\ nil) do
    case advance_transition(state, event) do
      {:observed, transition, observations} -> {transition, observations}
      transition -> {transition, []}
    end
  end

  defp advance_transition(
         %{
           "phase" => "request",
           "pending_request" => %{"id" => request_id, "kind" => request_kind} = request
         } = state,
         event
       )
       when request_kind in ["state_get", "state_set", "state_diff"] do
    try do
      case event do
        nil ->
          {:request, request, state}

        %{"id" => id, "kind" => "state_get", "result" => "ok", "text" => text} = ack
        when request_kind == "state_get" and id == request_id and map_size(ack) == 4 and
               (is_binary(text) or is_nil(text)) ->
          case State.decode(text, state["heap"]) do
            {:ok, value, heap} ->
              transition =
                state_constructed(request["stage_index"], value, %{
                  state_acknowledged(state)
                  | "heap" => heap
                })

              {:observed, transition, [{:state_read, request_id, value, text}]}

            {:error, reason} ->
              fail(reason)
          end

        %{"id" => id, "kind" => "state_set", "result" => "ok"} = ack
        when request_kind == "state_set" and id == request_id and map_size(ack) == 3 ->
          transition =
            state_constructed(request["stage_index"], request["value"], state_acknowledged(state))

          {:observed, transition,
           [{:state_written, request_id, request["value"], request["text"]}]}

        %{
          "id" => id,
          "kind" => "state_diff",
          "result" => "ok",
          "before_text" => text,
          "changed" => changed
        } = ack
        when request_kind == "state_diff" and id == request_id and map_size(ack) == 5 and
               (is_binary(text) or is_nil(text)) and is_boolean(changed) ->
          case State.diff(text, request["value"], state["heap"]) do
            {:ok, before, ^changed, heap} ->
              next = %{state_acknowledged(state) | "heap" => heap}
              {key, next} = record_value(request["key"], next)

              {value, next} =
                object(
                  [
                    {"kind", string("diff.last")},
                    {"key", key},
                    {"changed", %{"type" => "boolean", "value" => changed}},
                    {"before", before},
                    {"after", request["value"]}
                  ],
                  next
                )

              state_constructed(request["stage_index"], value, next)

            {:ok, _before, _changed, _heap} ->
              fail(:unexpected_state_acknowledgement)

            {:error, reason} ->
              fail(reason)
          end

        _ ->
          fail(:unexpected_state_acknowledgement)
      end
    catch
      :throw, {:workflow_machine, reason} -> {:error, reason, state}
    end
  end

  defp advance_transition(
         %{
           "phase" => "request",
           "pending_request" => %{"id" => request_id, "kind" => "sort_items"} = request
         } = state,
         event
       ) do
    case event do
      nil ->
        {:request, request, state}

      %{"id" => id, "kind" => "sort_items", "result" => "ok", "indices" => indices} = ack
      when id == request_id and map_size(ack) == 4 ->
        items = frame(state, request["stage_index"])["locals"]["items"]

        if sort_permutation?(indices, length(items)) do
          originals = List.to_tuple(items)
          items = Enum.map(indices, &elem(originals, &1))

          next =
            state
            |> Map.put("phase", state["request_phase"])
            |> Map.put("pending_request", nil)
            |> Map.delete("request_phase")

          sort_constructed(request["stage_index"], items, next)
        else
          {:error, :unexpected_sort_acknowledgement, state}
        end

      _ ->
        {:error, :unexpected_sort_acknowledgement, state}
    end
  end

  defp advance_transition(
         %{
           "phase" => "request",
           "pending_request" => %{"kind" => "invoke", "id" => request_id} = request
         } = state,
         event
       ) do
    case event do
      nil ->
        {:request, request, state}

      %{"id" => id, "response_json" => raw} when id == request_id and is_binary(raw) ->
        try do
          {response, next} = invoke_decode(if(raw == "", do: "null", else: raw), state)
          items = response |> invoke_result(next["heap"]) |> invoke_items(next["heap"])

          next =
            update_frame(next, request["stage_index"], fn frame ->
              put_in(frame, ["locals", "items"], frame["locals"]["items"] ++ items)
            end)

          {:continue,
           next
           |> Map.put("phase", next["request_phase"])
           |> Map.put("pending_request", nil)
           |> Map.delete("request_phase")}
        catch
          :throw, {:workflow_machine, reason} -> {:error, reason, state}
        end

      _ ->
        {:error, :unexpected_invoke_acknowledgement, state}
    end
  end

  defp advance_transition(
         %{
           "phase" => "request",
           "pending_request" => %{"id" => request_id, "kind" => request_kind} = request
         } = state,
         event
       )
       when request_kind in ["read_template_file", "render_template"] do
    case event do
      nil ->
        {:request, request, state}

      %{"id" => id, "kind" => kind, "result" => "ok", "value" => value}
      when id == request_id and kind == request_kind ->
        if canonical_string?(value) do
          try do
            next =
              state
              |> Map.put("phase", state["request_phase"])
              |> Map.put("pending_request", nil)
              |> Map.delete("request_phase")

            if request_kind == "read_template_file",
              do: template_constructed(request["stage_index"], value, next),
              else: emit_item(request["stream"], value, next)
          catch
            :throw, {:workflow_machine, reason} -> {:error, reason, state}
          end
        else
          {:error, :unexpected_template_acknowledgement, state}
        end

      _ ->
        {:error, :unexpected_template_acknowledgement, state}
    end
  end

  defp advance_transition(
         %{
           "phase" => "request",
           "pending_request" => %{"id" => request_id, "kind" => kind} = request
         } = state,
         event
       )
       when kind in ["compile_schema", "validate_response"] do
    case event do
      nil ->
        {:request, request, state}

      %{"id" => id, "result" => "ok"} when id == request_id ->
        {:continue,
         state
         |> Map.put("phase", state["request_phase"])
         |> Map.put("pending_request", nil)
         |> Map.delete("request_phase")}

      _ ->
        {:error, :unexpected_schema_acknowledgement, state}
    end
  end

  defp advance_transition(%{"phase" => "checkpoint"} = state, nil),
    do: {:checkpoint, state["checkpoint"], state}

  defp advance_transition(%{"phase" => "completed"} = state, nil),
    do: {:complete, result(state), state}

  defp advance_transition(state, nil) do
    try do
      [task | stack] = state["stack"]
      step(task, %{state | "stack" => stack})
    catch
      :throw, {:workflow_machine, reason} -> {:error, reason, state}
    end
  end

  defp advance_transition(state, _event), do: {:error, :unexpected_event, state}

  @doc "Starts a fresh semantic segment, validating the saved response before construction."
  def resume(state, response) do
    {result, _observations} = resume_observed(state, response)
    result
  end

  @doc "Resumes once while keeping volatile observations outside the saved segment."
  def resume_observed(state, response), do: {resume_transition(state, response), []}

  defp resume_transition(%{"phase" => "checkpoint", "checkpoint" => checkpoint} = old, response) do
    try do
      index = checkpoint["stage_index"]
      same? = checkpoint["mode"] == "same_stage"
      program = Enum.drop(old["program"], if(same?, do: index, else: index + 1))
      items = if same?, do: checkpoint["replay_items"], else: [response]

      {:ok, state} =
        new(program, %{"kind" => "array", "items" => items}, old["heap"], old["options"])

      request = checkpoint["request"]
      schema = Value.object_get(request, "responseSchema", state["heap"])
      command_input = checkpoint["command_input"]

      metadata_tasks =
        if same? do
          [command_input["pending"] | command_input["history"]]
          |> Enum.map(fn entry ->
            schema_task(entry["metadata"]["responseSchema"], "resume_metadata")
          end)
        else
          []
        end

      resume_input =
        if same?,
          do: %{"state" => command_input, "response" => response, "consumed" => false},
          else: nil

      state =
        state
        |> Map.put("next_request", old["next_request"])
        |> Map.put("segment", old["segment"] + 1)
        |> Map.put("resume_input", resume_input)
        |> Map.put(
          "stack",
          metadata_tasks ++ validation_tasks(schema, response, "saved_response") ++ state["stack"]
        )

      {:ok, state}
    catch
      :throw, {:workflow_machine, reason} -> {:error, reason}
    end
  end

  defp resume_transition(_state, _response), do: {:error, :not_at_checkpoint}

  defp step(%{"op" => "construct"}, state) do
    index = state["stage_index"]

    if index == length(state["program"]) do
      state = %{state | "phase" => "collect"}

      continue(
        push(state, [%{"op" => "drain", "stream" => state["current_stream"], "target" => "final"}])
      )
    else
      stage = Enum.at(state["program"], index)
      input = state["current_stream"]
      source = stream(state, input)

      tracker =
        transform("tracker", input, nil)
        |> Map.merge(%{
          "known_items" => if(source["kind"] == "array", do: source["items"], else: nil),
          "replay_items" => [],
          "replay_index" => 0,
          "replay_bytes" => 0,
          "replay_error" => nil,
          "replay_enabled" => true,
          "acquired" => false
        })

      {tracker_id, state} = add_stream(state, tracker)

      frame = %{
        "name" => stage["name"],
        "args" => stage["args"],
        "input" => input,
        "tracker" => tracker_id,
        "output" => nil,
        "status" => "constructing",
        "command_active" => true,
        "output_started" => false,
        "request_history" => [],
        "request_index" => 0,
        "locals" => %{}
      }

      state = %{state | "frames" => state["frames"] ++ [frame]}
      construct(stage["name"], index, state)
    end
  end

  defp step(%{"op" => "schema"} = task, state) do
    request = %{
      "id" => "schema:" <> Integer.to_string(state["next_request"]),
      "kind" => task["kind"],
      "schema" => task["schema"],
      "boundary" => task["boundary"]
    }

    request =
      if task["kind"] == "validate_response",
        do: Map.put(request, "response", task["response"]),
        else: request

    state =
      state
      |> Map.put("next_request", state["next_request"] + 1)
      |> Map.put("pending_request", request)
      |> Map.put("request_phase", state["phase"])
      |> Map.put("phase", "request")

    {:request, request, state}
  end

  defp step(%{"op" => "pull", "stream" => id}, state), do: pull(id, state)

  defp step(%{"op" => "after_pull", "stream" => id}, state) do
    node = stream(state, id)
    signal = state["signal"]

    if signal["done"] do
      state = put_stream(state, id, %{node | "completed" => true})
      continue(push(state, finish_tasks(node)))
    else
      after_item(id, node, signal["value"], state)
    end
  end

  defp step(%{"op" => "return", "stream" => id}, state) do
    node = stream(state, id)

    if node["completed"] or node["returned"] do
      continue(state)
    else
      state = put_stream(state, id, %{node | "returned" => true})

      tasks =
        if node["started"] do
          upstream =
            if node["kind"] == "transform" and node["acquired"],
              do: [%{"op" => "return", "stream" => node["upstream"]}],
              else: []

          upstream ++ finish_tasks(node)
        else
          []
        end

      continue(push(state, tasks))
    end
  end

  defp step(%{"op" => "finish", "index" => index}, state) do
    frame = frame(state, index)

    if frame["status"] == "finished" do
      continue(state)
    else
      state =
        update_frame(
          state,
          index,
          &Map.merge(&1, %{"status" => "finished", "command_active" => false})
        )

      tracker = stream(state, frame["tracker"])
      state = put_stream(state, frame["tracker"], Map.put(tracker, "replay_enabled", false))

      tasks =
        if tracker["started"] and not tracker["completed"],
          do: [%{"op" => "return", "stream" => frame["tracker"]}],
          else: []

      continue(push(state, tasks))
    end
  end

  defp step(%{"op" => "done_signal"}, state),
    do: continue(%{state | "signal" => %{"done" => true}})

  defp step(%{"op" => "drain"} = task, state) do
    continue(
      push(state, [
        %{"op" => "pull", "stream" => task["stream"]},
        Map.put(task, "op", "drain_item")
      ])
    )
  end

  defp step(%{"op" => "drain_item", "target" => target} = task, state) do
    if state["signal"]["done"] do
      drained(target, task, state)
    else
      value = state["signal"]["value"]

      state =
        cond do
          target == "groupBy" ->
            group_item(task["index"], value, state)

          target == "final" ->
            %{state | "items" => state["items"] ++ [value]}

          target in ["checkpoint", "invoke"] ->
            state

          true ->
            update_frame(state, task["index"], fn frame ->
              put_in(frame, ["locals", "items"], frame["locals"]["items"] ++ [value])
            end)
        end

      continue(push(state, [Map.put(task, "op", "drain")]))
    end
  end

  defp step(%{"op" => "table_item", "index" => index, "cursor" => cursor} = task, state) do
    items = frame(state, index)["locals"]["items"]

    if cursor == length(items) do
      table_rendered(index, state)
    else
      line = items |> Enum.at(cursor) |> table_cell_units(state["heap"])

      state =
        state
        |> append_stdout_units(line <> <<10, 0>>)
        |> Map.put("pipeline_output_started", true)

      continue(push(state, [Map.put(task, "cursor", cursor + 1)]))
    end
  end

  defp step(%{"op" => "invoke_item", "index" => index}, state) do
    frame = frame(state, index)

    if state["signal"]["done"] do
      invoke_constructed(index, state)
    else
      locals = frame["locals"]

      entries =
        locals["tool_args"]
        |> Value.object_keys(state["heap"])
        |> Enum.map(&{&1, Value.object_get(locals["tool_args"], &1, state["heap"])})

      # Object spread copies the container, retaining nested aliases. Replacing
      # the item field keeps its existing insertion position in the new object.
      {args, state} = object(entries ++ [{locals["item_key"], state["signal"]["value"]}], state)
      state = push(state, invoke_pull_tasks(index, frame["tracker"]))
      transition = invoke_request(index, args, state)
      {:observed, transition, [{:copy_mark, locals["tool_args"], args}]}
    end
  end

  defp step(%{"op" => "invoke_complete", "index" => index}, state),
    do: invoke_constructed(index, state)

  defp step(%{"op" => "ask_after_compile", "index" => index}, state) do
    frame = frame(state, index)
    restored = restored_state(state, index)

    if restored do
      {restored, state} = snapshot(restored, state)
      subject = Value.object_get(restored, "subject", state["heap"])
      state = update_frame(state, index, &put_in(&1, ["locals", "subject"], subject))
      continue(push(state, [%{"op" => "ask_preview", "index" => index}]))
    else
      continue(
        push(state, [
          %{"op" => "drain", "stream" => frame["tracker"], "target" => "ask", "index" => index}
        ])
      )
    end
  end

  defp step(%{"op" => "ask_preview", "index" => index}, state) do
    frame = frame(state, index)
    locals = frame["locals"]

    state =
      if locals["subject_from_stdin"] and locals["items"] != [] do
        text = preview(locals["items"], state["heap"])
        {subject, state} = object([{"text", text}], state)
        update_frame(state, index, &put_in(&1, ["locals", "subject"], subject))
      else
        state
      end

    if locals["emit"] do
      continue(
        push(state, [%{"op" => "ask_checkpoint", "index" => index, "mode" => "next_stage"}])
      )
    else
      if locals["prompt"] == "", do: fail(:request_input_prompt_required)

      continue(
        push(state, [
          schema_task(locals["schema"], "request_metadata"),
          %{"op" => "ask_metadata", "index" => index}
        ])
      )
    end
  end

  defp step(%{"op" => "ask_metadata", "index" => index}, state) do
    locals = frame(state, index)["locals"]
    {schema, state} = snapshot(locals["schema"], state)
    {subject, state} = optional_snapshot(locals["subject"], state)
    metadata = %{"prompt" => locals["prompt"], "responseSchema" => schema}
    metadata = optional_put(metadata, "subject", subject)
    {unsigned, state} = record_value(metadata, state)
    {:ok, signature} = JSON.stable_stringify(unsigned, state["heap"])
    metadata = Map.put(metadata, "signature", signature)

    {suspended, state} =
      object(optional_entries([{"type", string("ask")}], "subject", locals["subject"]), state)

    {suspended, state} = snapshot(suspended, state)

    state =
      update_frame(
        state,
        index,
        &Map.update!(&1, "locals", fn locals ->
          Map.merge(locals, %{"metadata" => metadata, "suspended" => suspended})
        end)
      )

    if index == 0 and state["resume_input"] do
      resume_input = state["resume_input"]
      history = resume_input["state"]["history"]
      requested = frame(state, index)["request_index"]
      historical = Enum.at(history, requested)
      stored = historical || resume_input["state"]["pending"]
      assert_match(stored, requested, metadata, suspended, state)

      {response, state} =
        snapshot(
          if(historical, do: historical["response"], else: resume_input["response"]),
          state
        )

      state =
        update_frame(
          state,
          index,
          &Map.update!(&1, "locals", fn locals ->
            Map.merge(locals, %{"response" => response, "historical" => not is_nil(historical)})
          end)
        )

      continue(
        push(
          state,
          validation_tasks(schema, response, "request_response") ++
            [%{"op" => "ask_response", "index" => index}]
        )
      )
    else
      continue(
        push(state, [%{"op" => "ask_checkpoint", "index" => index, "mode" => "same_stage"}])
      )
    end
  end

  defp step(%{"op" => "ask_response", "index" => index}, state) do
    frame = frame(state, index)
    locals = frame["locals"]
    {history_response, state} = snapshot(locals["response"], state)

    entry = %{
      "requestIndex" => frame["request_index"],
      "metadata" => locals["metadata"],
      "suspendedState" => locals["suspended"],
      "response" => history_response
    }

    state =
      update_frame(state, index, fn frame ->
        history =
          if locals["historical"],
            do: frame["request_history"],
            else: frame["request_history"] ++ [entry]

        %{frame | "request_history" => history, "request_index" => frame["request_index"] + 1}
      end)

    state =
      if locals["historical"], do: state, else: put_in(state, ["resume_input", "consumed"], true)

    {output, state} =
      add_stream(state, Map.put(buffered("iterator_items", [locals["response"]]), "owner", index))

    constructed(index, output, state)
  end

  defp step(%{"op" => "ask_checkpoint", "index" => index, "mode" => mode}, state) do
    frame = frame(state, index)
    locals = frame["locals"]
    same? = mode == "same_stage"

    if same? and (frame["output_started"] or state["pipeline_output_started"]),
      do: fail("requestInput cannot suspend after this command has produced output")

    if same? and length(frame["request_history"]) >= 100,
      do: fail("requestInput replay history limit exceeded")

    {replay, state} = if same?, do: replay_items(frame["tracker"], state), else: {[], state}

    command_input = %{
      "pending" => %{
        "requestIndex" => frame["request_index"],
        "metadata" => locals["metadata"],
        "suspendedState" => locals["suspended"]
      },
      "history" => frame["request_history"]
    }

    request = %{
      "type" => "input_request",
      "prompt" => locals["prompt"],
      "responseSchema" =>
        if(same?, do: locals["metadata"]["responseSchema"], else: locals["schema"]),
      "items" => if(same?, do: replay, else: locals["items"])
    }

    request =
      optional_put(
        request,
        "subject",
        if(same?, do: locals["metadata"]["subject"], else: locals["subject"])
      )

    request = if same?, do: Map.put(request, "commandInput", command_input), else: request
    {request, state} = record_value(request, state)
    output_node = buffered("iterator_items", [request])
    output_node = if same?, do: output_node, else: Map.put(output_node, "owner", index)
    {output, state} = add_stream(state, output_node)
    state = update_frame(state, index, &Map.put(&1, "output", output))

    checkpoint = %{
      "mode" => mode,
      "stage_index" => index,
      "request" => request,
      "replay_items" => replay,
      "halted_at" => %{"index" => index, "name" => "ask", "in_place" => same?}
    }

    checkpoint =
      if same?, do: Map.put(checkpoint, "command_input", command_input), else: checkpoint

    state = Map.put(state, "checkpoint", checkpoint)
    tasks = if same?, do: [%{"op" => "finish", "index" => index}], else: []

    continue(
      push(state, tasks ++ [%{"op" => "drain", "stream" => output, "target" => "checkpoint"}])
    )
  end

  defp step(%{"op" => "publish_checkpoint"}, state) do
    state = %{state | "phase" => "checkpoint", "stack" => []}
    {:checkpoint, state["checkpoint"], state}
  end

  defp after_item(id, %{"op" => "where"} = node, value, state) do
    left = where_path(value, node["path"], state["heap"])

    if where_compare(left, node["operator"], node["right"], state["heap"]) do
      emit_item(id, value, state)
    else
      continue(push(state, [%{"op" => "pull", "stream" => id}]))
    end
  end

  defp after_item(id, %{"op" => "dedupe"} = node, value, state) do
    signature =
      value |> collection_key(node["key"], state["heap"]) |> json_identity(state["heap"])

    if signature in node["seen"] do
      # A duplicate consumes upstream demand, but produces no output or cursor.
      continue(push(state, [%{"op" => "pull", "stream" => id}]))
    else
      state = put_stream(state, id, %{node | "seen" => node["seen"] ++ [signature]})
      emit_item(id, value, state)
    end
  end

  defp after_item(id, %{"op" => "template"} = node, value, state) do
    compute_request(
      "template:",
      %{
        "kind" => "render_template",
        "template" => node["template"],
        "item" => value,
        "stream" => id,
        "stage_index" => node["owner"]
      },
      state
    )
  end

  defp after_item(id, node, value, state) do
    {value, state} = project(node, value, state)
    emit_item(id, value, state)
  end

  defp emit_item(id, value, state) do
    node = stream(state, id)
    node = %{node | "post_yield" => true, "cursor" => node["cursor"] + 1}
    state = put_stream(state, id, node)

    state =
      if is_integer(node["owner"]),
        do: update_frame(state, node["owner"], &Map.put(&1, "output_started", true)),
        else: state

    continue(%{state | "signal" => %{"done" => false, "value" => value}})
  end

  defp construct("head", index, state) do
    frame = frame(state, index)
    limit = number(Map.get(frame["args"], "n", 10))
    if limit < 0, do: fail(:head_requires_nonnegative_number)

    node =
      transform("head", frame["tracker"], index) |> Map.merge(%{"limit" => limit, "count" => 0})

    {output, state} = add_stream(state, node)
    constructed(index, output, state)
  end

  defp construct("pick", index, state) do
    frame = frame(state, index)
    spec = List.first(frame["args"]["_"] || [])
    if not is_binary(spec) or spec == "", do: fail(:pick_requires_fields)
    fields = spec |> String.split(",") |> Enum.map(&trim/1) |> Enum.reject(&(&1 == ""))

    {output, state} =
      add_stream(state, Map.put(transform("pick", frame["tracker"], index), "fields", fields))

    constructed(index, output, state)
  end

  defp construct("map", index, state) do
    frame = frame(state, index)
    wrap = if is_binary(frame["args"]["wrap"]), do: frame["args"]["wrap"], else: nil
    unwrap = if is_binary(frame["args"]["unwrap"]), do: frame["args"]["unwrap"], else: nil
    if truthy?(wrap) and truthy?(unwrap), do: fail("map cannot use both --wrap and --unwrap")

    assignments =
      if is_list(frame["args"]["_"]) do
        Enum.flat_map(frame["args"]["_"], fn token ->
          case String.split(argument_string(token, state["heap"]), "=", parts: 2) do
            [key, value] ->
              case trim(key) do
                "" -> []
                key -> [%{"key" => key, "value" => value}]
              end

            _ ->
              []
          end
        end)
      else
        []
      end

    node =
      transform("map", frame["tracker"], index)
      |> Map.merge(%{"wrap" => wrap, "unwrap" => unwrap, "assignments" => assignments})

    {output, state} = add_stream(state, node)
    constructed(index, output, state)
  end

  defp construct("template", index, state) do
    args = frame(state, index)["args"]
    text = if is_binary(args["text"]), do: args["text"], else: ""
    file = if is_binary(args["file"]), do: args["file"], else: ""

    if text == "" and file != "" do
      compute_request(
        "template-file:",
        %{"kind" => "read_template_file", "file" => file, "stage_index" => index},
        state
      )
    else
      template_constructed(index, string(text), state)
    end
  end

  defp construct("where", index, state) do
    frame = frame(state, index)
    expression = List.first(frame["args"]["_"] || [])

    if not is_binary(expression) or expression == "",
      do: fail("where requires an expression (e.g. field=value)")

    case Regex.run(@where_predicate, expression) do
      [_, path, operator, raw] ->
        right =
          case raw do
            "true" ->
              %{"type" => "boolean", "value" => true}

            "false" ->
              %{"type" => "boolean", "value" => false}

            "null" ->
              %{"type" => "null"}

            _ ->
              numeric = where_number(string(raw))
              if where_nan?(numeric) or trim(raw) == "", do: string(raw), else: numeric
          end

        node =
          transform("where", frame["tracker"], index)
          |> Map.merge(%{
            "path" => String.split(path, "."),
            "operator" => if(operator == "=", do: "==", else: operator),
            "right" => right
          })

        {output, state} = add_stream(state, node)
        constructed(index, output, state)

      _ ->
        fail("Invalid where expression: " <> expression)
    end
  end

  defp construct("sort", index, state) do
    frame = frame(state, index)

    locals = %{
      "key" => optional_key(frame["args"]),
      "desc" => truthy?(frame["args"]["desc"]),
      "items" => []
    }

    state = update_frame(state, index, &Map.put(&1, "locals", locals))

    continue(
      push(state, [
        %{"op" => "drain", "stream" => frame["tracker"], "target" => "sort", "index" => index}
      ])
    )
  end

  defp construct("dedupe", index, state) do
    frame = frame(state, index)

    node =
      transform("dedupe", frame["tracker"], index)
      |> Map.merge(%{"key" => optional_key(frame["args"]), "seen" => []})

    {output, state} = add_stream(state, node)
    constructed(index, output, state)
  end

  defp construct("groupBy", index, state) do
    frame = frame(state, index)
    key = frame["args"]["key"] |> argument_string(state["heap"]) |> trim()
    if key == "", do: fail("groupBy requires --key")

    state =
      update_frame(state, index, &Map.put(&1, "locals", %{"key_path" => key, "groups" => []}))

    continue(
      push(state, [
        %{"op" => "drain", "stream" => frame["tracker"], "target" => "groupBy", "index" => index}
      ])
    )
  end

  defp construct("json", index, state) do
    frame = frame(state, index)

    if Map.get(state["options"], "render_output", false) == false do
      {output, state} = add_stream(state, transform("identity", frame["tracker"], index))
      constructed(index, output, state)
    else
      state = update_frame(state, index, &put_in(&1, ["locals", "items"], []))

      continue(
        push(state, [
          %{"op" => "drain", "stream" => frame["tracker"], "target" => "render", "index" => index}
        ])
      )
    end
  end

  defp construct("table", index, state) do
    frame = frame(state, index)

    if Map.get(state["options"], "render_output", false) == false do
      {output, state} = add_stream(state, transform("identity", frame["tracker"], index))
      constructed(index, output, state)
    else
      state = update_frame(state, index, &put_in(&1, ["locals", "items"], []))

      continue(
        push(state, [
          %{"op" => "drain", "stream" => frame["tracker"], "target" => "table", "index" => index}
        ])
      )
    end
  end

  defp construct(name, index, state) when name in ["state.get", "state.set", "diff.last"] do
    frame = frame(state, index)
    args = frame["args"]
    positional = List.first(args["_"] || [])
    key = if name == "diff.last" and not is_nil(args["key"]), do: args["key"], else: positional

    if not truthy?(key) do
      fail(
        if(name == "diff.last", do: "diff.last requires --key", else: name <> " requires a key")
      )
    end

    if name == "state.get" do
      compute_request(
        "state:",
        %{"kind" => "state_get", "key" => key, "stage_index" => index},
        state
      )
    else
      state = update_frame(state, index, &Map.put(&1, "locals", %{"key" => key, "items" => []}))

      continue(
        push(state, [
          %{"op" => "drain", "stream" => frame["tracker"], "target" => "state", "index" => index}
        ])
      )
    end
  end

  defp construct("ask", index, state) do
    frame = frame(state, index)
    args = frame["args"]

    raw =
      if is_binary(args["schema"]) and args["schema"] != "",
        do: args["schema"],
        else: @default_schema

    {schema, state} =
      case Value.decode_json(raw, state["heap"]) do
        {:ok, %{"type" => "reference", "id" => id} = schema, heap} ->
          if heap["nodes"][id]["type"] != "object", do: fail(:ask_schema_must_be_object)
          {schema, %{state | "heap" => heap}}

        _ ->
          fail(:ask_schema_must_be_object)
      end

    subject_flag =
      if is_nil(args["subject-from-stdin"]),
        do: args["subjectFromStdin"],
        else: args["subject-from-stdin"]

    locals = %{
      "prompt" => if(is_binary(args["prompt"]), do: args["prompt"], else: "Input required"),
      "schema" => schema,
      "subject_from_stdin" => truthy?(subject_flag),
      "emit" => truthy?(args["emit"]),
      "subject" => Value.undefined(),
      "items" => []
    }

    history =
      if index == 0 and state["resume_input"],
        do: state["resume_input"]["state"]["history"],
        else: []

    state =
      update_frame(
        state,
        index,
        &Map.merge(&1, %{"locals" => locals, "request_history" => history})
      )

    continue(
      push(state, [
        schema_task(schema, "ask_constructor"),
        %{"op" => "ask_after_compile", "index" => index}
      ])
    )
  end

  defp construct(name, index, state) when name in ["openclaw.invoke", "clawd.invoke"] do
    frame = frame(state, index)
    args = frame["args"]
    each = truthy?(args["each"])

    if not truthy?(args["tool"]) or not truthy?(args["action"]),
      do: fail(:invoke_requires_tool_and_action)

    {tool_args, state} =
      if truthy?(args["args-json"]) do
        invoke_decode(argument_string(args["args-json"], state["heap"]), state)
      else
        object([], state)
      end

    if each and not table_object?(tool_args, state["heap"]),
      do: fail(:invoke_each_requires_object_args)

    locals = %{
      "tool_args" => tool_args,
      "item_key" =>
        argument_string(invoke_option(args, "itemKey", "item-key", "item"), state["heap"]),
      "items" => []
    }

    state = update_frame(state, index, &Map.put(&1, "locals", locals))

    tasks =
      if each,
        do: invoke_pull_tasks(index, frame["tracker"]),
        else: [
          %{"op" => "drain", "stream" => frame["tracker"], "target" => "invoke", "index" => index}
        ]

    continue(push(state, tasks))
  end

  defp construct(_name, _index, _state), do: fail(:unsupported_workflow_command)

  defp template_constructed(index, template, state) do
    frame = frame(state, index)

    template =
      if Value.to_utf16le(template) == "" do
        positional = frame["args"]["_"]

        text =
          if is_list(positional),
            do: positional |> Enum.map(&argument_string(&1, state["heap"])) |> Enum.join(" "),
            else: ""

        if text == "", do: fail("template requires --text or --file (or positional text)")
        string(text)
      else
        template
      end

    {output, state} =
      add_stream(
        state,
        Map.put(transform("template", frame["tracker"], index), "template", template)
      )

    constructed(index, output, state)
  end

  defp compute_request(prefix, request, state) do
    request = Map.put(request, "id", prefix <> Integer.to_string(state["next_request"]))

    state =
      state
      |> Map.put("next_request", state["next_request"] + 1)
      |> Map.put("pending_request", request)
      |> Map.put("request_phase", state["phase"])
      |> Map.put("phase", "request")

    {:request, request, state}
  end

  defp state_acknowledged(state) do
    state
    |> Map.put("phase", state["request_phase"])
    |> Map.put("pending_request", nil)
    |> Map.delete("request_phase")
  end

  defp state_constructed(index, value, state) do
    {output, state} =
      add_stream(state, Map.put(buffered("iterator_items", [value]), "owner", index))

    constructed(index, output, state)
  end

  defp constructed(index, output, state) do
    terminal? = index == length(state["program"]) - 1

    state =
      update_frame(
        state,
        index,
        &Map.merge(&1, %{
          "output" => output,
          "status" => "constructed",
          "command_active" => terminal?
        })
      )

    state = %{state | "current_stream" => output, "stage_index" => index + 1}
    continue(push(state, [%{"op" => "construct"}]))
  end

  defp pull(id, state) do
    node = stream(state, id)

    cond do
      node["completed"] or node["returned"] ->
        continue(%{state | "signal" => %{"done" => true}})

      node["kind"] in ["array", "iterator_items", "group_iterator"] ->
        node = %{node | "started" => true}

        if node["cursor"] == length(node["items"]) do
          state = put_stream(state, id, %{node | "completed" => true})
          continue(push(%{state | "signal" => %{"done" => true}}, finish_tasks(node)))
        else
          item = Enum.at(node["items"], node["cursor"])

          {value, state} =
            if node["kind"] == "group_iterator",
              do: group_wrapper(item, state),
              else: {item, state}

          state = put_stream(state, id, %{node | "cursor" => node["cursor"] + 1})

          state =
            if is_integer(node["owner"]),
              do: update_frame(state, node["owner"], &Map.put(&1, "output_started", true)),
              else: state

          continue(%{state | "signal" => %{"done" => false, "value" => value}})
        end

      node["op"] == "head" and node["post_yield"] ->
        count = node["count"] + 1
        node = %{node | "count" => count, "post_yield" => false}
        state = put_stream(state, id, node)

        if count >= node["limit"] do
          state = put_stream(state, id, %{node | "completed" => true})

          continue(
            push(
              state,
              [%{"op" => "return", "stream" => node["upstream"]}] ++
                finish_tasks(node) ++ [%{"op" => "done_signal"}]
            )
          )
        else
          continue(push(state, [%{"op" => "pull", "stream" => id}]))
        end

      node["op"] == "head" and node["limit"] == 0 ->
        node = %{node | "started" => true, "completed" => true}
        state = put_stream(state, id, node)
        continue(push(state, finish_tasks(node) ++ [%{"op" => "done_signal"}]))

      true ->
        node = Map.merge(node, %{"started" => true, "post_yield" => false, "acquired" => true})
        state = put_stream(state, id, node)

        continue(
          push(state, [
            %{"op" => "pull", "stream" => node["upstream"]},
            %{"op" => "after_pull", "stream" => id}
          ])
        )
    end
  end

  defp project(%{"op" => "tracker", "known_items" => items} = node, value, state)
       when is_list(items) do
    {node, state} = snapshot_known_item(node, state)
    {value, put_stream(state, node["id"], node)}
  end

  defp project(
         %{"op" => "pick", "fields" => fields},
         %{"type" => "reference", "id" => id} = value,
         state
       ) do
    node = state["heap"]["nodes"][id]
    entries = Enum.map(fields, &{&1, property(value, node, &1, state["heap"])})
    object(entries, state)
  end

  defp project(%{"op" => "map", "unwrap" => unwrap}, value, state)
       when is_binary(unwrap) and unwrap != "" do
    unwrapped =
      case value do
        %{"type" => "reference", "id" => id} ->
          property(value, state["heap"]["nodes"][id], unwrap, state["heap"])

        _ ->
          Value.undefined()
      end

    {unwrapped, state}
  end

  defp project(%{"op" => "map"} = node, value, state) do
    {current, state} =
      if truthy?(node["wrap"]), do: object([{node["wrap"], value}], state), else: {value, state}

    if node["assignments"] == [] do
      {current, state}
    else
      {current, state} =
        case current do
          %{"type" => "reference", "id" => id} ->
            if state["heap"]["nodes"][id]["type"] == "object",
              do: {current, state},
              else: object([{"value", current}], state)

          _ ->
            object([{"value", current}], state)
        end

      state =
        Enum.reduce(node["assignments"], state, fn assignment, state ->
          rendered = render_map_template(assignment["value"], value, state["heap"])
          heap = Value.object_put(current, assignment["key"], rendered, state["heap"])
          %{state | "heap" => heap}
        end)

      {current, state}
    end
  end

  defp project(_node, value, state), do: {value, state}

  defp render_map_template(template, item, heap) do
    {parts, cursor} =
      @map_template
      |> Regex.scan(template, return: :index)
      |> Enum.map_reduce(0, fn [{start, length}, {expression_start, expression_length}], cursor ->
        literal = template |> binary_part(cursor, start - cursor) |> utf16le()
        key = template |> binary_part(expression_start, expression_length) |> trim()
        value = if key in [".", "this"], do: item, else: get_by_path(item, key, heap)

        replacement =
          case value do
            %{"type" => type} when type in ["undefined", "null"] ->
              ""

            %{"type" => "string"} ->
              Value.to_utf16le(value)

            value ->
              case JSON.stringify(value, heap) do
                {:ok, text} -> utf16le(text)
                {:error, reason} -> fail(reason)
              end
          end

        {[literal, replacement], start + length}
      end)

    suffix = template |> binary_part(cursor, byte_size(template) - cursor) |> utf16le()
    [parts, suffix] |> IO.iodata_to_binary() |> Value.from_utf16le()
  end

  defp snapshot_known_item(node, state) do
    if node["replay_error"] do
      {node, state}
    else
      case JSON.snapshot(Enum.at(node["known_items"], node["replay_index"]), state["heap"]) do
        {:ok, copy, heap} ->
          {:ok, text} = JSON.stringify(copy, heap)
          bytes = node["replay_bytes"] + byte_size(text)
          node = %{node | "replay_bytes" => bytes}

          node =
            if length(node["replay_items"]) + 1 > 1000 or bytes > 1_048_576 do
              %{node | "replay_error" => "requestInput replay limit exceeded"}
            else
              %{
                node
                | "replay_items" => node["replay_items"] ++ [copy],
                  "replay_index" => node["replay_index"] + 1
              }
            end

          {node, %{state | "heap" => heap}}

        {:error, reason} ->
          # The reference records snapshot errors during iteration and reports
          # them only if this command actually requests replay.
          {%{node | "replay_error" => inspect(reason)}, state}
      end
    end
  end

  defp property(reference, %{"type" => "object"}, key, heap),
    do: Value.object_get(reference, key, heap)

  defp property(_reference, %{"type" => "array", "items" => items}, "length", _heap),
    do: tagged_number(length(items))

  defp property(_reference, %{"type" => "array", "items" => items}, key, _heap) do
    case Value.key_index(key) do
      index when is_integer(index) -> Enum.at(items, index, Value.undefined())
      _ -> Value.undefined()
    end
  end

  defp drained("final", _task, state) do
    state = %{state | "phase" => "completed"}
    {:complete, result(state), state}
  end

  defp drained("ask", task, state),
    do: continue(push(state, [%{"op" => "ask_preview", "index" => task["index"]}]))

  defp drained("checkpoint", _task, state),
    do: continue(push(state, [%{"op" => "publish_checkpoint"}]))

  defp drained("invoke", task, state) do
    index = task["index"]
    args = frame(state, index)["locals"]["tool_args"]
    invoke_request(index, args, push(state, [%{"op" => "invoke_complete", "index" => index}]))
  end

  defp drained("state", task, state) do
    index = task["index"]
    frame = frame(state, index)
    {value, heap} = State.cardinality(frame["locals"]["items"], state["heap"])

    case State.text(value, heap) do
      {:ok, text} ->
        compute_request(
          "state:",
          %{
            "kind" => if(frame["name"] == "state.set", do: "state_set", else: "state_diff"),
            "key" => frame["locals"]["key"],
            "value" => value,
            "text" => text,
            "stage_index" => index
          },
          %{state | "heap" => heap}
        )

      {:error, reason} ->
        fail(reason)
    end
  end

  defp drained("sort", task, state) do
    index = task["index"]
    locals = frame(state, index)["locals"]
    keys = Enum.map(locals["items"], &collection_key(&1, locals["key"], state["heap"]))

    if Enum.any?(keys, fn
         %{"type" => "number"} = value -> Number.classify(value) == :nan
         _ -> false
       end) do
      {keys, heap} = Value.array(keys, state["heap"])

      compute_request(
        "sort:",
        %{
          "kind" => "sort_items",
          "keys" => keys,
          "desc" => locals["desc"],
          "stage_index" => index
        },
        %{state | "heap" => heap}
      )
    else
      # The non-strict predicate keeps equal keys in their original order.
      items =
        Enum.sort(locals["items"], fn left, right ->
          left = collection_key(left, locals["key"], state["heap"])
          right = collection_key(right, locals["key"], state["heap"])
          comparison = compare_values(left, right, state["heap"])
          if locals["desc"], do: comparison >= 0, else: comparison <= 0
        end)

      sort_constructed(index, items, state)
    end
  end

  defp drained("groupBy", task, state) do
    index = task["index"]
    groups = frame(state, index)["locals"]["groups"]

    {output, state} =
      add_stream(state, Map.put(buffered("group_iterator", groups), "owner", index))

    constructed(index, output, state)
  end

  defp drained("render", task, state) do
    index = task["index"]
    items = frame(state, index)["locals"]["items"]
    {array, heap} = Value.array(items, state["heap"])

    text =
      case JSON.pretty(array, heap) do
        {:ok, text} -> text
        {:error, reason} -> fail(reason)
      end

    state = %{
      state
      | "heap" => heap,
        "rendered" => true,
        "rendered_items" => state["rendered_items"] ++ items,
        "pipeline_output_started" => true
    }

    state = append_stdout_units(state, utf16le(text <> "\n"))

    {output, state} = add_stream(state, Map.put(buffered("iterator_items", []), "owner", index))
    constructed(index, output, state)
  end

  defp drained("table", task, state) do
    index = task["index"]
    items = frame(state, index)["locals"]["items"]

    case table_lines(items, state["heap"]) do
      nil ->
        continue(push(state, [%{"op" => "table_item", "index" => index, "cursor" => 0}]))

      lines ->
        state =
          Enum.reduce(lines, state, fn line, state ->
            append_stdout_units(state, line <> <<10, 0>>)
          end)

        table_rendered(index, state)
    end
  end

  defp sort_constructed(index, items, state) do
    state = update_frame(state, index, &put_in(&1, ["locals", "items"], items))

    {output, state} =
      add_stream(state, Map.put(buffered("iterator_items", items), "owner", index))

    constructed(index, output, state)
  end

  defp sort_permutation?(indices, count) when is_list(indices) do
    length(indices) == count and
      Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < count)) and
      MapSet.size(MapSet.new(indices)) == count
  end

  defp sort_permutation?(_indices, _count), do: false

  defp table_rendered(index, state) do
    state = %{state | "rendered" => true, "pipeline_output_started" => true}
    {output, state} = add_stream(state, Map.put(buffered("iterator_items", []), "owner", index))
    constructed(index, output, state)
  end

  defp invoke_request(index, tool_args, state) do
    frame = frame(state, index)
    args = frame["args"]
    session_key = invoke_option(args, "sessionKey", "session-key", nil)
    dry_run = invoke_option(args, "dryRun", "dry-run", nil)

    entries = [
      {"tool", string(argument_string(args["tool"], state["heap"]))},
      {"action", string(argument_string(args["action"], state["heap"]))},
      {"args", tool_args}
    ]

    entries =
      if truthy?(session_key),
        do: entries ++ [{"sessionKey", string(argument_string(session_key, state["heap"]))}],
        else: entries

    entries =
      if is_nil(dry_run),
        do: entries,
        else: entries ++ [{"dryRun", %{"type" => "boolean", "value" => truthy?(dry_run)}}]

    {body, state} = object(entries, state)

    body =
      case JSON.stringify(body, state["heap"]) do
        {:ok, text} -> text
        {:error, reason} -> fail(reason)
      end

    request = %{
      "id" => "invoke:" <> Integer.to_string(state["next_request"]),
      "kind" => "invoke",
      "command" => frame["name"],
      "segment" => state["segment"],
      "stage_index" => index,
      "body" => body
    }

    state =
      state
      |> Map.put("next_request", state["next_request"] + 1)
      |> Map.put("pending_request", request)
      |> Map.put("request_phase", state["phase"])
      |> Map.put("phase", "request")

    {:request, request, state}
  end

  defp invoke_constructed(index, state) do
    items = frame(state, index)["locals"]["items"]

    {output, state} =
      add_stream(state, Map.put(buffered("iterator_items", items), "owner", index))

    constructed(index, output, state)
  end

  defp invoke_pull_tasks(index, tracker),
    do: [%{"op" => "pull", "stream" => tracker}, %{"op" => "invoke_item", "index" => index}]

  defp invoke_option(args, key, alias_key, default),
    do: Enum.find([args[key], args[alias_key], default], &(not is_nil(&1)))

  defp invoke_decode(raw, state) do
    case Value.decode_json(raw, state["heap"]) do
      {:ok, value, heap} -> {value, %{state | "heap" => heap}}
      {:error, reason} -> fail(reason)
    end
  end

  defp invoke_result(%{"type" => "reference", "id" => id} = value, heap) do
    case heap["nodes"][id] do
      %{"type" => "object", "fields" => %{"ok" => ok}} ->
        if ok != %{"type" => "boolean", "value" => true}, do: fail(:invoke_tool_error)
        Value.object_get(value, "result", heap)

      _ ->
        value
    end
  end

  defp invoke_result(value, _heap), do: value

  defp invoke_items(%{"type" => "reference", "id" => id} = value, heap) do
    case heap["nodes"][id] do
      %{"type" => "array", "items" => items} -> items
      _ -> [value]
    end
  end

  defp invoke_items(value, _heap), do: [value]

  defp table_lines([], _heap), do: [utf16le("(no results)")]

  defp table_lines(items, heap) do
    sample = Enum.take(items, 20)

    if Enum.all?(sample, &table_object?(&1, heap)) do
      columns =
        sample
        |> Enum.flat_map(&Value.object_keys(&1, heap))
        |> Enum.uniq()

      rows =
        [
          Enum.map(columns, &(&1 |> Value.key_string() |> Value.to_utf16le()))
          | Enum.map(items, fn item ->
              Enum.map(columns, fn column ->
                item |> path_property(column, heap) |> table_cell_units(heap)
              end)
            end)
        ]
        |> Enum.map(fn row -> Enum.map(row, &table_flatten_lf/1) end)

      widths =
        columns
        |> Enum.with_index()
        |> Enum.map(fn {_column, index} ->
          Enum.reduce(rows, 3, fn row, width ->
            max(width, row |> Enum.at(index) |> byte_size() |> div(2))
          end)
        end)

      [header | body] = Enum.map(rows, &table_row(&1, widths))

      [
        header,
        widths |> Enum.map(&:binary.copy(<<45, 0>>, &1)) |> Enum.join(<<32, 0, 32, 0>>) | body
      ]
    else
      # Fallback converts and writes one item per transition, retaining earlier
      # stdout if a later item's conversion cannot complete.
      nil
    end
  end

  defp table_object?(%{"type" => "reference", "id" => id}, heap),
    do: heap["nodes"][id]["type"] == "object"

  defp table_object?(_value, _heap), do: false

  defp table_cell_units(%{"type" => type}, _heap) when type in ["null", "undefined"], do: ""
  defp table_cell_units(%{"type" => "string"} = value, _heap), do: Value.to_utf16le(value)

  defp table_cell_units(%{"type" => type} = value, heap) when type in ["number", "boolean"],
    do: js_string_units(value, heap)

  defp table_cell_units(value, heap) do
    case JSON.stringify(value, heap) do
      {:ok, text} -> utf16le(text)
      {:error, reason} -> fail(reason)
    end
  end

  # Match whole code units: the LF bytes can also occur across two other units.
  defp table_flatten_lf(raw) do
    for <<unit::unsigned-little-16 <- raw>>, into: <<>> do
      <<if(unit == 10, do: 32, else: unit)::unsigned-little-16>>
    end
  end

  defp table_row(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map(fn {cell, width} ->
      cell <> :binary.copy(<<32, 0>>, width - div(byte_size(cell), 2))
    end)
    |> Enum.join(<<32, 0, 32, 0>>)
  end

  # Signatures preserve ordinary JSON property order. Undefined is a separate
  # JSON record, never confused with null or any serialized string.
  defp json_identity(value, heap) do
    case JSON.stringify(value, heap) do
      {:ok, :undefined} -> %{"kind" => "undefined"}
      {:ok, text} -> %{"kind" => "json", "text" => text}
      {:error, reason} -> fail(reason)
    end
  end

  defp group_item(index, value, state) do
    locals = frame(state, index)["locals"]
    key = get_by_path(value, locals["key_path"], state["heap"])
    signature = json_identity(key, state["heap"])
    position = Enum.find_index(locals["groups"], &(&1["signature"] == signature))

    {groups, state} =
      if is_nil(position) do
        {items, heap} = Value.array([value], state["heap"])
        group = %{"signature" => signature, "key" => key, "items" => items}
        {locals["groups"] ++ [group], %{state | "heap" => heap}}
      else
        group = Enum.at(locals["groups"], position)
        items = group["items"]
        members = Value.array_items(items, state["heap"])
        heap = put_in(state["heap"], ["nodes", items["id"], "items"], members ++ [value])
        {locals["groups"], %{state | "heap" => heap}}
      end

    update_frame(state, index, &put_in(&1, ["locals", "groups"], groups))
  end

  defp group_wrapper(group, state) do
    count = length(Value.array_items(group["items"], state["heap"]))

    object(
      [{"key", group["key"]}, {"items", group["items"]}, {"count", tagged_number(count)}],
      state
    )
  end

  defp optional_key(args), do: if(is_binary(args["key"]), do: args["key"], else: nil)

  defp collection_key(value, key, heap) when is_binary(key) and key != "",
    do: get_by_path(value, key, heap)

  defp collection_key(value, _key, _heap), do: value

  # where.js has a separate getPath: empty segments are significant and
  # primitives never acquire boxed string properties.
  defp where_path(value, parts, heap) do
    Enum.reduce(parts, value, fn
      key, %{"type" => "reference", "id" => id} = current ->
        property(current, heap["nodes"][id], key, heap)

      _key, _current ->
        Value.undefined()
    end)
  end

  defp where_compare(left, "==", right, heap), do: where_equal?(left, right, heap)
  defp where_compare(left, "!=", right, heap), do: not where_equal?(left, right, heap)

  defp where_compare(left, operator, right, heap) do
    left = where_primitive(left, heap)
    right = where_primitive(right, heap)

    comparison =
      if where_type(left) == "string" and where_type(right) == "string" do
        compare_string_units(Value.to_utf16le(left), Value.to_utf16le(right))
      else
        where_number_order(where_number(left), where_number(right))
      end

    case operator do
      "<" -> comparison == -1
      "<=" -> comparison in [-1, 0]
      ">" -> comparison == 1
      ">=" -> comparison in [0, 1]
    end
  end

  defp where_equal?(left, right, heap) do
    left_type = where_type(left)
    right_type = where_type(right)

    cond do
      nullish?(left) and nullish?(right) ->
        true

      left_type == "number" and right_type == "number" ->
        where_number_order(left, right) == 0

      left_type == right_type ->
        left == right

      left_type == "boolean" ->
        where_equal?(where_number(left), right, heap)

      right_type == "boolean" ->
        where_equal?(left, where_number(right), heap)

      left_type == "number" and right_type == "string" ->
        where_number_order(left, where_number(right)) == 0

      left_type == "string" and right_type == "number" ->
        where_number_order(where_number(left), right) == 0

      left_type == "reference" and right_type in ["number", "string"] ->
        where_equal?(where_primitive(left, heap), right, heap)

      right_type == "reference" and left_type in ["number", "string"] ->
        where_equal?(left, where_primitive(right, heap), heap)

      true ->
        false
    end
  end

  # In the current Value domain, default valueOf returns the object and every
  # representable own valueOf is non-callable. The next default toString uses
  # the existing object/array conversion, including its explicit hook boundary.
  defp where_primitive(%{"type" => "reference"} = value, heap),
    do: value |> js_string_units(heap) |> Value.from_utf16le()

  defp where_primitive(value, _heap), do: value

  defp where_type(value), do: value["type"]
  defp where_nan?(value), do: Number.classify(value) == :nan
  defp where_number(value), do: Number.coerce(value)
  defp where_number_order(left, right), do: Number.compare(left, right)

  defp get_by_path(value, path, heap) do
    path |> String.split(".", trim: true) |> Enum.reduce(value, &path_property(&2, &1, heap))
  end

  # Collection paths intentionally do not change pick's existing property rules.
  defp path_property(%{"type" => "reference", "id" => id} = value, key, heap),
    do: property(value, heap["nodes"][id], key, heap)

  defp path_property(%{"type" => "string"} = value, key, _heap) do
    utf16 = Value.to_utf16le(value)

    if key == "length" do
      tagged_number(div(byte_size(utf16), 2))
    else
      case canonical_index(key) do
        index when is_integer(index) and index < div(byte_size(utf16), 2) ->
          utf16 |> binary_part(index * 2, 2) |> Value.from_utf16le()

        _ ->
          Value.undefined()
      end
    end
  end

  defp path_property(_value, _key, _heap), do: Value.undefined()

  defp canonical_index(key), do: Value.key_index(key)

  defp compare_values(left, right, heap) do
    cond do
      nullish?(left) and nullish?(right) ->
        0

      nullish?(left) ->
        1

      nullish?(right) ->
        -1

      left["type"] == "number" and right["type"] == "number" ->
        case Number.compare(left, right) do
          :unordered -> 0
          comparison -> comparison
        end

      true ->
        compare_string_units(js_string_units(left, heap), js_string_units(right, heap))
    end
  end

  defp compare_order(left, right) when left < right, do: -1
  defp compare_order(left, right) when left > right, do: 1
  defp compare_order(_left, _right), do: 0
  defp nullish?(value), do: value["type"] in ["undefined", "null"]

  # Private string assembly uses exact LE units, never bare buffers in state.
  defp utf16le(text), do: :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

  defp compare_string_units(left, right),
    do: compare_order(string_order_key(left), string_order_key(right))

  defp string_order_key(raw) do
    for <<unit::unsigned-little-16 <- raw>>, into: <<>>, do: <<unit::unsigned-big-16>>
  end

  defp js_string_units(value, heap), do: js_string_units(value, heap, [])
  defp js_string_units(%{"type" => "undefined"}, _heap, _path), do: utf16le("undefined")
  defp js_string_units(%{"type" => "null"}, _heap, _path), do: utf16le("null")
  defp js_string_units(%{"type" => "string"} = value, _heap, _path), do: Value.to_utf16le(value)

  defp js_string_units(%{"type" => "number"} = value, _heap, _path),
    do: value |> Number.string() |> utf16le()

  defp js_string_units(%{"type" => "boolean"} = value, heap, _path) do
    case JSON.stringify(value, heap) do
      {:ok, text} -> utf16le(text)
      {:error, reason} -> fail(reason)
    end
  end

  defp js_string_units(%{"type" => "reference", "id" => id}, heap, path) do
    case heap["nodes"][id] do
      %{"type" => "object", "fields" => fields} ->
        # Own non-callable toString shadows the inherited conversion method.
        # Callable conversion hooks cannot be represented by this Value heap.
        if Map.has_key?(fields, "toString"), do: fail(:unsupported_object_string_conversion)
        utf16le("[object Object]")

      %{"type" => "array", "items" => items} ->
        if id in path do
          ""
        else
          items
          |> Enum.map(fn item ->
            if nullish?(item), do: "", else: js_string_units(item, heap, [id | path])
          end)
          |> Enum.join(<<44, 0>>)
        end
    end
  end

  # Node Writable encodes each complete write separately, after string assembly.
  defp append_stdout_units(state, raw) do
    text = raw |> stdout_utf8([]) |> Enum.reverse() |> IO.iodata_to_binary()
    %{state | "stdout" => state["stdout"] <> text}
  end

  defp stdout_utf8(<<>>, chunks), do: chunks

  defp stdout_utf8(<<high::unsigned-little-16, low::unsigned-little-16, rest::binary>>, chunks)
       when high in 0xD800..0xDBFF and low in 0xDC00..0xDFFF do
    scalar = 0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00
    stdout_utf8(rest, [<<scalar::utf8>> | chunks])
  end

  defp stdout_utf8(<<unit::unsigned-little-16, rest::binary>>, chunks)
       when unit in 0xD800..0xDFFF,
       do: stdout_utf8(rest, [<<0xFFFD::utf8>> | chunks])

  defp stdout_utf8(<<unit::unsigned-little-16, rest::binary>>, chunks),
    do: stdout_utf8(rest, [<<unit::utf8>> | chunks])

  defp argument_string(nil, _heap), do: ""
  defp argument_string(value, _heap) when is_binary(value), do: value
  defp argument_string(value, _heap) when is_boolean(value), do: Atom.to_string(value)

  defp argument_string(value, heap) when is_number(value) do
    {:ok, text} = JSON.stringify(tagged_number(value), heap)
    text
  end

  defp argument_string(values, heap) when is_list(values),
    do: values |> Enum.map(&argument_string(&1, heap)) |> Enum.join(",")

  defp argument_string(_value, _heap), do: "[object Object]"

  defp replay_items(tracker_id, state) do
    tracker = stream(state, tracker_id)

    if not tracker["replay_enabled"],
      do: fail("requestInput replay is no longer available after command output")

    if is_list(tracker["known_items"]) do
      remaining = Enum.drop(tracker["known_items"], tracker["replay_index"])

      {tracker, state} =
        Enum.reduce(remaining, {tracker, state}, fn _item, {tracker, state} ->
          snapshot_known_item(tracker, state)
        end)

      state = put_stream(state, tracker_id, tracker)
      if tracker["replay_error"], do: fail(tracker["replay_error"])
      copies = tracker["replay_items"]
      if length(copies) > 1000, do: fail("requestInput replay item limit exceeded")

      {copies, {state, _bytes}} =
        Enum.map_reduce(copies, {state, 0}, fn item, {state, bytes} ->
          {copy, state} = snapshot(item, state)
          {:ok, text} = JSON.stringify(copy, state["heap"])
          bytes = bytes + byte_size(text)
          if bytes > 1_048_576, do: fail("requestInput replay byte limit exceeded")
          {copy, {state, bytes}}
        end)

      {copies, state}
    else
      {[], state}
    end
  end

  defp restored_state(state, index) do
    if index == 0 and state["resume_input"] do
      resume_input = state["resume_input"]
      requested = frame(state, index)["request_index"]

      stored =
        Enum.at(resume_input["state"]["history"], requested) || resume_input["state"]["pending"]

      suspended = stored["suspendedState"]

      if suspended && Value.object_get(suspended, "type", state["heap"]) == string("ask"),
        do: suspended,
        else: nil
    end
  end

  defp assert_match(stored, index, metadata, suspended, state) do
    if stored["requestIndex"] != index or stored["metadata"]["prompt"] != metadata["prompt"] or
         stored["metadata"]["signature"] != metadata["signature"],
       do: fail(:request_input_resume_mismatch)

    if JSON.stable_stringify(stored["suspendedState"], state["heap"]) !=
         JSON.stable_stringify(suspended, state["heap"]),
       do: fail(:request_input_state_mismatch)
  end

  defp preview(items, heap) do
    raw =
      items
      |> Enum.map(fn
        %{"type" => "string"} = value ->
          Value.to_utf16le(value)

        item ->
          case JSON.stringify(item, heap) do
            {:ok, :undefined} -> ""
            {:ok, text} -> utf16le(text)
            {:error, reason} -> fail(reason)
          end
      end)
      |> Enum.join(<<10, 0>>)

    raw |> binary_part(0, min(byte_size(raw), 4000)) |> Value.from_utf16le()
  end

  defp number(value) do
    case value |> Number.from_native() |> Number.finite() do
      {:ok, number} -> number
      :nonfinite -> fail(:head_requires_finite_number)
    end
  end

  defp tagged_number(value), do: Number.from_native(value)

  defp trim(value), do: Regex.replace(@edge_whitespace, value, "")
  defp truthy?(%{"type" => "number"} = value), do: Number.truthy?(value)
  defp truthy?(value), do: value not in [nil, false, "", 0, 0.0]
  defp string(value), do: %{"type" => "string", "value" => value}

  defp canonical_string?(%{"type" => "string", "value" => text} = value)
       when map_size(value) == 2 and is_binary(text),
       do: String.valid?(text)

  defp canonical_string?(%{"type" => "string", "utf16le" => encoded} = value)
       when map_size(value) == 2 and is_binary(encoded) do
    with {:ok, raw} <- Base.decode64(encoded),
         true <- Base.encode64(raw) == encoded and rem(byte_size(raw), 2) == 0 do
      Value.from_utf16le(raw) == value
    else
      _ -> false
    end
  end

  defp canonical_string?(_), do: false

  defp buffered(kind, items),
    do: %{
      "kind" => kind,
      "items" => items,
      "cursor" => 0,
      "started" => false,
      "completed" => false,
      "returned" => false
    }

  defp transform(op, upstream, owner) do
    %{
      "kind" => "transform",
      "op" => op,
      "upstream" => upstream,
      "owner" => owner,
      "cursor" => 0,
      "started" => false,
      "completed" => false,
      "returned" => false,
      "post_yield" => false,
      "acquired" => false
    }
  end

  defp schema_task(schema, boundary),
    do: %{
      "op" => "schema",
      "kind" => "compile_schema",
      "schema" => schema,
      "boundary" => boundary
    }

  defp validation_tasks(schema, response, boundary),
    do: [
      schema_task(schema, boundary),
      %{
        "op" => "schema",
        "kind" => "validate_response",
        "schema" => schema,
        "response" => response,
        "boundary" => boundary
      }
    ]

  defp finish_tasks(%{"owner" => owner}) when is_integer(owner),
    do: [%{"op" => "finish", "index" => owner}]

  defp finish_tasks(_node), do: []

  defp add_stream(state, node) do
    id = "s" <> Integer.to_string(state["next_stream"])

    {id,
     %{
       state
       | "next_stream" => state["next_stream"] + 1,
         "streams" => Map.put(state["streams"], id, Map.put(node, "id", id))
     }}
  end

  defp stream(state, id), do: Map.fetch!(state["streams"], id)

  defp put_stream(state, id, node),
    do: %{state | "streams" => Map.put(state["streams"], id, node)}

  defp frame(state, index), do: Enum.at(state["frames"], index)

  defp update_frame(state, index, fun),
    do: %{state | "frames" => List.update_at(state["frames"], index, fun)}

  defp push(state, tasks), do: %{state | "stack" => tasks ++ state["stack"]}
  defp continue(state), do: {:continue, state}
  defp fail(reason), do: throw({:workflow_machine, reason})
  defp result(state), do: Map.take(state, ["items", "rendered", "rendered_items", "stdout"])

  defp snapshot(value, state) do
    case JSON.snapshot(value, state["heap"]) do
      {:ok, copy, heap} -> {copy, %{state | "heap" => heap}}
      {:error, reason} -> fail(reason)
    end
  end

  defp optional_snapshot(%{"type" => "undefined"} = value, state), do: {value, state}
  defp optional_snapshot(value, state), do: snapshot(value, state)
  defp optional_put(map, _key, nil), do: map
  defp optional_put(map, _key, %{"type" => "undefined"}), do: map
  defp optional_put(map, key, value), do: Map.put(map, key, value)
  defp optional_entries(entries, _key, %{"type" => "undefined"}), do: entries
  defp optional_entries(entries, key, value), do: entries ++ [{key, value}]

  defp object(entries, state) do
    {value, heap} = Value.object(entries, state["heap"])
    {value, %{state | "heap" => heap}}
  end

  defp record_value(%{"type" => type} = value, state)
       when type in ["undefined", "null", "boolean", "string", "number", "reference"],
       do: {value, state}

  defp record_value(value, state) when is_binary(value), do: {string(value), state}

  defp record_value(value, state) when is_boolean(value),
    do: {%{"type" => "boolean", "value" => value}, state}

  defp record_value(value, state) when is_number(value), do: {tagged_number(value), state}

  defp record_value(values, state) when is_list(values) do
    {values, state} = Enum.map_reduce(values, state, &record_value/2)
    {value, heap} = Value.array(values, state["heap"])
    {value, %{state | "heap" => heap}}
  end

  defp record_value(record, state) when is_map(record) do
    {entries, state} =
      Enum.map_reduce(record, state, fn {key, value}, state ->
        {value, state} = record_value(value, state)
        {{key, value}, state}
      end)

    object(entries, state)
  end
end
