defmodule Synapsis.Workflow.MachineUTF16FunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.JSON, as: WorkflowJSON
  alias Synapsis.Workflow.Schema.PortSession
  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Value}

  @root Path.expand("../../../../..", __DIR__)
  @fixture Path.join(@root, "packages/tool-host/test/fixtures/workflow-machine-utf16-cases.json")
  @external_resource @fixture
  @data @fixture |> File.read!() |> Jason.decode!()
  @moduletag timeout: 120_000

  # Literals shared with the unchanged-whole-module Node oracle, frozen before
  # implementation. Inputs enter via the trusted Value/Machine APIs; no public
  # escaped-lone import, template constructor or native effect is claimed.
  for item <- @data["cases"] do
    @item item
    test "Machine exact runtime strings: #{@item["id"]}" do
      {roots, heap} = values(@item["input"], Value.new())
      roots = if @item["alias_first"], do: roots ++ [hd(roots)], else: roots
      state = machine(@item["pipeline"], roots, heap)
      {:complete, result, final} = boundary(state)
      assert item_json(result["items"], final) == @item["expected_json"]

      if @item["indices"] do
        assert result["items"] == Enum.map(@item["indices"], &Enum.at(roots, &1))
        assert Map.take(final["heap"]["nodes"], Map.keys(heap["nodes"])) == heap["nodes"]
      end

      if @item["alias_first"] do
        assert result["items"] == roots
        assert Enum.at(result["items"], 0) == Enum.at(result["items"], 1)
      end

      for {field, names} <- @item["fields"] || %{}, {name, index} <- Enum.with_index(names) do
        value = Value.object_get(Enum.at(result["items"], index), field, final["heap"])
        assert value == @data["strings"][name]["tag"]
        assert Value.to_utf16le(value) == Base.decode64!(@data["strings"][name]["base64"])
      end

      if @item["group_indices"] do
        for {indices, i} <- Enum.with_index(@item["group_indices"]) do
          group = Enum.at(result["items"], i)
          items = Value.object_get(group, "items", final["heap"])
          assert Value.array_items(items, final["heap"]) == Enum.map(indices, &Enum.at(roots, &1))
          key = Value.object_get(group, "key", final["heap"])
          assert key == @data["strings"][Enum.at(@item["group_keys"], i)]["tag"]
        end
      end

      assert Jason.decode!(Jason.encode!(final)) == final
    end
  end

  test "trusted constructors use the frozen canonical tags and exact unit encodings" do
    for {_name, item} <- @data["strings"] do
      raw = utf16(item["units"])
      assert Base.encode64(raw) == item["base64"]
      assert Value.from_utf16le(raw) == item["tag"]
      assert Value.to_utf16le(item["tag"]) == raw
      assert WorkflowJSON.stringify(item["tag"], Value.new()) == {:ok, item["json"]}
    end
  end

  for item <- @data["previews"] do
    @item item
    test "ask preview, metadata and ordinary checkpoint resume: #{@item["id"]}" do
      with_session(fn session ->
        {roots, heap} = preview_input(@item)
        {raw, expected_json} = preview_expected(@item)

        expected_tag =
          if @item["expected_repeat"] || @item["id"] == "joined-lone-input-units",
            do: %{"type" => "string", "utf16le" => Base.encode64(raw)},
            else: %{"type" => "string", "value" => ~S({"k":"\ud83d"})}

        for {emit, mode} <- [{"", "same_stage"}, {" --emit", "next_stage"}] do
          state =
            machine(
              "ask --prompt Review --schema '{}' --subject-from-stdin" <>
                emit <> " | map 'echo={{.}}'",
              roots,
              heap,
              "array"
            )

          {:checkpoint, checkpoint, saved} = boundary(state, session)
          assert checkpoint["mode"] == mode
          request = checkpoint["request"]
          subject = Value.object_get(request, "subject", saved["heap"])
          text = Value.object_get(subject, "text", saved["heap"])
          assert text == expected_tag
          assert Value.to_utf16le(text) == raw
          assert WorkflowJSON.stringify(text, saved["heap"]) == {:ok, expected_json}
          items = Value.object_get(request, "items", saved["heap"])

          assert item_json(Value.array_items(items, saved["heap"]), saved) ==
                   item_json(roots, state)

          if mode == "same_stage" do
            pending = checkpoint["command_input"]["pending"]

            assert pending["metadata"]["signature"] ==
                     ~s({"prompt":"Review","responseSchema":{},"subject":{"text":) <>
                       expected_json <> "}}"

            metadata_text =
              pending["metadata"]["subject"] |> Value.object_get("text", saved["heap"])

            suspended_subject =
              pending["suspendedState"] |> Value.object_get("subject", saved["heap"])

            assert metadata_text == expected_tag
            assert Value.object_get(suspended_subject, "text", saved["heap"]) == expected_tag
          end

          restored = saved |> Jason.encode!() |> Jason.decode!()
          assert restored == saved
          response = @data["strings"]["high"]["tag"]
          assert {:ok, resumed} = Machine.resume(restored, response)
          {:complete, result, completed} = boundary(resumed, session)
          assert item_json(result["items"], completed) == [~S({"value":"\ud83d","echo":"\ud83d"})]
          [answer] = result["items"]
          assert Value.object_get(answer, "echo", completed["heap"]) == response
          if mode == "same_stage", do: assert(completed["resume_input"]["consumed"] == true)
        end
      end)
    end
  end

  for item <- @data["tables"] do
    @item item
    test "table retains units until its UTF8 stdout writes: #{@item["id"]}" do
      {roots, heap} = values(@item["input"], Value.new())
      state = machine("table", roots, heap, "iterator_items", %{"render_output" => true})
      before_json = item_json(roots, state)
      {:complete, result, final} = boundary(state)

      assert result == %{
               "items" => [],
               "rendered" => true,
               "rendered_items" => [],
               "stdout" => @item["stdout"]
             }

      assert String.valid?(result["stdout"])
      assert final["pipeline_output_started"] == true
      assert item_json(roots, final) == before_json
      assert Map.take(final["heap"]["nodes"], Map.keys(heap["nodes"])) == heap["nodes"]
      assert Jason.decode!(Jason.encode!(final)) == final
    end
  end

  test "ordinary transition snapshots retain a shared object and canonical pair rejoining" do
    {roots, heap} =
      values([%{"hi" => %{"$string" => "high"}, "lo" => %{"$string" => "low"}}], Value.new())

    [root] = roots
    state = machine("map 'joined={{hi}}{{lo}}' 'seen={{hi}}'", [root, root], heap)
    {:complete, result, final} = boundary(state, nil, true)
    assert result["items"] == [root, root]
    assert Value.object_get(root, "joined", final["heap"]) == @data["strings"]["pair"]["tag"]
    assert Value.object_get(root, "seen", final["heap"]) == @data["strings"]["high"]["tag"]
  end

  test "existing internal invoke each request JSON preserves the lone item until an ordinary reply" do
    high = @data["strings"]["high"]["tag"]

    state =
      machine("openclaw.invoke --tool fixture.echo --action echo --each", [high], Value.new())

    {:request, request, pending} = boundary(state)
    assert request["kind"] == "invoke"
    assert request["body"] == ~S({"tool":"fixture.echo","action":"echo","args":{"item":"\ud83d"}})
    assert String.valid?(request["body"])
    assert pending["streams"][pending["input_stream"]]["items"] == [high]
    restored = pending |> Jason.encode!() |> Jason.decode!()
    assert restored == pending

    assert {:continue, next} =
             Machine.advance(restored, %{
               "id" => request["id"],
               "response_json" => ~S({"ok":true,"result":"ok"})
             })

    {:complete, result, final} = boundary(next)
    assert item_json(result["items"], final) == [~S("ok")]
  end

  defp utf16(units), do: for(unit <- units, into: <<>>, do: <<unit::unsigned-little-16>>)

  defp values(items, heap), do: Enum.map_reduce(items, heap, &value/2)
  defp value(%{"$string" => name}, heap), do: {@data["strings"][name]["tag"], heap}

  defp value(items, heap) when is_list(items) do
    {items, heap} = values(items, heap)
    Value.array(items, heap)
  end

  defp value(fields, heap) when is_map(fields) do
    {entries, heap} =
      Enum.map_reduce(Enum.sort(fields), heap, fn {key, child}, heap ->
        {child, heap} = value(child, heap)
        {{key, child}, heap}
      end)

    Value.object(entries, heap)
  end

  defp value(item, heap) do
    assert {:ok, value, heap} = Value.decode_json(Jason.encode!(item), heap)
    {value, heap}
  end

  defp machine(pipeline, roots, heap, kind \\ "iterator_items", options \\ %{}) do
    assert {:ok, program} = Pipeline.parse(pipeline)

    assert {:ok, state} =
             Machine.new(program, %{"kind" => kind, "items" => roots}, heap, options)

    state
  end

  defp item_json(items, state),
    do:
      Enum.map(items, fn item ->
        assert {:ok, json} = WorkflowJSON.stringify(item, state["heap"])
        json
      end)

  defp preview_input(%{"input_repeat" => repeat}) do
    values(
      [String.duplicate(<<repeat["unit"]::utf8>>, repeat["count"]) <> repeat["suffix"]],
      Value.new()
    )
  end

  defp preview_input(item), do: values(item["input"], Value.new())

  defp preview_expected(%{"expected_repeat" => repeat, "expected_json_repeat" => json}) do
    raw =
      :binary.copy(<<repeat["unit"]::unsigned-little-16>>, repeat["count"]) <>
        utf16(repeat["tail_units"])

    {raw, "\"" <> String.duplicate(json["prefix"], json["count"]) <> json["tail"] <> "\""}
  end

  defp preview_expected(item), do: {utf16(item["expected_units"]), item["expected_json"]}

  defp boundary(state, session \\ nil, roundtrip \\ false, remaining \\ 4_000)
  defp boundary(_state, _session, _roundtrip, 0), do: flunk("ordinary transition bound exceeded")

  defp boundary(state, session, roundtrip, remaining) do
    restored = if roundtrip, do: Jason.decode!(Jason.encode!(state)), else: state
    assert restored == state

    case Machine.advance(restored) do
      {:continue, next} ->
        boundary(next, session, roundtrip, remaining - 1)

      {:request, %{"kind" => kind}, pending}
      when kind in ["compile_schema", "validate_response"] and not is_nil(session) ->
        assert {:continue, next} = Schema.advance_pending(session, pending, 15_000)
        boundary(next, session, roundtrip, remaining - 1)

      {:request, request, pending} ->
        {:request, request, pending}

      {:complete, result, final} ->
        {:complete, result, final}

      {:checkpoint, checkpoint, saved} ->
        {:checkpoint, checkpoint, saved}

      other ->
        flunk("unexpected ordinary UTF16 transition: #{inspect(other)}")
    end
  end

  defp with_session(run) do
    node = System.find_executable("node")
    assert is_binary(node)

    session =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: node,
         helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")}
      )

    try do
      run.(session)
    after
      assert {:ok, %{phase: :settled, cleanup_confirmed: true, exit_status: 0}} =
               PortSession.close(session)
    end
  end
end
