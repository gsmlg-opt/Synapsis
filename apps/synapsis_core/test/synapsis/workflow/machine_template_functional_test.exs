defmodule Synapsis.Workflow.MachineTemplateFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.{Machine, Pipeline, Schema, Template, Value}
  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../..", __DIR__)
  @fixture Path.join(@root, "packages/tool-host/test/fixtures/workflow-template-requests.json")
  @external_resource @fixture
  @corpus @fixture |> File.read!() |> Jason.decode!()
  @timeout 15_000
  @moduletag timeout: 120_000

  # Independent source literals, frozen before production. File acknowledgements
  # below are explicitly TRUSTED CONTENT INPUT, never evidence of a file read.
  # Every render/schema acknowledgement comes from the actual owned PortSession.

  test "all frozen 114 source and 23 UTF16 literals pass through lazy Machine and actual PortSession" do
    with_session(fn session ->
      assert length(@corpus["cases"]) == 137

      for vector <- @corpus["cases"] do
        state =
          new(
            [stage("template", %{"file" => "trusted-corpus.txt"})],
            [vector["request"]["item"]],
            vector["heap"],
            "iterator_items"
          )

        {:request, file, pending} = next_boundary(roundtrip(state))

        assert file == %{
                 "id" => "template-file:1",
                 "kind" => "read_template_file",
                 "file" => "trusted-corpus.txt",
                 "stage_index" => 0
               }

        assert input(pending)["cursor"] == 0
        assert {:continue, loaded} = acknowledge_file(pending, vector["request"]["template"])
        {:request, request, rendering} = next_boundary(roundtrip(loaded))

        assert request == %{
                 "id" => "template:2",
                 "kind" => "render_template",
                 "template" => vector["request"]["template"],
                 "item" => vector["request"]["item"],
                 "stream" => hd(rendering["frames"])["output"],
                 "stage_index" => 0
               }

        assert rendering["heap"] == vector["heap"]
        assert input(rendering)["cursor"] == 1
        assert rendering["items"] == []
        assert {:continue, rendered} = render(session, roundtrip(rendering))
        {:complete, result, final} = next_boundary(roundtrip(rendered))

        assert result == %{
                 "items" => [vector["expected"]],
                 "rendered" => false,
                 "rendered_items" => [],
                 "stdout" => ""
               }

        assert Value.to_utf16le(hd(result["items"])) == Base.decode64!(vector["expected_utf16le"])
        assert final["heap"] == vector["heap"]
        assert final["next_request"] == 3
      end
    end)
  end

  test "typed flag selection, whitespace, file fallback and positional joining retain source precedence" do
    with_session(fn session ->
      for {args, file_text, expected, kinds} <- [
            {%{"text" => "TEXT {{name}}", "file" => "full", "_" => ["POSITIONAL"]}, nil,
             "TEXT Ada", ["render_template"]},
            {%{"text" => "  ", "file" => "full"}, nil, "  ", ["render_template"]},
            {%{"text" => "", "file" => "full"}, "FILE {{name}}", "FILE Ada",
             ["read_template_file", "render_template"]},
            {%{"text" => true, "file" => "full"}, "FILE {{name}}", "FILE Ada",
             ["read_template_file", "render_template"]},
            {%{"file" => "empty", "_" => ["POSITIONAL", "{{name}}"]}, "", "POSITIONAL Ada",
             ["read_template_file", "render_template"]},
            {%{"text" => "", "file" => "", "_" => ["Hello", "{{name}}", "!"]}, nil, "Hello Ada !",
             ["render_template"]},
            {%{"text" => true, "file" => true, "_" => ["TYPED", "{{name}}"]}, nil, "TYPED Ada",
             ["render_template"]}
          ] do
        state = machine([stage("template", args)], ~S([{"name":"Ada"}]))

        {:complete, result, _final, requests} =
          drive(state, session, fn _ -> string(file_text) end)

        assert result["items"] == [string(expected)]
        assert Enum.map(requests, & &1["kind"]) == kinds

        expected_ids =
          Enum.with_index(kinds, 1)
          |> Enum.map(fn {kind, ordinal} -> prefix(kind) <> Integer.to_string(ordinal) end)

        assert Enum.map(requests, & &1["id"]) == expected_ids
      end
    end)
  end

  test "trusted file seam retains lone UTF16 units in the template root and actual rendered receipt" do
    with_session(fn session ->
      state = machine([stage("template", %{"file" => "trusted-utf16"})], ~S([{"v":"雪"}]))
      {:request, _, pending} = next_boundary(state)
      template = %{"type" => "string", "utf16le" => "Pdh7AHsAdgB9AH0AAN4="}
      assert {:continue, loaded} = acknowledge_file(roundtrip(pending), template)
      {:request, request, pending} = next_boundary(loaded)
      assert request["template"] == template
      assert request["id"] == "template:2"
      assert {:continue, rendered} = render(session, roundtrip(pending))
      {:complete, result, final} = next_boundary(roundtrip(rendered))
      assert result["items"] == [%{"type" => "string", "utf16le" => "PdjqlgDe"}]

      assert Value.to_utf16le(hd(result["items"])) ==
               <<0xD83D::little-16, 0x96EA::little-16, 0xDE00::little-16>>

      assert input(final)["completed"] == true
    end)
  end

  test "file constructor precedes downstream construction and input even with head0 or empty input" do
    # These demands never render or validate: no compute helper is needed.
    session = nil

    for kind <- ["array", "iterator_items"], empty? <- [false, true] do
      program = [
        stage("template", %{"file" => "raw relative 雪.txt"}),
        stage("head", %{"n" => "0"})
      ]

      state = machine(program, if(empty?, do: "[]", else: ~S([{"name":"Ada"}])), kind)
      {:request, request, pending} = next_boundary(state)

      assert request == %{
               "id" => "template-file:1",
               "kind" => "read_template_file",
               "file" => "raw relative 雪.txt",
               "stage_index" => 0
             }

      assert pending["stage_index"] == 0
      assert length(pending["frames"]) == 1
      assert input(pending)["started"] == false
      assert input(pending)["cursor"] == 0
      assert {:continue, loaded} = acknowledge_file(roundtrip(pending), string("FILE {{name}}"))
      {:complete, result, final, []} = drive(loaded, session)
      assert result["items"] == []
      assert input(final)["started"] == false
      assert input(final)["cursor"] == 0
      assert final["next_request"] == 2
    end

    state = machine([stage("template", %{"file" => "empty-input"})], "[]", "iterator_items")
    {:complete, result, final, requests} = drive(state, session, fn _ -> string("FILE") end)
    assert result["items"] == []
    assert Enum.map(requests, & &1["kind"]) == ["read_template_file"]
    assert input(final)["completed"] == true
  end

  test "two template constructors read independently before the first demand and retain loaded text" do
    with_session(fn session ->
      program = [
        stage("template", %{"file" => "same.txt"}),
        stage("template", %{"file" => "same.txt"})
      ]

      state = machine(program, ~S([{"name":"Ada"},{"name":"Bob"}]), "iterator_items")
      {:request, first, pending} = next_boundary(state)
      assert first["id"] == "template-file:1"
      assert {:continue, loaded} = acknowledge_file(pending, string("BEFORE {{name}}"))
      {:request, second, pending} = next_boundary(roundtrip(loaded))

      assert second == %{
               "id" => "template-file:2",
               "kind" => "read_template_file",
               "file" => "same.txt",
               "stage_index" => 1
             }

      assert input(pending)["cursor"] == 0
      assert {:continue, loaded} = acknowledge_file(pending, string("[{{.}}]"))
      {:complete, result, final, requests} = drive(roundtrip(loaded), session)
      assert result["items"] == [string("[BEFORE Ada]"), string("[BEFORE Bob]")]

      assert Enum.map(requests, & &1["id"]) == [
               "template:3",
               "template:4",
               "template:5",
               "template:6"
             ]

      assert Enum.map(requests, & &1["stage_index"]) == [0, 1, 0, 1]

      assert Enum.map(requests, & &1["template"]) == [
               string("BEFORE {{name}}"),
               string("[{{.}}]"),
               string("BEFORE {{name}}"),
               string("[{{.}}]")
             ]

      assert input(final)["cursor"] == 2
      assert input(final)["completed"] == true
    end)
  end

  test "one render per demand sees current heap and shared map mutation while earlier strings remain immutable" do
    with_session(fn session ->
      assert {:ok, item, heap} = Value.decode_json(~S({"v":"A"}))
      assert {:ok, program} = Pipeline.parse("map 'v={{v}}!' | template --text '{{v}}'")
      state = new(program, [item, item], heap, "iterator_items")
      {:request, request, pending} = next_boundary(state)
      assert request["id"] == "template:1"
      assert request["item"] == item
      assert request["template"] == string("{{v}}")
      assert Value.object_get(item, "v", pending["heap"]) == string("A!")
      assert input(pending)["cursor"] == 1
      assert {:continue, next} = render(session, roundtrip(pending))
      {:request, request, pending} = next_boundary(next)
      assert request["id"] == "template:2"
      assert request["item"] == item
      assert pending["items"] == [string("A!")]
      assert Value.object_get(item, "v", pending["heap"]) == string("A!!")
      assert input(pending)["cursor"] == 2
      assert {:continue, next} = render(session, roundtrip(pending))
      {:complete, result, final} = next_boundary(next)
      assert result["items"] == [string("A!"), string("A!!")]
      assert Enum.all?(final["frames"], &(&1["status"] == "finished"))

      state = new([stage("template", %{"text" => "{{v}}"})], [item, item], heap)
      {:request, _, pending} = next_boundary(state)
      assert {:continue, next} = render(session, pending)
      # Benign trusted host mutation between normal demands; only the later
      # render sees this current heap. This does not modify a pending request.
      next = put_in(next, ["heap", "nodes", item["id"], "fields", "v"], string("B"))
      {:complete, result, _final, requests} = drive(next, session)
      assert length(requests) == 1
      assert result["items"] == [string("A"), string("B")]
    end)
  end

  test "normal head1 return finalizes acquired template without pulling another item" do
    with_session(fn session ->
      for kind <- ["array", "iterator_items"] do
        state =
          machine(
            [stage("template", %{"file" => "trusted"}), stage("head", %{"n" => "1"})],
            ~S([{"name":"Ada"},{"name":"Bob"}]),
            kind
          )

        {:complete, result, final, requests} =
          drive(state, session, fn _ -> string("HELLO {{name}}") end)

        assert result["items"] == [string("HELLO Ada")]
        assert Enum.map(requests, & &1["id"]) == ["template-file:1", "template:2"]
        assert input(final)["cursor"] == 1
        assert input(final)["returned"] == true
        assert input(final)["completed"] == false
        assert Enum.all?(final["frames"], &(&1["status"] == "finished"))
      end
    end)
  end

  test "semantic next/same stage resume validates before fresh constructors and reads updated retained path once" do
    with_session(fn session ->
      for {extra, mode} <- [{" --emit", "next_stage"}, {" --subject-from-stdin", "same_stage"}] do
        assert {:ok, program} =
                 Pipeline.parse(
                   "template --file removed.txt | template --file retained.txt | ask --prompt Review --schema '{\"type\":\"string\"}'" <>
                     extra <> " | template --file retained.txt"
                 )

        state = machine(program, ~S(["seed"]), "iterator_items")

        before_file = fn request ->
          if request["file"] == "removed.txt",
            do: string("PREFIX {{.}}"),
            else: string("OLD {{.}}")
        end

        {:checkpoint, checkpoint, saved, requests} = drive(state, session, before_file)
        assert checkpoint["mode"] == mode
        assert checkpoint["stage_index"] == 2

        assert requests
               |> Enum.filter(&(&1["kind"] == "read_template_file"))
               |> Enum.map(& &1["file"]) == ["removed.txt", "retained.txt"]

        restored = roundtrip(saved)
        assert {:ok, resumed} = Machine.resume(restored, string("fresh"))
        assert resumed["segment"] == 1
        assert resumed["next_request"] == saved["next_request"]

        {:complete, result, final, after_requests} =
          drive(roundtrip(resumed), session, fn request ->
            assert request["file"] == "retained.txt"
            string("NEW {{.}}")
          end)

        file_index = Enum.find_index(after_requests, &(&1["kind"] == "read_template_file"))
        assert is_integer(file_index)

        assert Enum.take(after_requests, file_index)
               |> Enum.all?(&(&1["kind"] in ["compile_schema", "validate_response"]))

        assert Enum.any?(
                 Enum.take(after_requests, file_index),
                 &(&1["kind"] == "validate_response" and &1["boundary"] == "saved_response")
               )

        files = Enum.filter(after_requests, &(&1["kind"] == "read_template_file"))
        assert Enum.map(files, & &1["file"]) == ["retained.txt"]
        assert hd(files)["stage_index"] == if(mode == "same_stage", do: 1, else: 0)
        assert result["items"] == [string("NEW fresh")]

        assert Enum.map(after_requests, &ordinal/1) ==
                 Enum.to_list(saved["next_request"]..(final["next_request"] - 1))

        if mode == "same_stage", do: assert(final["resume_input"]["consumed"] == true)
      end
    end)
  end

  defp machine(program, json, kind \\ "array") do
    assert {:ok, array, heap} = Value.decode_json(json)
    new(program, Value.array_items(array, heap), heap, kind)
  end

  defp new(program, items, heap, kind \\ "array") do
    assert {:ok, state} =
             Machine.new(program, %{"kind" => kind, "items" => items}, heap, %{
               "render_output" => false
             })

    state
  end

  defp stage(name, args), do: %{"name" => name, "args" => Map.put_new(args, "_", [])}
  defp string(value), do: %{"type" => "string", "value" => value}
  defp input(state), do: state["streams"]["s0"]
  defp prefix("read_template_file"), do: "template-file:"
  defp prefix("render_template"), do: "template:"

  defp ordinal(request),
    do: request["id"] |> String.split(":") |> List.last() |> String.to_integer()

  defp roundtrip(state) do
    restored = Jason.decode!(Jason.encode!(state))
    assert restored == state
    restored
  end

  defp acknowledge_file(state, value) do
    request = state["pending_request"]

    Machine.advance(state, %{
      "id" => request["id"],
      "kind" => "read_template_file",
      "result" => "ok",
      "value" => value
    })
  end

  defp next_boundary(state, remaining \\ 2_000)
  defp next_boundary(_state, 0), do: flunk("ordinary transition bound exceeded")

  defp next_boundary(state, remaining) do
    case Machine.advance(roundtrip(state)) do
      {:continue, next} ->
        next_boundary(next, remaining - 1)

      {:request, request, pending} = result ->
        assert Machine.advance(pending) == result
        assert Machine.advance(roundtrip(pending)) == result
        assert pending["pending_request"] == request
        result

      result ->
        result
    end
  end

  defp drive(
         state,
         session,
         file_content \\ fn _ -> flunk("unexpected trusted file acknowledgement") end,
         requests \\ []
       ) do
    case next_boundary(state) do
      {:request, request, pending} ->
        transition =
          case request["kind"] do
            "read_template_file" ->
              acknowledge_file(pending, file_content.(request))

            "render_template" ->
              render(session, pending)

            kind when kind in ["compile_schema", "validate_response"] ->
              Schema.advance_pending(session, pending, @timeout)
          end

        assert {:continue, next} = transition
        if request["kind"] != "read_template_file", do: assert_session(session)
        drive(next, session, file_content, requests ++ [request])

      {:complete, result, final} ->
        {:complete, result, final, requests}

      {:checkpoint, checkpoint, final} ->
        {:checkpoint, checkpoint, final, requests}

      other ->
        flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp render(session, pending) do
    before_status = PortSession.status(session)
    transition = Template.advance_pending(session, pending, @timeout)
    assert_session(session)
    assert PortSession.status(session).cache_entries == before_status.cache_entries
    transition
  end

  defp assert_session(session) do
    assert %{phase: :idle, os_pid: pid, cache_entries: entries, cleanup_confirmed: false} =
             PortSession.status(session)

    assert is_integer(pid)
    assert is_integer(entries)
    assert File.exists?("/proc/#{pid}")
    key = {__MODULE__, session}

    case Process.get(key) do
      nil -> Process.put(key, pid)
      previous -> assert pid == previous
    end
  end

  defp with_session(run) do
    node = System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert Path.type(node) == :absolute

    session =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: node,
         helper_path: Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")}
      )

    try do
      run.(session)
      assert_session(session)
      assert %{phase: :idle, os_pid: pid} = PortSession.status(session)
      assert is_integer(pid)

      assert {:ok, %{phase: :settled, cleanup_confirmed: true, exit_status: 0}} =
               PortSession.close(session)

      refute File.exists?("/proc/#{pid}")
    after
      if Process.alive?(session), do: PortSession.close(session)
      Process.delete({__MODULE__, session})
    end
  end
end
