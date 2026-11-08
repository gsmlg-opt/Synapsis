defmodule Synapsis.Workflow.TemplateFileFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.Local
  alias Synapsis.Workflow.{Machine, Segment, Template, Value}
  alias Synapsis.Workflow.Schema.PortSession

  @root Path.expand("../../../../..", __DIR__)
  @source Path.join(@root, "packages/tool-host/src/workflow/schema-stdio.mjs")
  @package Path.join(@root, "apps/synapsis_core/priv/workflow_schema")
  @moduletag timeout: 180_000
  @targets [{Local, :read_binary, 3}, {PortSession, :fulfill, 4}]

  # Exact literals independently frozen before production; the Node source
  # oracle in workflow-template-file-functional.test.mjs checks the same bytes.
  @vectors [
    {"plain", "4869207b7b2e7d7d", "Hi {{.}}", "Hi 雪😀"},
    {"whitespace", "202009", "  \t", "  \t"},
    {"bom", "efbbbf7b7b2e7d7d", "\uFEFF{{.}}", "\uFEFF雪😀"},
    {"lf", "410a7b7b2e7d7d0a", "A\n{{.}}\n", "A\n雪😀\n"},
    {"crlf", "410d0a7b7b2e7d7d0d0a", "A\r\n{{.}}\r\n", "A\r\n雪😀\r\n"},
    {"nul", "41007b7b2e7d7d", "A\0{{.}}", "A\0雪😀"},
    {"unicode", "e99baaf09f9880207b7b2e7d7d", "雪😀 {{.}}", "雪😀 雪😀"},
    {"isolated-continuation", "807b7b2e7d7d", "�{{.}}", "�雪😀"},
    {"truncated-three", "e282", "�", "�"},
    {"invalid-following-ascii", "e228a1", "�(�", "�(�"},
    {"overlong", "c0af", "��", "��"},
    {"encoded-surrogate", "eda080", "���", "���"},
    {"out-of-range", "f4908080", "����", "����"},
    {"arbitrary", "fffe0041e282acf09f988080", "��\0A€😀�", "��\0A€😀�"},
    {"empty-fallback", "", "", "FALLBACK 雪😀"}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "synapsis-template-file-" <> Ecto.UUID.generate())
    File.mkdir_p!(Path.join(root, "nested cwd"))
    on_exit(fn -> File.rm_rf!(root) end)
    assert {:ok, canonical, "."} = Local.resolve(root, ".")
    %{root: canonical}
  end

  test "v1/v2 scope is explicit JSON state while old constructors keep their exact source", %{
    root: root
  } do
    scope = %{"project_root" => root, "cwd" => "nested cwd"}
    pipeline = "template --file 'file 雪 space.txt'"

    for options <- [[], [version: 2]] do
      assert {:ok, old} = Segment.new(pipeline, options)
      assert old["source"] == %{"kind" => "inline", "pipeline" => pipeline}
      assert map_size(old) == if(options == [], do: 6, else: 7)
      assert {:ok, scoped} = Segment.new(pipeline, options ++ [file_scope: scope])
      assert scoped["source"] == Map.put(old["source"], "file_scope", scope)
      assert Map.delete(scoped, "source") == Map.delete(old, "source")
      assert roundtrip(scoped) == scoped
      assert {:request, %{"kind" => "read_template_file"}, pending} = segment_boundary(scoped)
      assert pending["source"] == scoped["source"]

      if options != [],
        do: assert({:ok, %{consumed_effects: 0}} = Segment.inspect_snapshot(pending))
    end

    assert {:ok, old} = Segment.new(pipeline)
    assert {:ok, ^old} = Segment.new(pipeline, [])
  end

  test "actual source capture/decode/render preserves all 15 complete byte vectors", %{root: root} do
    check_vectors(@source, root)
  end

  test "complete relocated package captures/decodes/renders the same frozen bytes", %{root: root} do
    assembled = Path.join(root, "assembled helper")
    relocated = Path.join(root, "relocated helper")
    assert {:ok, _} = File.cp_r(@package, assembled)
    assert :ok = File.rename(assembled, relocated)
    refute File.exists?(assembled)
    check_vectors(Path.join(relocated, "schema-stdio.mjs"), root)
  end

  test "root/nested cwd, absolute and space paths reach Local unchanged", %{root: root} do
    with_session(@source, fn session ->
      for {cwd, argument, relative} <- [
            {".", "root.txt", "root.txt"},
            {"nested cwd", "space 雪 file.txt", "nested cwd/space 雪 file.txt"},
            {"nested cwd", Path.join(root, "absolute.txt"), "absolute.txt"}
          ] do
        File.write!(Path.join(root, relative), "PATH {{.}}")
        scope = %{"project_root" => root, "cwd" => cwd}

        {:request, _, pending} =
          boundary(machine([stage("template", %{"file" => argument})], [string("雪😀")]))

        {transition, events} =
          observed(fn -> Template.advance_file(session, pending, scope, deadline()) end)

        assert {:continue, loaded} = transition

        expected_path =
          if Path.type(argument) == :absolute or cwd == ".",
            do: argument,
            else: cwd <> "/" <> argument

        assert [{_, [^root, ^expected_path, _]}] = calls(events, Local, :read_binary)
        assert [{_, {:ok, "PATH {{.}}", ^relative}}] = returns(events, Local, :read_binary, 3)
        assert {:complete, result, _} = drive(loaded, session, scope)
        assert result["items"] == [string("PATH 雪😀")]
      end
    end)
  end

  test "head0 and empty input capture once before demand; text precedence suppresses capture", %{
    root: root
  } do
    File.write!(Path.join(root, "construction.txt"), "FILE {{.}}")
    scope = %{"project_root" => root, "cwd" => "."}

    with_session(@source, fn session ->
      for {items, tail} <- [{[string("A")], [stage("head", %{"n" => "0"})]}, {[], []}] do
        state = machine([stage("template", %{"file" => "construction.txt"}) | tail], items)
        {:request, _, pending} = boundary(state)
        assert pending["streams"]["s0"]["cursor"] == 0
        assert pending["streams"]["s0"]["started"] == false

        {transition, events} =
          observed(fn -> Template.advance_file(session, pending, scope, deadline()) end)

        assert {:continue, loaded} = transition
        assert length(calls(events, Local, :read_binary)) == 1

        assert Enum.map(calls(events, PortSession, :fulfill), fn {_, [_, request, _, _]} ->
                 request["kind"]
               end) == ["decode_template_file"]

        assert loaded["streams"]["s0"]["cursor"] == 0
        assert {:complete, result, _} = drive(loaded, session, scope)
        assert result["items"] == []
      end

      for {text, expected} <- [{"TEXT {{.}}", "TEXT A"}, {"  ", "  "}] do
        {result, events} =
          observed(fn ->
            drive(
              machine([stage("template", %{"text" => text, "file" => "construction.txt"})], [
                string("A")
              ]),
              session,
              scope
            )
          end)

        assert {:complete, %{"items" => [value]}, _} = result
        assert value == string(expected)
        assert calls(events, Local, :read_binary) == []

        assert Enum.map(calls(events, PortSession, :fulfill), fn {_, [_, request, _, _]} ->
                 request["kind"]
               end) == ["render_template"]
      end
    end)
  end

  test "captured text survives file update, item demands and JSON state; constructors capture independently",
       %{root: root} do
    file = Path.join(root, "retained.txt")
    scope = %{"project_root" => root, "cwd" => "."}

    with_session(@source, fn session ->
      File.write!(file, "OLD {{.}}")

      {:request, _, pending} =
        boundary(
          machine([stage("template", %{"file" => "retained.txt"})], [string("A"), string("B")])
        )

      assert {:continue, loaded} = Template.advance_file(session, pending, scope, deadline())
      File.write!(file, "NEW {{.}}")
      {result, events} = observed(fn -> drive(roundtrip(loaded), session, scope) end)
      assert {:complete, %{"items" => values}, _} = result
      assert values == [string("OLD A"), string("OLD B")]
      assert calls(events, Local, :read_binary) == []

      program = [
        stage("template", %{"file" => "retained.txt"}),
        stage("template", %{"file" => "retained.txt"})
      ]

      {:request, _, pending} = boundary(machine(program, [string("A")]))

      {first, first_events} =
        observed(fn -> Template.advance_file(session, pending, scope, deadline()) end)

      assert {:continue, loaded} = first
      File.write!(file, "[{{.}}]")
      {:request, %{"id" => "template-file:2"}, pending} = boundary(roundtrip(loaded))
      assert pending["streams"]["s0"]["cursor"] == 0

      {second, second_events} =
        observed(fn -> Template.advance_file(session, pending, scope, deadline()) end)

      assert {:continue, loaded} = second
      assert length(calls(first_events ++ second_events, Local, :read_binary)) == 2
      assert {:complete, %{"items" => values}, _} = drive(roundtrip(loaded), session, scope)
      assert values == [string("[NEW A]")]
    end)
  end

  defp check_vectors(helper, root) do
    scope = %{"project_root" => root, "cwd" => "nested cwd"}

    with_session(helper, fn session ->
      assert {:ok, compiled} =
               PortSession.fulfill(
                 session,
                 schema("compile", "compile_schema"),
                 schema_heap(),
                 15_000
               )

      assert compiled == receipt("compile", "compiled")
      %{os_pid: pid, cache_entries: 1} = PortSession.status(session)

      for {name, hex, decoded, expected} <- @vectors do
        bytes = Base.decode16!(hex, case: :lower)
        relative = "nested cwd/" <> name <> " space.txt"
        File.write!(Path.join(root, relative), bytes)
        args = %{"file" => name <> " space.txt", "_" => ["FALLBACK", "{{.}}"]}

        {:request, request, pending} =
          boundary(machine([stage("template", args)], [string("雪😀")]))

        assert request["id"] == "template-file:1"
        absolute = System.monotonic_time(:millisecond) + 30_000

        callback = fn ->
          send(
            Process.get(:template_file_tracer),
            {:live_deadline_observed, absolute, System.monotonic_time(:millisecond)}
          )

          {:ok, absolute}
        end

        {transition, events} =
          observed(fn -> Template.advance_file(session, pending, scope, callback) end)

        assert {:continue, loaded} = transition
        assert [{capture_index, [^root, ^relative, options]}] = calls(events, Local, :read_binary)

        assert [{captured_index, {:ok, ^bytes, ^relative}}] =
                 returns(events, Local, :read_binary, 3)

        assert [{helper_index, [^session, decode, heap, timeout]}] =
                 calls(events, PortSession, :fulfill)

        assert decode == %{
                 "id" => "template-file:1",
                 "kind" => "decode_template_file",
                 "bytes_base64" => Base.encode64(bytes)
               }

        assert heap == pending["heap"]
        assert is_integer(timeout) and timeout > 0 and timeout <= 120_000
        assert capture_index < captured_index and captured_index < helper_index

        deadlines =
          for {{:live_deadline_observed, value, at}, index} <- Enum.with_index(events),
              do: {index, value, at}

        assert length(deadlines) == 2

        [{before_capture, capture_deadline, _}, {before_helper, helper_deadline, helper_at}] =
          deadlines

        assert before_capture < capture_index
        assert captured_index < before_helper and before_helper < helper_index
        assert options[:deadline] == capture_deadline
        assert helper_deadline == capture_deadline
        assert timeout <= helper_deadline - helper_at
        assert [{_, {:ok, receipt}}] = returns(events, PortSession, :fulfill, 4)
        assert receipt == Map.put(receipt("template-file:1", "decoded"), "value", string(decoded))
        assert map_size(receipt) == 6
        assert {:complete, result, _} = drive(roundtrip(loaded), session, scope)
        assert result["items"] == [string(expected)]

        assert {:ok, validated} =
                 PortSession.fulfill(
                   session,
                   schema("validate", "validate_response", string(expected)),
                   schema_heap(),
                   15_000
                 )

        assert validated == receipt("validate", "valid")
        assert %{phase: :idle, os_pid: ^pid, cache_entries: 1} = PortSession.status(session)
        assert File.exists?("/proc/#{pid}")
      end
    end)
  end

  defp observed(function) do
    for {module, _, _} = target <- @targets do
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(target, [{:_, [], [{:return_trace}]}], [:local]) > 0
    end

    # Trace a separate observer because self-tracing suppresses trace messages.
    owner = self()
    tracer = spawn(fn -> collect_trace(owner, []) end)
    Process.put(:template_file_tracer, tracer)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = function.()
      barrier = :erlang.trace_delivered(self())

      receive do
        {:trace_delivered, _, ^barrier} -> :ok
      after
        5_000 -> flunk("trace delivery did not drain")
      end

      :erlang.trace(self(), false, [:call])
      send(tracer, {:collect, self()})

      receive do
        {:observed_events, events} -> {result, events}
      after
        5_000 -> flunk("trace observer did not finish")
      end
    after
      :erlang.trace(self(), false, [:call])
      for target <- @targets, do: :erlang.trace_pattern(target, false, [:local])
      Process.delete(:template_file_tracer)
      if Process.alive?(tracer), do: send(tracer, :stop)
    end
  end

  defp collect_trace(owner, events) do
    receive do
      {:collect, ^owner} ->
        # Deadline callback messages originate synchronously in the test process;
        # forward them through the tracer at invocation time for total ordering.
        send(owner, {:observed_events, Enum.reverse(events)})

      :stop ->
        :ok

      event ->
        collect_trace(owner, [event | events])
    end
  end

  defp calls(events, module, function),
    do:
      for(
        {{:trace, _, :call, {^module, ^function, args}}, index} <- Enum.with_index(events),
        do: {index, args}
      )

  defp returns(events, module, function, arity),
    do:
      for(
        {{:trace, _, :return_from, {^module, ^function, ^arity}, value}, index} <-
          Enum.with_index(events),
        do: {index, value}
      )

  defp deadline, do: fn -> {:ok, System.monotonic_time(:millisecond) + 30_000} end
  defp roundtrip(state), do: Jason.decode!(Jason.encode!(state))
  defp string(text), do: %{"type" => "string", "value" => text}
  defp stage(name, args), do: %{"name" => name, "args" => Map.put_new(args, "_", [])}

  defp machine(program, items) do
    assert {:ok, state} =
             Machine.new(program, %{"kind" => "iterator_items", "items" => items}, Value.new(), %{
               "render_output" => false
             })

    state
  end

  defp boundary(state, remaining \\ 2000)
  defp boundary(_state, 0), do: flunk("ordinary transition bound exceeded")

  defp boundary(state, remaining) do
    case Machine.advance(roundtrip(state)) do
      {:continue, next} -> boundary(next, remaining - 1)
      other -> other
    end
  end

  defp segment_boundary(state) do
    case Segment.advance(roundtrip(state)) do
      {:continue, next} -> segment_boundary(next)
      other -> other
    end
  end

  defp drive(state, session, scope) do
    case boundary(state) do
      {:request, request, pending} ->
        transition =
          case request["kind"] do
            "read_template_file" -> Template.advance_file(session, pending, scope, deadline())
            "render_template" -> Template.advance_pending(session, pending, 15_000)
          end

        assert {:continue, next} = transition
        drive(next, session, scope)

      other ->
        other
    end
  end

  defp with_session(helper, function) do
    session =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
         helper_path: helper},
        id: make_ref()
      )

    assert %{phase: :dormant, os_pid: nil} = PortSession.status(session)

    try do
      function.(session)

      assert {:ok, %{cleanup_confirmed: true, exit_status: 0, os_pid: pid}} =
               PortSession.close(session)

      refute File.exists?("/proc/#{pid}")
    after
      if Process.alive?(session), do: PortSession.close(session)
    end
  end

  defp receipt(id, outcome),
    do: %{
      "type" => "result",
      "id" => id,
      "result" => "ok",
      "outcome" => outcome,
      "cacheEntries" => 1
    }

  defp schema(id, kind, response \\ nil) do
    request = %{"id" => id, "kind" => kind, "schema" => %{"type" => "reference", "id" => "1"}}
    if kind == "validate_response", do: Map.put(request, "response", response), else: request
  end

  defp schema_heap,
    do: %{
      "version" => 1,
      "next_id" => 2,
      "nodes" => %{
        "1" => %{
          "type" => "object",
          "keys" => ["type"],
          "fields" => %{"type" => string("string")}
        }
      }
    }
end
