defmodule Synapsis.Session.NativeFilesystemFactoryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.Filesystem
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir
  @names ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @node System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
  @fixtures Path.expand("../../fixtures/openclaw/488631c", __DIR__)
  @edits [
    %{"oldText" => "alpha", "newText" => "beta"},
    %{"oldText" => "beta", "newText" => "BETA"}
  ]

  setup %{tmp_dir: root} do
    previous_node = Application.fetch_env(:synapsis_agent, :filesystem_node)
    previous_workspace = System.get_env("SYNAPSIS_WORKSPACE_ROOT")
    workspace = Path.join(root, "captured-workspace")
    File.mkdir_p!(workspace)
    Application.put_env(:synapsis_agent, :filesystem_node, @node)
    System.put_env("SYNAPSIS_WORKSPACE_ROOT", workspace)

    on_exit(fn ->
      case previous_node do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end

      if previous_workspace,
        do: System.put_env("SYNAPSIS_WORKSPACE_ROOT", previous_workspace),
        else: System.delete_env("SYNAPSIS_WORKSPACE_ROOT")
    end)

    %{workspace_root: workspace}
  end

  for namespace <- [:local, :workspace] do
    @namespace namespace

    test "#{namespace} canonical filesystem success crosses Worker, provider, Parts and Concord",
         ctx do
      harness = setup_harness(ctx.tmp_dir)
      {physical, public} = target_directory(@namespace, ctx, harness)
      seed(physical)
      calls = calls(public)
      expected = expected_results(public)
      owner = self()

      Gaoxy.Test.stub(harness.provider.fixture, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request = Jason.decode!(body)

        index =
          Agent.get_and_update(harness.counter, fn state ->
            {length(state.provider_requests),
             %{state | provider_requests: state.provider_requests ++ [request]}}
          end)

        send(owner, {:filesystem_request, index, request})

        if index == 0 do
          send(owner, {:filesystem_runtime, runtime(harness.session.id)})
        end

        case Enum.at(calls, index) do
          nil -> answer(conn)
          {id, name, arguments, _prepared} -> function_call(conn, id, name, arguments)
        end
      end)

      SessionHarness.subscribe!(harness.session.id)
      SessionHarness.ensure_running!(harness.session.id)
      assert :ok = Worker.switch_model(harness.session.id, harness.provider.name, "gpt-4o")
      assert :ok = Worker.send_message(harness.session.id, "Use the selected filesystem tools")
      assert_receive {:filesystem_request, 0, first}, 5_000
      assert_receive {:filesystem_runtime, runtime}, 5_000
      assert first["model"] == "gpt-4o"

      assert Enum.sort(Enum.map(first["tools"], &ToolName.decode(&1["name"]))) ==
               Enum.sort(@names)

      for name <- @names do
        descriptor = runtime.catalog.registry.tools[name]
        context = descriptor.backend_context
        assert descriptor.backend == Filesystem
        assert descriptor.tool_revision == 1
        assert context.root == ctx.tmp_dir
        assert context.run_id == runtime.run_id
        assert context.incarnation == runtime.incarnation
        assert context.catalog_revision == runtime.catalog.revision

        assert context.workspace == %{
                 role: :session,
                 agent_id: harness.agent_name,
                 session_id: harness.session.id
               }

        assert context.path_environment == %{
                 cwd: ctx.tmp_dir,
                 os_home: System.user_home(),
                 platform: platform(),
                 workspace_root: ctx.workspace_root
               }

        assert is_function(context.prepared_target_resolver, 3)
        assert context.execution_options[:node_executable] == @node
        assert context.execution_options[:model_has_vision] == true
      end

      requests =
        for index <- 1..length(calls) do
          assert_receive {:filesystem_request, ^index, request}, 10_000
          request
        end

      assert_receive {:run_event, %{type: "session.completed"}}, 10_000
      assert File.read!(Path.join(physical, "write.txt")) == "new\n"
      assert File.read!(Path.join(physical, "edit.txt")) == "beta\nBETA\ngamma\n"

      parts = tool_parts(harness.session.id)
      uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
      results = Enum.filter(parts, &match?(%ToolResult{}, &1))
      assert Enum.map(uses, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))
      assert Enum.map(uses, & &1.tool) == Enum.map(calls, &elem(&1, 1))
      assert Enum.map(uses, & &1.input) == Enum.map(calls, &elem(&1, 2))
      assert Enum.map(results, & &1.tool_use_id) == Enum.map(calls, &elem(&1, 0))

      for {{id, _name, _raw, _prepared}, result} <- Enum.zip(calls, results) do
        assert result.is_error == false
        assert result.projection == %{"version" => 1, "result" => expected[id]}
        assert result.content == Enum.map_join(expected[id]["content"], "\n", & &1["text"])
      end

      for {request, count} <- Enum.with_index(requests, 1) do
        assert_wire_history(request, Enum.take(uses, count), Enum.take(results, count))
      end

      assert_durable_parts(harness.session.id, uses, results)

      for part <- parts do
        assert {:ok, dump} = Synapsis.Part.dump(part)
        assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
      end

      assert {:ok, aggregate} =
               Synapsis.Runtime.Store.load(runtime.store.namespace, runtime.run_id)

      operations =
        for {_, intent} <- aggregate.run.execution_intents,
            intent.type == :tool,
            do: intent.operation

      assert length(operations) == length(calls)

      for {id, name, _raw, prepared} <- calls do
        operation = Enum.find(operations, &(&1.tool_call_id == id))
        assert operation.tool_name == name
        assert operation.arguments == prepared
      end
    end
  end

  defp setup_harness(root) do
    harness =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      case Synapsis.Providers.get_by_name(harness.provider.name) do
        {:ok, provider} -> Synapsis.Providers.delete(provider.id)
        {:error, :not_found} -> :ok
      end
    end)

    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: @names})

    assert {:ok, _} =
             Synapsis.Providers.create(%{
               name: harness.provider.name,
               type: "openai_responses",
               base_url: harness.provider.base_url,
               api_key_encrypted: "test-key"
             })

    # The real runtime's normal all-allow setup is a prerequisite, not a policy test.
    permission = Store.get_value(harness.session.id, "permission")

    assert :ok =
             Store.put_value(harness.session.id, "permission", %{
               permission
               | tool_contract_version: 1,
                 allow_read: :allow,
                 allow_write: :allow,
                 allow_execute: :allow,
                 allow_destructive: :allow
             })

    harness
  end

  defp target_directory(:local, ctx, _harness), do: {Path.join(ctx.tmp_dir, "files"), "files"}

  defp target_directory(:workspace, ctx, harness) do
    logical = "agents/#{harness.agent_name}/sessions/#{harness.session.id}/files"
    {Path.join(ctx.workspace_root, logical), "@synapsis/" <> logical}
  end

  defp seed(root) do
    File.mkdir_p!(Path.join(root, "listing/z dir"))
    File.write!(Path.join(root, "lines.txt"), "alpha\nbeta\ngamma\n")
    File.write!(Path.join(root, "unicode.txt"), "A😀中B\n尾\n")
    File.write!(Path.join(root, "edit.txt"), "alpha\nbeta\ngamma\n")
    File.write!(Path.join(root, "listing/.hidden"), "hidden")
    File.write!(Path.join(root, "listing/A.txt"), "A")
  end

  defp calls(public) do
    lines = %{"path" => public <> "/lines.txt", "offset" => 2, "limit" => 1}
    unicode = %{"path" => public <> "/unicode.txt", "cursor" => 3, "limit" => 1}
    write = %{"path" => public <> "/write.txt</arg_value>>", "content" => "new\n"}
    prepared_write = %{write | "path" => public <> "/write.txt"}

    edit = %{
      "path" => public <> "/edit.txt",
      "edits" => Jason.encode!(Enum.map(@edits, &Map.put(&1, "note", "source projection"))),
      "note" => "original model argument"
    }

    prepared_edit = %{"path" => public <> "/edit.txt", "edits" => @edits}
    ls = %{"path" => public <> "/listing"}

    [
      {"fs-lines", "synapsis::read", lines, lines},
      {"fs-unicode", "synapsis::read", unicode, unicode},
      {"fs-write", "synapsis::write", write, prepared_write},
      {"fs-edit", "synapsis::edit", edit, prepared_edit},
      {"fs-ls", "synapsis::ls", ls, ls}
    ]
  end

  defp expected_results(public) do
    write_path = public <> "/write.txt"
    edit_path = public <> "/edit.txt"
    write_receipt = fixture_case("edit-plans", "write-create")
    edit_receipt = fixture_case("edit-plans", "original-snapshot")["receipt"]

    %{
      "fs-lines" => read_result(fixture_case("read-pages", "one-based-slice")),
      "fs-unicode" => read_result(fixture_case("read-pages", "utf16-selected-slice")),
      "fs-write" =>
        result(
          "Successfully wrote 4 bytes to " <> write_path,
          write_receipt
          |> Map.update!("patch", &String.replace(&1, "write.txt", write_path))
          |> Map.merge(%{"changed" => true, "created" => true})
        ),
      "fs-edit" =>
        result(
          "Successfully replaced 2 block(s) in " <> edit_path <> ".",
          edit_receipt
          |> Map.update!("patch", &String.replace(&1, "edit.txt", edit_path))
          |> Map.put("changed", true)
        ),
      "fs-ls" =>
        result("\".hidden\"\n\"A.txt\"\n\"z dir/\"", %{
          "content" => "\".hidden\"\n\"A.txt\"\n\"z dir/\""
        })
    }
  end

  defp fixture_case(file, id) do
    @fixtures
    |> Path.join(file <> ".json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("cases")
    |> Enum.find(&(&1["id"] == id))
    |> Map.fetch!("result")
  end

  defp read_result(captured), do: result(captured["text"], captured["details"])

  defp result(text, details),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "details" => details,
      "is_error" => false
    }

  defp platform do
    case :os.type() do
      {:unix, :darwin} -> :darwin
      {:win32, _} -> :win32
      {:unix, _} -> :linux
    end
  end

  defp runtime(id) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {_, data} = :sys.get_state(worker, 1_000)
    state = :sys.get_state(data.runtime_pid, 1_000)

    %{
      catalog: :sys.get_state(state.root, 1_000).catalog,
      run_id: state.run_id,
      incarnation: state.binding.run_incarnation,
      store: state.store
    }
  end

  defp tool_parts(id) do
    for message <- Synapsis.Sessions.get_messages(id),
        part <- message.parts,
        match?(%ToolUse{}, part) or match?(%ToolResult{}, part),
        do: part
  end

  defp assert_durable_parts(id, uses, results) do
    assert {:ok, turns} = Store.list_turns(id)

    durable =
      for turn <- turns, part <- turn.parts, part[:type] in ~w(tool_use tool_result), do: part

    assert Enum.count(durable, &(&1[:type] == "tool_use")) == length(uses)
    assert Enum.count(durable, &(&1[:type] == "tool_result")) == length(results)

    for use <- uses do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_use" and &1[:id] == use.tool_use_id and &1[:name] == use.tool and
                   &1[:input] == use.input)
             )
    end

    for result <- results do
      assert Enum.any?(
               durable,
               &(&1[:type] == "tool_result" and &1[:tool_use_id] == result.tool_use_id and
                   &1[:projection] == result.projection and &1[:content] == result.content and
                   &1[:is_error] == false)
             )
    end
  end

  defp assert_wire_history(request, uses, results) do
    for use <- uses do
      assert Enum.any?(
               request["input"],
               &(&1["type"] == "function_call" and &1["call_id"] == use.tool_use_id and
                   ToolName.decode(&1["name"]) == use.tool and
                   Jason.decode!(&1["arguments"]) == use.input)
             )
    end

    for result <- results do
      assert %{
               "type" => "function_call_output",
               "call_id" => result.tool_use_id,
               "output" => result.content
             } in request["input"]
    end
  end

  defp function_call(conn, id, name, arguments) do
    encoded = Jason.encode!(arguments)

    item = %{
      "type" => "function_call",
      "id" => id <> "-item",
      "call_id" => id,
      "name" => ToolName.encode(name),
      "arguments" => encoded
    }

    sse(conn, [
      %{
        "type" => "response.output_item.added",
        "output_index" => 0,
        "item" => Map.put(item, "arguments", "")
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => item["id"],
        "delta" => encoded
      },
      %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
      completed([item])
    ])
  end

  defp answer(conn),
    do:
      sse(conn, [
        %{"type" => "response.output_text.delta", "delta" => "Filesystem complete"},
        completed([])
      ])

  defp completed(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"status" => "completed", "output" => output}
    }

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )
end
