defmodule Synapsis.Workflow.MachineInvokeFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.{Machine, Pipeline, Value}

  # Independently authored literals from the whole openclaw_invoke.js module in
  # @clawdbot/lobster 2026.9.16 and the four lobster-invoke.json source cases.
  # Only the pure semantic request/result continuation is exercised. The driver
  # supplies successful raw JSON; no transport or environment behavior is claimed.
  # Schema ACKs below are ordinary mocks, not an actual schema validator.

  test "single-drains-input-false emits the literal request after consuming all input" do
    state =
      machine(
        ~S(openclaw.invoke --tool fixture.read --action read --args-json '{"path":"雪.txt"}'),
        ~S(["ignored",{"old":1}])
      )

    {:request, request, pending} = boundary(state)

    assert request == %{
             "id" => "invoke:1",
             "kind" => "invoke",
             "command" => "openclaw.invoke",
             "segment" => 0,
             "stage_index" => 0,
             "body" => ~S({"tool":"fixture.read","action":"read","args":{"path":"雪.txt"}})
           }

    assert_unpublished(pending, ["openclaw.invoke"], 0)
    assert_source(pending, 2, true)

    assert hd(pending["frames"])["args"] == %{
             "_" => [],
             "tool" => "fixture.read",
             "action" => "read",
             "args-json" => ~S({"path":"雪.txt"})
           }

    {:complete, result, final} =
      pending |> reply(request, ~S({"ok":true,"result":false})) |> boundary()

    assert_result(result, final, ["false"])
    assert_source(final, 2, true)
    assert_constructed(final, ["openclaw.invoke"])
    assert final["next_request"] == 2
  end

  test "each-merges-before-publishing waits for each reply before pulling the next item" do
    state =
      machine(
        ~S(openclaw.invoke --tool fixture.write --action write --each --item-key value --args-json '{"keep":0,"value":"old"}'),
        ~S([{"tag":"一"},false])
      )

    {:request, first, pending} = boundary(state)

    assert first ==
             invoke(
               "invoke:1",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.write","action":"write","args":{"keep":0,"value":{"tag":"一"}}})
             )

    assert_source(pending, 1, false)
    assert_unpublished(pending, ["openclaw.invoke"], 0)

    {:request, second, pending} =
      pending |> reply(first, ~S({"ok":true,"result":[{"n":1},{"n":2}]})) |> boundary()

    assert second ==
             invoke(
               "invoke:2",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.write","action":"write","args":{"keep":0,"value":false}})
             )

    assert_source(pending, 2, false)
    assert_unpublished(pending, ["openclaw.invoke"], 0)

    {:complete, result, final} =
      pending |> reply(second, ~S({"ok":true,"result":null})) |> boundary()

    assert_result(result, final, [~S({"n":1}), ~S({"n":2}), "null"])
    assert_source(final, 2, true)
    assert_constructed(final, ["openclaw.invoke"])
    assert final["next_request"] == 3
  end

  test "legacy-command-environment-raw-array preserves the semantic legacy command" do
    state = machine("clawd.invoke --tool fixture.list --action list", "[]")
    {:request, request, pending} = boundary(state)

    assert request ==
             invoke(
               "invoke:1",
               "clawd.invoke",
               0,
               0,
               ~S({"tool":"fixture.list","action":"list","args":{}})
             )

    assert_source(pending, 0, true)
    assert_unpublished(pending, ["clawd.invoke"], 0)

    {:complete, result, final} = pending |> reply(request, ~S([{"label":"raw"},0])) |> boundary()
    assert_result(result, final, [~S({"label":"raw"}), "0"])
    assert_source(final, 0, true)
    assert_constructed(final, ["clawd.invoke"])
  end

  test "explicit-url-own-item-key-object retains transport args and raw response key order" do
    state =
      machine(
        ~S(openclaw.invoke --url http://127.0.0.1:4243/explicit --tool fixture.write --action write --each --itemKey payload --args-json '{"item":"unchanged","payload":"old"}' --sessionKey fixture-session),
        ~S(["雪😀"])
      )

    {:request, request, pending} = boundary(state)

    assert request ==
             invoke(
               "invoke:1",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.write","action":"write","args":{"item":"unchanged","payload":"雪😀"},"sessionKey":"fixture-session"})
             )

    assert hd(pending["frames"])["args"] == %{
             "_" => [],
             "url" => "http://127.0.0.1:4243/explicit",
             "tool" => "fixture.write",
             "action" => "write",
             "each" => true,
             "itemKey" => "payload",
             "args-json" => ~S({"item":"unchanged","payload":"old"}),
             "sessionKey" => "fixture-session"
           }

    assert_source(pending, 1, false)
    assert_unpublished(pending, ["openclaw.invoke"], 0)

    {:complete, result, final} =
      pending |> reply(request, ~S({"ok":true,"result":{"z":1,"a":2}})) |> boundary()

    assert_result(result, final, [~S({"z":1,"a":2})])
    [object] = result["items"]
    assert Value.object_keys(object, final["heap"]) == ["z", "a"]
    assert_source(final, 1, true)
    assert_constructed(final, ["openclaw.invoke"])
  end

  test "all each constructor calls finish before downstream head zero is constructed" do
    state =
      machine(
        "openclaw.invoke --tool fixture.echo --action echo --each | head --n 0",
        ~S(["first","second"])
      )

    {:request, first, pending} = boundary(state)

    assert first ==
             invoke(
               "invoke:1",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.echo","action":"echo","args":{"item":"first"}})
             )

    assert_unpublished(pending, ["openclaw.invoke"], 0)
    assert_source(pending, 1, false)

    {:request, second, pending} = pending |> reply(first, ~S(["one"])) |> boundary()

    assert second ==
             invoke(
               "invoke:2",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.echo","action":"echo","args":{"item":"second"}})
             )

    assert_unpublished(pending, ["openclaw.invoke"], 0)
    assert_source(pending, 2, false)

    {:complete, result, final} = pending |> reply(second, ~S(["two"])) |> boundary()
    assert_result(result, final, [])
    assert_source(final, 2, true)
    assert_constructed(final, ["openclaw.invoke", "head"])
    [call, _head] = final["frames"]
    assert final["streams"][call["output"]]["started"] == false
    assert call["output_started"] == false
    assert final["next_request"] == 3
  end

  test "successive invocation stages flatten one level and carry ordered heap roots" do
    state =
      machine(
        "openclaw.invoke --tool fixture.list --action list | clawd.invoke --tool fixture.echo --action echo --each",
        ~S(["discarded"])
      )

    {:request, first, pending} = boundary(state)

    assert first ==
             invoke(
               "invoke:1",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.list","action":"list","args":{}})
             )

    assert_unpublished(pending, ["openclaw.invoke"], 0)

    {:request, second, pending} =
      pending |> reply(first, ~S({"ok":true,"result":[[1,2],{"z":1,"a":2}]})) |> boundary()

    assert second ==
             invoke(
               "invoke:2",
               "clawd.invoke",
               0,
               1,
               ~S({"tool":"fixture.echo","action":"echo","args":{"item":[1,2]}})
             )

    assert_unpublished(pending, ["openclaw.invoke", "clawd.invoke"], 1)
    assert Enum.at(pending["frames"], 0)["status"] == "constructed"

    {:request, third, pending} = pending |> reply(second, "0") |> boundary()

    assert third ==
             invoke(
               "invoke:3",
               "clawd.invoke",
               0,
               1,
               ~S({"tool":"fixture.echo","action":"echo","args":{"item":{"z":1,"a":2}}})
             )

    assert_unpublished(pending, ["openclaw.invoke", "clawd.invoke"], 1)

    {:complete, result, final} =
      pending |> reply(third, ~S({"ok":true,"result":false})) |> boundary()

    assert_result(result, final, ["0", "false"])
    assert_constructed(final, ["openclaw.invoke", "clawd.invoke"])
    assert_source(final, 1, true)
    assert final["next_request"] == 4
  end

  test "invoke and schema ordinals continue across ask resume without repeating the prefix call" do
    state =
      machine(
        ~S(openclaw.invoke --tool fixture.draft --action draft | ask --prompt Review --schema '{"type":"string"}' --emit | clawd.invoke --tool fixture.publish --action publish --each),
        "[]"
      )

    {:request, first, pending} = boundary(state)

    assert first ==
             invoke(
               "invoke:1",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.draft","action":"draft","args":{}})
             )

    {:request, compile, pending} = pending |> reply(first, ~S(["draft"])) |> boundary()
    assert_schema(compile, pending, "schema:2", "compile_schema", "ask_constructor")
    {:checkpoint, checkpoint, suspended} = pending |> acknowledge(compile) |> boundary()
    assert checkpoint["mode"] == "next_stage"
    assert checkpoint["stage_index"] == 1
    assert Enum.map(suspended["frames"], & &1["name"]) == ["openclaw.invoke", "ask"]
    assert suspended["next_request"] == 3

    response = %{"type" => "string", "value" => "approved"}
    assert {:ok, resumed} = Machine.resume(suspended, response)
    assert Machine.resume(roundtrip(suspended), response) == {:ok, resumed}
    assert Enum.map(resumed["program"], & &1["name"]) == ["clawd.invoke"]
    assert resumed["segment"] == 1

    {:request, compile, pending} = boundary(resumed)
    assert_schema(compile, pending, "schema:3", "compile_schema", "saved_response")
    assert pending["frames"] == []
    {:request, validation, pending} = pending |> acknowledge(compile) |> boundary()
    assert_schema(validation, pending, "schema:4", "validate_response", "saved_response")
    assert validation["response"] == response
    assert pending["frames"] == []

    {:request, publish, pending} = pending |> acknowledge(validation) |> boundary()

    assert publish ==
             invoke(
               "invoke:5",
               "clawd.invoke",
               1,
               0,
               ~S({"tool":"fixture.publish","action":"publish","args":{"item":"approved"}})
             )

    assert_unpublished(pending, ["clawd.invoke"], 0)

    {:complete, result, final} =
      pending |> reply(publish, ~S({"ok":true,"result":"published"})) |> boundary()

    assert_result(result, final, [~S("published")])
    assert_constructed(final, ["clawd.invoke"])
    assert final["next_request"] == 6
  end

  test "request body preserves ordered base args and ordinary optional flag aliases" do
    {:ok, program} = Pipeline.parse("openclaw.invoke --tool fixture.echo --action echo --each")
    [stage] = program

    args =
      Map.merge(stage["args"], %{
        "args-json" => ~S({"z":1,"a":2}),
        "itemKey" => "payload",
        "item-key" => "unused",
        "session-key" => "attributed",
        "dryRun" => false,
        "dry-run" => true
      })

    state = machine_program([Map.put(stage, "args", args)], ~S([{"b":1,"a":2}]))
    {:request, request, pending} = boundary(state)

    assert request ==
             invoke(
               "invoke:1",
               "openclaw.invoke",
               0,
               0,
               ~S({"tool":"fixture.echo","action":"echo","args":{"z":1,"a":2,"payload":{"b":1,"a":2}},"sessionKey":"attributed","dryRun":false})
             )

    assert hd(pending["frames"])["args"] == args
    {:complete, result, final} = pending |> reply(request, ~S({"z":1,"a":2})) |> boundary()
    assert_result(result, final, [~S({"z":1,"a":2})])
    assert Value.object_keys(hd(result["items"]), final["heap"]) == ["z", "a"]
  end

  defp machine(pipeline, input) do
    {:ok, program} = Pipeline.parse(pipeline)
    machine_program(program, input)
  end

  defp machine_program(program, input) do
    {:ok, array, heap} = Value.decode_json(input)

    {:ok, state} =
      Machine.new(
        program,
        %{"kind" => "iterator_items", "items" => Value.array_items(array, heap)},
        heap
      )

    state
  end

  defp invoke(id, command, segment, index, body),
    do: %{
      "id" => id,
      "kind" => "invoke",
      "command" => command,
      "segment" => segment,
      "stage_index" => index,
      "body" => body
    }

  defp boundary(state, remaining \\ 10_000)
  defp boundary(_state, 0), do: flunk("ordinary transition helper exhausted")

  defp boundary(state, remaining) do
    case advance(state) do
      {:continue, next} ->
        boundary(next, remaining - 1)

      {:request, request, pending} = result ->
        assert advance(pending) == result
        assert advance(pending) == result
        assert pending["pending_request"] == request
        result

      {:complete, _result, _state} = result ->
        result

      {:checkpoint, _checkpoint, _state} = result ->
        result

      other ->
        flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp reply(state, request, raw) do
    assert {:continue, next} = advance(state, %{"id" => request["id"], "response_json" => raw})
    next
  end

  defp acknowledge(state, request) do
    assert {:continue, next} = advance(state, %{"id" => request["id"], "result" => "ok"})
    next
  end

  defp advance(state, event \\ nil) do
    restored = roundtrip(state)
    assert restored == state
    assert_roots(restored, restored["heap"])
    result = Machine.advance(state, event)
    # Every continuation, request, completion and checkpoint must be identical
    # when resumed from an ordinary JSON snapshot at this precise transition.
    assert Machine.advance(restored, event) == result
    result
  end

  defp roundtrip(value), do: value |> JSON.encode!() |> JSON.decode!()

  defp assert_roots(%{"type" => "reference", "id" => id}, heap),
    do: assert(Map.has_key?(heap["nodes"], id))

  defp assert_roots(map, heap) when is_map(map),
    do: Enum.each(map, fn {_key, value} -> assert_roots(value, heap) end)

  defp assert_roots(list, heap) when is_list(list), do: Enum.each(list, &assert_roots(&1, heap))
  defp assert_roots(_value, _heap), do: :ok

  defp assert_unpublished(state, names, index) do
    assert Enum.map(state["frames"], & &1["name"]) == names
    frame = Enum.at(state["frames"], index)
    assert frame["status"] == "constructing"
    assert frame["output"] == nil
    assert frame["output_started"] == false
    assert state["stage_index"] == index
    assert state["items"] == []
    assert state["pipeline_output_started"] == false
    assert state["stdout"] == ""
  end

  defp assert_source(state, cursor, completed) do
    source = state["streams"][state["input_stream"]]
    assert source["cursor"] == cursor
    assert source["started"] == true
    assert source["completed"] == completed
    assert source["returned"] == false
  end

  defp assert_constructed(state, names) do
    assert Enum.map(state["frames"], & &1["name"]) == names
    assert state["stage_index"] == length(names)
    assert Enum.all?(state["frames"], &(&1["status"] in ["constructed", "finished"]))
    assert Enum.all?(state["frames"], &is_binary(&1["output"]))
  end

  defp assert_result(result, state, expected) do
    assert Enum.map(result["items"], fn value ->
             assert {:ok, text} = WorkflowJSON.stringify(value, state["heap"])
             text
           end) == expected

    assert result == Map.take(state, ["items", "rendered", "rendered_items", "stdout"])
    assert result["rendered"] == false
    assert result["rendered_items"] == []
    assert result["stdout"] == ""
    assert state["phase"] == "completed"
    assert_roots(roundtrip(state), state["heap"])
    assert advance(state) == {:complete, result, state}
  end

  defp assert_schema(request, state, id, kind, boundary) do
    assert request["id"] == id
    assert request["kind"] == kind
    assert request["boundary"] == boundary
    assert {:ok, ~S({"type":"string"})} = WorkflowJSON.stringify(request["schema"], state["heap"])

    keys =
      if kind == "validate_response",
        do: ["boundary", "id", "kind", "response", "schema"],
        else: ["boundary", "id", "kind", "schema"]

    assert Enum.sort(Map.keys(request)) == keys
  end
end
