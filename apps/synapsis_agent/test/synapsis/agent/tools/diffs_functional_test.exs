defmodule Synapsis.Agent.Tools.DiffsFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.DiffsDelivery
  alias Synapsis.Agent.Tools.{Diffs, Policy, Profiles}
  alias Synapsis.Config.Store, as: ConfigStore
  alias Synapsis.Diffs.PortSession
  alias Synapsis.Session.Store

  @moduletag timeout: 150_000
  @name "synapsis::diffs"
  @arguments %{
    "before" => "const value = 1;\n",
    "after" => "const value = 2;\n",
    "path" => "src/value.ts",
    "lang" => "TS",
    "title" => "Value update"
  }
  @traced [
    {PortSession, :start_link, 1},
    {PortSession, :render, 3},
    {PortSession, :close, 1},
    {ResourceRegistry, :register, 5},
    {ResourceRegistry, :release, 3},
    {DiffsDelivery, :publish_viewer, 4},
    {DiffsDelivery, :reserve_file, 3}
  ]

  defmodule Provider do
    def stream(request, %{observer: observer}) do
      send(observer, {:diffs_provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          after
            120_000 -> raise "ordinary Diffs provider response was not supplied"
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule ObservedPolicy do
    def prepare_tool(invocation, context) do
      result = Policy.prepare_tool(invocation, context)
      send(context.fixture_observer, {:diffs_prepared, invocation, result})
      result
    end

    def tool_effect_timeout(invocation, context) do
      result = Policy.tool_effect_timeout(invocation, context)
      send(context.fixture_observer, {:diffs_effect_timeout, result})
      result
    end
  end

  setup do
    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-diffs359-native-#{System.get_env("MIX_TEST_PARTITION", "0")}",
        Ecto.UUID.generate()
      ])

    File.mkdir_p!(root)
    previous = ConfigStore.get(:diffs, "default")

    assert {:ok, _} =
             ConfigStore.put(:diffs, %{
               "id" => "default",
               "viewerBaseUrl" => "https://diffs.example/review",
               "host" => %{
                 "nodeExecutable" => System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
                 "chromiumExecutable" => System.fetch_env!("SYNAPSIS_DIFFS_CHROMIUM"),
                 "artifactRoot" => Path.join(root, "artifacts"),
                 "timeoutMs" => 120_000
               }
             })

    on_exit(fn ->
      case previous do
        {:ok, record} -> ConfigStore.put(:diffs, record)
        {:error, :not_found} -> ConfigStore.delete(:diffs, "default")
      end

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "selected descriptor retains the exact public source schema and native effect policy", %{
    root: root
  } do
    fixture = fixture(root)
    descriptor = fixture.bundle.registry.tools[@name]
    assert @name in Profiles.supported_names()
    assert Diffs.names() == [@name]
    assert Diffs.permission_level(@name) == :execute
    assert descriptor.backend == Diffs
    assert descriptor.tool_revision == 1
    assert descriptor.codex_exposure == :direct_model_only
    assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert descriptor.schema["additionalProperties"] == false

    assert Enum.sort(Map.keys(descriptor.schema["properties"])) ==
             Enum.sort(
               ~w(before after patch path lang title mode theme layout fileQuality fileFormat fileScale fileMaxWidth expandUnchanged ttlSeconds baseUrl)
             )

    assert descriptor.schema["properties"]["mode"]["enum"] == ~w(view image file both)
    assert descriptor.schema["properties"]["fileFormat"]["enum"] == ~w(png pdf)

    assert {:ok, []} =
             Diffs.bundles(
               fixture.context,
               fixture.identity,
               fixture.authority,
               [],
               fixture.binding
             )

    result = invoke(fixture, Map.put(@arguments, "mode", "view"))
    assert result["details"]["mode"] == "view"
    assert_receive {:diffs_prepared, invocation, :allow}, 5_000
    assert invocation.tool_name == @name
    assert invocation.arguments == Map.put(@arguments, "mode", "view")
    assert_receive {:diffs_effect_timeout, {:ok, timeout}}, 5_000
    assert is_integer(timeout) and timeout > 0
    finish(fixture)
  end

  test "identical source text returns the source result without starting a renderer", %{
    root: root
  } do
    fixture = fixture(root)
    trace_renderer()
    result = invoke(fixture, %{"before" => "same\n", "after" => "same\n"})

    assert result["content"] == [
             %{
               "type" => "text",
               "text" => "Before and after are identical — no changes to render."
             }
           ]

    assert result["details"] == %{
             "changed" => false,
             "context" => %{
               "agentId" => fixture.agent.id,
               "sessionId" => fixture.identity.session_id
             }
           }

    finish(fixture)
    events = traces()

    assert Enum.filter(events, fn event ->
             match?({:trace, _, :call, {PortSession, _, _}}, event)
           end) == []

    assert Path.wildcard(Path.join(root, "artifacts/*")) == []
  end

  test "view publishes actual source HTML and respects a request URL prefix", %{root: root} do
    fixture = fixture(root)
    trace_renderer()

    input =
      Map.merge(@arguments, %{
        "mode" => "view",
        "baseUrl" => "https://request.example/prefix/",
        "ttlSeconds" => 2400
      })

    result = invoke(fixture, input)
    details = assert_common(result, fixture, "view")
    assert details["viewerUrl"] == "https://request.example/prefix" <> details["viewerPath"]

    assert result["content"] == [
             %{"type" => "text", "text" => "Diff viewer ready.\n#{details["viewerUrl"]}"}
           ]

    assert_viewer(details)
    finish(fixture)
    assert_normal_resources(traces(), fixture, ["viewer"], false)
  end

  for {mode, format} <- [{"file", "png"}, {"file", "pdf"}, {"image", "png"}] do
    test "#{mode} returns a real #{format} file and source attachment instruction", %{root: root} do
      fixture = fixture(root)
      trace_renderer()
      mode = unquote(mode)
      format = unquote(format)
      result = invoke(fixture, Map.merge(@arguments, %{"mode" => mode, "fileFormat" => format}))
      details = assert_common(result, fixture, mode)

      assert result["content"] == [
               %{
                 "type" => "text",
                 "text" =>
                   "Diff #{String.upcase(format)} generated at: #{details["filePath"]}\nTo send this file, use an available file-sending tool to send it as an attachment."
               }
             ]

      bytes = assert_file(details, fixture, format)
      if format == "pdf", do: assert_pdf_text(bytes)
      finish(fixture)
      assert_normal_resources(traces(), fixture, ["image"], true)
    end
  end

  test "both publishes the viewer before independent PNG registration through one helper", %{
    root: root
  } do
    fixture = fixture(root)
    trace_renderer()
    result = invoke(fixture, @arguments)
    details = assert_common(result, fixture, "both")
    assert details["viewerUrl"] == "https://diffs.example/review" <> details["viewerPath"]

    assert result["content"] == [
             %{
               "type" => "text",
               "text" =>
                 "Diff viewer: #{details["viewerUrl"]}\nDiff PNG generated at: #{details["filePath"]}\nTo send this file, use an available file-sending tool to send it as an attachment."
             }
           ]

    viewer = assert_viewer(details)
    assert_file(details, fixture, "png")
    reference = details["fileDelivery"]
    assert {:ok, file} = DiffsDelivery.read_file(reference["session_id"], reference["id"], [])
    assert viewer.record.public_id != file.record.public_id
    assert details["artifactId"] == viewer.record.public_id

    assert details["expiresAt"] ==
             DateTime.to_iso8601(DateTime.from_unix!(viewer.record.expires_at, :millisecond))

    assert details["fileExpiresAt"] ==
             DateTime.to_iso8601(DateTime.from_unix!(file.record.expires_at, :millisecond))

    assert viewer.record.expires_at - viewer.record.created_at == 1_800_000
    assert file.record.expires_at - file.record.created_at == 1_800_000
    finish(fixture)
    events = traces()
    assert_normal_resources(events, fixture, ["viewer", "image"], true)

    published =
      Enum.find_index(
        events,
        &match?({:trace, _, :return_from, {DiffsDelivery, :publish_viewer, 4}, {:ok, _}}, &1)
      )

    reserved =
      Enum.find_index(events, &match?({:trace, _, :call, {DiffsDelivery, :reserve_file, _}}, &1))

    assert is_integer(published) and is_integer(reserved) and published < reserved
    plans = for {:trace, _, :call, {PortSession, :render, [_, plan, _]}} <- events, do: plan
    assert [first, second] = plans
    assert first["input"] == second["input"]
    assert first["options"] == second["options"]
    assert first["context"] == second["context"]
  end

  test "ordinary patch with unchanged expansion disabled publishes viewer and PNG", %{root: root} do
    fixture = fixture(root)
    trace_renderer()

    patch =
      Enum.join(
        [
          "diff --git a/src/value.ts b/src/value.ts",
          "--- a/src/value.ts",
          "+++ b/src/value.ts",
          "@@ -1 +1 @@",
          "-const value = 1;",
          "+const value = 2;"
        ],
        "\n"
      )

    result =
      invoke(fixture, %{
        "patch" => patch,
        "title" => "Value update",
        "mode" => "both",
        "expandUnchanged" => false
      })

    details = result["details"]
    assert details["changed"] == true
    assert details["mode"] == "both"
    assert details["inputKind"] == "patch"
    assert details["title"] == "Value update"
    assert details["fileCount"] == 1

    assert details["context"] == %{
             "agentId" => fixture.agent.id,
             "sessionId" => fixture.identity.session_id
           }

    assert result["content"] == [
             %{
               "type" => "text",
               "text" =>
                 "Diff viewer: #{details["viewerUrl"]}\nDiff PNG generated at: #{details["filePath"]}\nTo send this file, use an available file-sending tool to send it as an attachment."
             }
           ]

    assert_viewer(details)
    assert_file(details, fixture, "png")
    finish(fixture)
    events = traces()
    assert_normal_resources(events, fixture, ["viewer", "image"], true)
    plans = for {:trace, _, :call, {PortSession, :render, [_, plan, _]}} <- events, do: plan
    assert [first, second] = plans
    assert first["input"] == %{"kind" => "patch", "patch" => patch, "title" => "Value update"}
    assert first["options"]["expandUnchanged"] == false
    assert first["input"] == second["input"]
    assert first["options"] == second["options"]
  end

  defp fixture(root) do
    assert :ok = Store.ensure_started()
    session_id = Ecto.UUID.generate()

    assert {:ok, agent} =
             Synapsis.AgentConfigs.create(%{
               name: "diffs-#{Ecto.UUID.generate()}",
               tools: [@name],
               tool_contract_version: 1,
               permission_mode: "yolo",
               config: %{"workspace_path" => root}
             })

    on_exit(fn ->
      for path <- Path.wildcard(Path.join(root, "artifacts/*")) do
        case Synapsis.Diffs.ArtifactStore.lookup(
               Path.basename(path),
               System.system_time(:millisecond),
               System.monotonic_time(:millisecond) + 5_000
             ) do
          {:ok, record} -> DiffsDelivery.remove_artifact(record, [])
          _ -> :ok
        end
      end

      Synapsis.AgentConfigs.delete(agent)
      Store.delete_session(session_id)
    end)

    assert :ok =
             Store.put_value(session_id, "permission", %Synapsis.SessionPermission{
               session_id: session_id,
               tool_contract_version: 1,
               mode: :autonomous,
               allow_read: :allow,
               allow_write: :allow,
               allow_execute: :allow
             })

    identity = %{
      caller: "synapsis:" <> session_id,
      session_id: session_id,
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      catalog_revision: 1
    }

    authority = %{
      caller: identity.caller,
      run_id: identity.run_id,
      grants: [@name],
      tool_revision: 1,
      tool_revisions: %{@name => 1}
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: Map.from_struct(agent),
      project_path: root,
      tool_session_binding: binding
    }

    assert {:ok, bundles} = Diffs.bundles(context, identity, authority, [@name], binding)

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(context, identity, bundles, authority)

    assert {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: identity.run_id,
         incarnation: 1,
         session_binding: binding,
         registry: bundle.registry,
         tools: bundle.tools,
         authority: bundle.authority,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{observer: self()},
         hooks: ObservedPolicy,
         host_context: %{
           fixture_observer: self(),
           tool_context_resolver: fn invocation, catalog ->
             Profiles.project_catalog(invocation, snapshot, catalog)
           end
         },
         schema_admission: :strict,
         work: 8,
         run_timeout: 140_000,
         effect_timeout: 120_000,
         commit_timeout: 5_000,
         cleanup_timeout: 15_000}
      )

    %{
      conversation: conversation,
      session: session,
      binding: binding,
      identity: identity,
      authority: authority,
      context: context,
      bundle: bundle,
      agent: agent
    }
  end

  defp invoke(fixture, input) do
    assert {:ok, _} = Conversation.prompt(fixture.conversation, "Render the ordinary comparison")
    assert_receive {:diffs_provider, request, provider}, 5_000
    assert Enum.map(request.tools, & &1.name) == [@name]
    call = %{id: "ordinary-diffs", name: @name, arguments: input}

    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: call},
         %{
           type: :response_completed,
           message: %{role: :assistant, content: "Compare values", tool_calls: [call]}
         }
       ]}
    )

    assert_receive {:diffs_provider, following, next_provider}, 120_000
    assert [result] = Enum.filter(following.messages, &(&1[:role] == :tool))
    assert result.tool_call_id == "ordinary-diffs"
    assert result.result[:is_error] != true

    send(
      next_provider,
      {:events,
       [
         %{
           type: :response_completed,
           message: %{role: :assistant, content: "Comparison received"}
         }
       ]}
    )

    await_complete(fixture.conversation, System.monotonic_time(:millisecond) + 10_000)
    result.result |> Jason.encode!() |> Jason.decode!()
  end

  defp finish(fixture) do
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)
  end

  defp await_complete(pid, deadline) do
    case Conversation.status(pid) do
      %{phase: :terminal, run: %{state: :completed}, resource_cleanup: :confirmed} ->
        :ok

      status ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(status)
        Process.sleep(5)
        await_complete(pid, deadline)
    end
  end

  defp assert_common(result, fixture, mode) do
    details = result["details"]
    assert details["changed"] == true
    assert details["mode"] == mode
    assert details["title"] == "Value update"
    assert details["inputKind"] == "before_after"
    assert details["fileCount"] == 1

    assert details["context"] == %{
             "agentId" => fixture.agent.id,
             "sessionId" => fixture.identity.session_id
           }

    assert Regex.match?(~r/\A[0-9a-f]{20}\z/, details["artifactId"])
    assert {:ok, _, 0} = DateTime.from_iso8601(details["expiresAt"])
    assert Enum.all?(result["content"], &(&1["type"] == "text"))
    details
  end

  defp assert_viewer(details) do
    assert ["", "plugins", "diffs", "view", id, token] = String.split(details["viewerPath"], "/")
    assert details["artifactId"] == id
    assert {:ok, viewer} = DiffsDelivery.read_viewer(id, token, [])
    assert viewer.bytes =~ "Value update"
    assert viewer.bytes =~ "src/value.ts"
    assert viewer.bytes =~ "data-openclaw-diff-payload"
    assert viewer.bytes =~ "const value = 1;"
    assert viewer.bytes =~ "const value = 2;"
    viewer
  end

  defp assert_file(details, fixture, format) do
    assert details["path"] == details["filePath"]
    assert Path.basename(details["path"]) == "preview.#{format}"
    assert details["fileFormat"] == format
    assert details["fileQuality"] == "standard"
    assert details["fileScale"] == 2
    assert details["fileMaxWidth"] == 960
    assert details["fileDelivery"]["session_id"] == fixture.identity.session_id
    ref = details["fileDelivery"]
    assert {:ok, file} = DiffsDelivery.read_file(ref["session_id"], ref["id"], [])
    assert file.bytes == File.read!(details["filePath"])
    assert byte_size(file.bytes) == details["fileBytes"]

    assert {:ok, attachment} =
             DiffsDelivery.resolve_attachment(ref["session_id"], details["filePath"], [])

    assert attachment.bytes == file.bytes

    if format == "png",
      do: assert(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = file.bytes),
      else: assert(<<"%PDF-", _::binary>> = file.bytes)

    file.bytes
  end

  defp trace_renderer do
    for {module, function, arity} <- @traced do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern({module, function, arity}, [{:_, [], [{:return_trace}]}], [:local])
    end

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      for {m, f, a} <- @traced, do: :erlang.trace_pattern({m, f, a}, false, [:local])
    end)
  end

  defp traces do
    ref = :erlang.trace_delivered(:all)
    assert_receive {:trace_delivered, :all, ^ref}, 5_000
    drain_traces([])
  end

  defp drain_traces(acc) do
    receive do
      {:trace, _, _, _} = event -> drain_traces([event | acc])
      {:trace, _, _, _, _} = event -> drain_traces([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_normal_resources(events, fixture, targets, browser?) do
    assert [{:trace, _, :return_from, {PortSession, :start_link, 1}, {:ok, broker}}] =
             Enum.filter(
               events,
               &match?({:trace, _, :return_from, {PortSession, :start_link, 1}, _}, &1)
             )

    assert Enum.map(
             for(
               {:trace, _, :call, {PortSession, :render, [^broker, plan, _]}} <- events,
               do: plan
             ),
             & &1["renderTarget"]
           ) == targets

    assert [
             {:trace, _, :call,
              {ResourceRegistry, :register, [registry, owner, :diffs, ^broker, opts]}}
           ] =
             Enum.filter(
               events,
               &match?(
                 {:trace, _, :call, {ResourceRegistry, :register, [_, _, :diffs, _, _]}},
                 &1
               )
             )

    assert registry == fixture.binding.resource_registry
    assert owner == fixture.binding.owner_id
    assert opts[:owner_pid] == fixture.binding.owner_pid
    assert opts[:incarnation] == fixture.binding.incarnation

    assert [{:trace, _, :return_from, {ResourceRegistry, :register, 5}, {:ok, handle}}] =
             Enum.filter(
               events,
               &match?({:trace, _, :return_from, {ResourceRegistry, :register, 5}, {:ok, _}}, &1)
             )

    assert Enum.any?(
             events,
             &match?(
               {:trace, _, :call, {ResourceRegistry, :release, [^registry, ^handle, ^owner]}},
               &1
             )
           )

    closed =
      for {:trace, _, :return_from, {PortSession, :close, 1}, {:ok, state}} <- events, do: state

    assert [state | _] = closed
    assert state.cleanup_confirmed and state.worker_closed and state.exit_status == 0
    assert state.sequence == length(targets)
    assert is_integer(state.os_pid)
    refute File.exists?("/proc/#{state.os_pid}")

    if browser? do
      assert is_integer(state.browser_pid)
      assert state.browser_exit == %{"pid" => state.browser_pid, "code" => 0, "signal" => nil}
      refute File.exists?("/proc/#{state.browser_pid}")
    else
      assert state.browser_pid == nil
    end

    refute Process.alive?(broker)
    assert {:ok, %{status: :confirmed}} = ResourceRegistry.cleanup_status(registry, handle, owner)
  end

  defp assert_pdf_text(bytes) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"))},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :eof,
          args:
            Enum.map(
              [System.fetch_env!("SYNAPSIS_DIFFS_PDF_HELPER"), "--port", "--timeout-ms=15000"],
              &String.to_charlist/1
            )
        ]
      )

    true =
      Port.command(
        port,
        Jason.encode!(%{"pdfBase64" => Base.encode64(bytes), "minTextChars" => 1}) <> "\n"
      )

    result = port_result(port, []) |> Jason.decode!()
    assert result["metadata"]["pages"]["processed"] == [1]
    text = String.replace(result["text"], ~r/\s/u, "")

    for literal <- ["src/value.ts", "const value = 1;", "const value = 2;"],
        do: assert(text =~ String.replace(literal, ~r/\s/u, ""))
  end

  defp port_result(port, acc) do
    receive do
      {^port, {:data, bytes}} -> port_result(port, [bytes | acc])
      {^port, :eof} -> port_result(port, acc)
      {^port, {:exit_status, 0}} -> acc |> Enum.reverse() |> IO.iodata_to_binary()
      {^port, {:exit_status, code}} -> flunk("PDF observer exit #{code}")
    after
      16_000 ->
        Port.close(port)
        flunk("PDF observer did not complete")
    end
  end
end
