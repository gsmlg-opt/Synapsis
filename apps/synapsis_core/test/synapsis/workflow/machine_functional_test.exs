defmodule Synapsis.Workflow.MachineFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.{Machine, Pipeline, Value}

  # Independently authored ordinary-success tests, frozen before Machine/capture.
  # Schema requests are acknowledged by this explicit trusted-driver fixture.
  # This does not implement or establish host schema validation equivalence.

  test "constructors precede collection and head zero never starts its lazy input" do
    state = machine("pick id | head --n 0 | json", ~S([{"id":1},{"id":2}]), "iterator_items")
    state = seek(state, &(length(&1["frames"]) == 3))
    assert frame_names(state) == ["pick", "head", "json"]
    assert state["version"] == 1
    assert is_integer(state["stage_index"])
    assert is_binary(state["phase"])
    assert state["streams"][state["input_stream"]]["kind"] == "iterator_items"
    assert input(state)["cursor"] == 0
    assert input(state)["started"] == false
    assert input(state)["completed"] == false
    assert input(state)["returned"] == false
    assert Enum.all?(state["frames"], &is_binary(&1["status"]))

    {:complete, result, state, []} = boundary(state)
    assert public_items(result["items"], state) == []
    assert result["rendered"] == false
    assert result["rendered_items"] == []
    assert result["stdout"] == ""
    assert input(state)["cursor"] == 0
    assert input(state)["started"] == false
    assert input(state)["completed"] == false
    assert input(state)["returned"] == false
  end

  test "positive fractional head yields two items and returns its started upstream" do
    state =
      machine("head --n 1.5 | pick id | json", ~S([{"id":1},{"id":2},{"id":3}]), "iterator_items")

    {:complete, result, state, []} = boundary(state)
    assert public_items(result["items"], state) == [%{"id" => 1}, %{"id" => 2}]
    assert frame_names(state) == ["head", "pick", "json"]
    assert input(state)["cursor"] == 2
    assert input(state)["started"] == true
    assert input(state)["completed"] == false
    assert input(state)["returned"] == true
  end

  test "head Number coercion accepts ordinary parser-reachable values" do
    for {flag, expected} <- [
          {~S(--n ""), []},
          {"--n 0x2", ["a", "b"]},
          {"--n", ["a"]},
          {"--n 2.0", ["a", "b"]}
        ] do
      {:complete, result, state, []} = boundary(machine("head #{flag} | json", ~S(["a","b","c"])))
      assert public_items(result["items"], state) == expected
    end
  end

  test "pick projects only demanded items and retains a missing own field as undefined" do
    state =
      machine(
        "pick ' id , absent ' | head --n 1 | json",
        ~S([{"id":1,"extra":true},{"id":2}]),
        "iterator_items"
      )

    {:complete, result, state, []} = boundary(state)
    [item] = result["items"]
    assert Value.object_keys(item, state["heap"]) == ["id", "absent"]
    assert Value.object_get(item, "absent", state["heap"]) == %{"type" => "undefined"}
    assert public_items(result["items"], state) == [%{"id" => 1}]
    assert input(state)["cursor"] == 1
  end

  test "pick exposes canonical array indices and length and retains missing noncanonical keys" do
    state = machine("pick ' 0 , length , 01 , missing ' | json", ~S([["first","second"]]))
    {:complete, result, state, []} = boundary(state)
    [item] = result["items"]
    assert Value.object_keys(item, state["heap"]) == ["0", "length", "01", "missing"]
    assert Value.object_get(item, "01", state["heap"]) == %{"type" => "undefined"}
    assert Value.object_get(item, "missing", state["heap"]) == %{"type" => "undefined"}
    assert public_items(result["items"], state) == [%{"0" => "first", "length" => 2}]
  end

  test "tool json preserves lazy tracker identity even when the initial input is an array" do
    state =
      machine(
        "json | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin",
        ~S(["draft"])
      )

    state = seek(state, &(length(&1["frames"]) == 1))
    [json] = state["frames"]
    assert input(state)["kind"] == "array"
    assert state["streams"][json["output"]]["kind"] == "transform"
    assert input(state)["started"] == false
    {:checkpoint, checkpoint, state, requests} = boundary(state)
    assert checkpoint["mode"] == "same_stage"
    assert checkpoint["replay_items"] == []
    assert public(checkpoint["request"], state)["subject"] == %{"text" => "draft"}
    assert Enum.all?(requests, &(&1["kind"] == "compile_schema"))
  end

  test "ask compile request is stable and occurs before draining its input" do
    state =
      machine(
        "ask --prompt Review --schema '{\"type\":\"string\"}'",
        ~S(["draft"]),
        "iterator_items"
      )

    {:request, request, pending} = request_boundary(state)
    assert request["kind"] == "compile_schema"
    assert is_binary(request["id"])
    assert public(request["schema"], pending) == %{"type" => "string"}
    assert input(pending)["started"] == false
    assert input(pending)["cursor"] == 0
    assert Machine.advance(pending) == {:request, request, pending}
    assert Machine.advance(pending) == {:request, request, pending}
    {:checkpoint, checkpoint, _state, _requests} = acknowledge_then_boundary(request, pending)
    assert checkpoint["mode"] == "same_stage"
  end

  test "ask defaults and truthy string flags follow source constructor behavior" do
    {:checkpoint, checkpoint, state, _requests} = boundary(machine("ask", ~S(["draft"])))
    request = public(checkpoint["request"], state)
    assert request["prompt"] == "Input required"

    assert request["responseSchema"] == %{
             "type" => "object",
             "properties" => %{
               "decision" => %{"type" => "string", "enum" => ["approve", "reject", "redraft"]},
               "feedback" => %{"type" => "string", "description" => "Feedback for redraft"}
             },
             "required" => ["decision"]
           }

    assert not Map.has_key?(request, "subject")

    state =
      machine(
        "ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin=false --emit=false",
        ~S(["draft"])
      )

    {:checkpoint, checkpoint, state, _requests} = boundary(state)
    assert checkpoint["mode"] == "next_stage"
    assert public(checkpoint["request"], state)["subject"] == %{"text" => "draft"}
  end

  test "pick field names trim ECMAScript Unicode edge whitespace" do
    state = machine("pick '\uFEFFid\u00A0,\u2003absent\u202F' | json", ~S([{"id":1}]))
    {:complete, result, state, []} = boundary(state)
    [item] = result["items"]
    assert Value.object_keys(item, state["heap"]) == ["id", "absent"]
    assert Value.object_get(item, "absent", state["heap"]) == %{"type" => "undefined"}
    assert public_items(result["items"], state) == [%{"id" => 1}]
  end

  test "actual array replay and public ask metadata use strict snapshots" do
    state =
      machine(
        "ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
        ~S([{"title":"draft"}])
      )

    [original] = input(state)["items"]
    {:checkpoint, checkpoint, state, _requests} = boundary(state)
    assert checkpoint["mode"] == "same_stage"
    assert checkpoint["stage_index"] == 0
    assert checkpoint["halted_at"] == %{"index" => 0, "name" => "ask", "in_place" => true}
    assert public_items(checkpoint["replay_items"], state) == [%{"title" => "draft"}]
    [snapshot] = checkpoint["replay_items"]
    assert snapshot != original

    expected = %{
      "type" => "input_request",
      "prompt" => "Review",
      "responseSchema" => %{"type" => "string"},
      "subject" => %{"text" => ~S({"title":"draft"})},
      "items" => [%{"title" => "draft"}],
      "commandInput" => %{
        "pending" => %{
          "requestIndex" => 0,
          "metadata" => %{
            "prompt" => "Review",
            "responseSchema" => %{"type" => "string"},
            "subject" => %{"text" => ~S({"title":"draft"})},
            "signature" =>
              ~S({"prompt":"Review","responseSchema":{"type":"string"},"subject":{"text":"{\"title\":\"draft\"}"}})
          },
          "suspendedState" => %{"type" => "ask", "subject" => %{"text" => ~S({"title":"draft"})}}
        },
        "history" => []
      }
    }

    assert public(checkpoint["request"], state) == expected
    assert is_map(checkpoint["command_input"])
    heap = Value.object_put(original, "title", string("changed"), state["heap"])
    state = Map.put(state, "heap", heap)
    assert public_items(checkpoint["replay_items"], state) == [%{"title" => "draft"}]
    assert public(checkpoint["request"], state) == expected
  end

  test "same-stage resume preserves subject and constructs a fresh segment without its prefix" do
    state =
      machine(
        "head --n 1 | ask --prompt Review --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
        ~S(["draft","later"]),
        "iterator_items"
      )

    {:checkpoint, checkpoint, state, _requests} = boundary(state)
    assert frame_names(state) == ["head", "ask"]
    assert checkpoint["replay_items"] == []
    assert checkpoint["stage_index"] == 1
    assert public(checkpoint["request"], state)["subject"] == %{"text" => "draft"}
    assert {:ok, resumed} = Machine.resume(state, string("continue"))
    assert Enum.map(resumed["program"], & &1["name"]) == ["ask", "json"]
    {:request, request, pending} = response_request_before_construction(resumed)
    assert request["kind"] == "validate_response"
    assert public(request["response"], pending) == "continue"
    assert pending["frames"] == []
    {:complete, result, state, requests} = acknowledge_then_boundary(request, pending)
    assert public_items(result["items"], state) == ["continue"]
    assert frame_names(state) == ["ask", "json"]
    [ask, _json] = state["frames"]
    assert length(ask["request_history"]) == 1
    assert Enum.any?(requests, &(&1["kind"] == "validate_response"))
  end

  test "emit checkpoints slice after ask and feed the response to the next segment" do
    state =
      machine(
        "head --n 1 | ask --prompt Review --schema '{\"type\":\"boolean\"}' --emit | json",
        ~S(["draft","later"]),
        "iterator_items"
      )

    {:checkpoint, checkpoint, state, _requests} = boundary(state)
    assert checkpoint["mode"] == "next_stage"
    assert checkpoint["stage_index"] == 1
    assert checkpoint["halted_at"] == %{"index" => 1, "name" => "ask", "in_place" => false}

    assert public(checkpoint["request"], state) == %{
             "type" => "input_request",
             "prompt" => "Review",
             "responseSchema" => %{"type" => "boolean"},
             "items" => ["draft"]
           }

    assert not Map.has_key?(checkpoint, "command_input")
    assert {:ok, resumed} = Machine.resume(state, %{"type" => "boolean", "value" => true})
    assert Enum.map(resumed["program"], & &1["name"]) == ["json"]
    {:complete, result, state, requests} = boundary(resumed)
    assert Enum.any?(requests, &(&1["kind"] == "validate_response"))
    assert public_items(result["items"], state) == [true]
    assert frame_names(state) == ["json"]
  end

  test "sequential asks checkpoint independently and consume each response once" do
    state =
      machine(
        "ask --prompt First --schema '{\"type\":\"string\"}' --subject-from-stdin | ask --prompt Second --schema '{\"type\":\"string\"}' --subject-from-stdin | json",
        ~S(["draft"])
      )

    {:checkpoint, first, state, _requests} = boundary(state)
    assert public(first["request"], state)["prompt"] == "First"
    assert public_items(first["replay_items"], state) == ["draft"]
    assert {:ok, state} = Machine.resume(state, string("alpha"))
    {:checkpoint, second, state, _requests} = boundary(state)
    assert second["stage_index"] == 1
    assert second["replay_items"] == []
    assert public(second["request"], state)["prompt"] == "Second"
    assert public(second["request"], state)["subject"] == %{"text" => "alpha"}
    assert frame_names(state) == ["ask", "ask"]
    assert length(hd(state["frames"])["request_history"]) == 1
    assert {:ok, state} = Machine.resume(state, string("beta"))
    {:complete, result, state, _requests} = boundary(state)
    assert public_items(result["items"], state) == ["beta"]
    assert frame_names(state) == ["ask", "json"]
    assert length(hd(state["frames"])["request_history"]) == 1
  end

  test "rendering drains during construction, keeps original items, and writes pretty JSON plus LF" do
    state =
      machine(
        "pick id,label | json | head --n 0",
        ~S([{"id":1,"label":"一","extra":true}]),
        "array",
        %{"render_output" => true}
      )

    state = seek(state, &(length(&1["frames"]) == 3))
    assert input(state)["started"] == true
    assert input(state)["cursor"] == 1
    assert input(state)["completed"] == true
    {:complete, result, state, []} = boundary(state)
    assert result["items"] == []
    assert result["rendered"] == true
    assert public_items(result["rendered_items"], state) == [%{"id" => 1, "label" => "一"}]
    assert result["stdout"] == "[\n  {\n    \"id\": 1,\n    \"label\": \"一\"\n  }\n]\n"
  end

  test "an intermediate pulled machine survives exact ordinary JSON roundtrip" do
    state =
      machine("pick id | head --n 1.5 | json", ~S([{"id":1},{"id":2},{"id":3}]), "iterator_items")

    state = seek(state, &(input(&1)["cursor"] == 1))
    assert input(state)["started"] == true
    assert input(state)["completed"] == false
    assert frame_names(state) == ["pick", "head", "json"]
    restored = state |> Jason.encode!() |> Jason.decode!()
    assert restored == state
    assert json_data?(state)
    original_result = boundary(state)
    assert boundary(restored) == original_result
    {:complete, result, state, []} = original_result
    assert public_items(result["items"], state) == [%{"id" => 1}, %{"id" => 2}]
    assert input(state)["cursor"] == 2
  end

  test "ask buffered output records ordinary response and emitted request lifecycle" do
    state =
      machine("ask --prompt Review --schema '{\"type\":\"string\"}'", ~S(["draft"]))

    {:checkpoint, checkpoint, state, _requests} = boundary(state)
    assert checkpoint["mode"] == "same_stage"
    assert frame_names(state) == ["ask"]
    [ask] = state["frames"]
    assert ask["output_started"] == false

    assert {:ok, resumed} = Machine.resume(state, string("continue"))
    {:complete, result, state, _requests} = boundary(resumed)
    assert public_items(result["items"], state) == ["continue"]
    assert frame_names(state) == ["ask"]
    [ask] = state["frames"]
    assert ask["output_started"] == true
    assert ask["status"] == "finished"

    state =
      machine(
        "ask --prompt Review --schema '{\"type\":\"string\"}' --emit",
        ~S(["draft"])
      )

    {:checkpoint, checkpoint, state, _requests} = boundary(state)
    assert checkpoint["mode"] == "next_stage"

    assert public(checkpoint["request"], state) == %{
             "type" => "input_request",
             "prompt" => "Review",
             "responseSchema" => %{"type" => "string"},
             "items" => ["draft"]
           }

    assert frame_names(state) == ["ask"]
    [ask] = state["frames"]
    assert ask["output_started"] == true
    assert ask["status"] == "finished"
  end

  defp machine(pipeline, json, kind \\ "array", options \\ %{}) do
    assert {:ok, program} = Pipeline.parse(pipeline)
    assert {:ok, array, heap} = Value.decode_json(json)

    assert {:ok, state} =
             Machine.new(
               program,
               %{"kind" => kind, "items" => Value.array_items(array, heap)},
               heap,
               options
             )

    state
  end

  defp input(state), do: state["streams"][state["input_stream"]]
  defp frame_names(state), do: Enum.map(state["frames"], & &1["name"])
  defp string(value), do: %{"type" => "string", "value" => value}

  defp public(value, state) do
    assert {:ok, text} = WorkflowJSON.stringify(value, state["heap"])
    Jason.decode!(text)
  end

  defp public_items(items, state), do: Enum.map(items, &public(&1, state))

  defp seek(state, predicate, remaining \\ 2_000)

  defp seek(state, predicate, remaining) when remaining > 0 do
    if predicate.(state) do
      state
    else
      assert {:continue, state} = Machine.advance(state)
      seek(state, predicate, remaining - 1)
    end
  end

  defp seek(_state, _predicate, 0), do: flunk("ordinary machine transition bound exceeded")

  defp request_boundary(state, remaining \\ 2_000)

  defp request_boundary(state, remaining) when remaining > 0 do
    case Machine.advance(state) do
      {:continue, state} -> request_boundary(state, remaining - 1)
      {:request, request, state} -> {:request, request, state}
      other -> flunk("expected schema request, got #{inspect(other)}")
    end
  end

  defp request_boundary(_state, 0), do: flunk("ordinary request transition bound exceeded")

  defp response_request_before_construction(state) do
    assert state["frames"] == []
    response_transition(Machine.advance(state), 2_000)
  end

  defp response_transition(_transition, 0),
    do: flunk("ordinary saved-response transition bound exceeded")

  defp response_transition({:continue, state}, remaining) do
    assert state["frames"] == []
    response_transition(Machine.advance(state), remaining - 1)
  end

  defp response_transition({:request, %{"kind" => "compile_schema"} = request, state}, remaining) do
    assert state["frames"] == []
    assert Machine.advance(state) == {:request, request, state}
    event = %{"id" => request["id"], "result" => "ok"}
    response_transition(Machine.advance(state, event), remaining - 1)
  end

  defp response_transition(
         {:request, %{"kind" => "validate_response"} = request, state},
         _remaining
       ) do
    assert state["frames"] == []
    {:request, request, state}
  end

  defp response_transition(other, _remaining),
    do: flunk("expected saved-response request before construction, got #{inspect(other)}")

  defp acknowledge_then_boundary(request, state) do
    # A matching acknowledgement represents completed work by a future driver.
    event = %{"id" => request["id"], "result" => "ok"}
    settle(Machine.advance(state, event), [request], 2_000)
  end

  defp boundary(state), do: settle(Machine.advance(state), [], 2_000)

  defp settle(_transition, _requests, 0),
    do: flunk("ordinary completion transition bound exceeded")

  defp settle({:continue, state}, requests, remaining),
    do: settle(Machine.advance(state), requests, remaining - 1)

  defp settle({:request, request, state}, requests, remaining) do
    assert request["kind"] in ["compile_schema", "validate_response"]
    assert is_binary(request["id"])
    assert is_map(public(request["schema"], state))
    assert Machine.advance(state) == {:request, request, state}
    event = %{"id" => request["id"], "result" => "ok"}
    settle(Machine.advance(state, event), requests ++ [request], remaining - 1)
  end

  defp settle({:checkpoint, checkpoint, state}, requests, _remaining),
    do: {:checkpoint, checkpoint, state, requests}

  defp settle({:complete, result, state}, requests, _remaining),
    do: {:complete, result, state, requests}

  defp settle(other, _requests, _remaining),
    do: flunk("unexpected ordinary transition #{inspect(other)}")

  defp json_data?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_data?(item) end)

  defp json_data?(value) when is_list(value), do: Enum.all?(value, &json_data?/1)

  defp json_data?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)
end
