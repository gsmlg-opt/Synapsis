defmodule Synapsis.Session.NativePDFFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.ResourceRegistry
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.{PDF, Profiles}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.PDF.PortSession
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{AgentConfigs, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::pdf"
  @analysis "The ordinary report has a red second page and a blue fourth page."
  @root Path.expand("../../../../..", __DIR__)
  @fixture Path.join(@root, "apps/synapsis_core/test/fixtures/pdf/ordinary.pdf")

  test "selected PDF acquires binary bytes, analyzes actual ordered PNGs and persists final analysis across Worker restart",
       %{tmp_dir: root} do
    harness = harness(root)
    install(harness, %{"pdf" => Gaoxy.Test.url(harness.provider.fixture, "/ordinary.pdf")})
    trace_extraction()
    start(harness)
    assert_receive {:pdf_outer, 0, initial}, 5_000
    assert_receive {:pdf_descriptor, descriptor}, 5_000
    assert descriptor.backend == PDF
    assert descriptor.codex_exposure == :direct_model_only
    assert [%{"name" => name, "input_schema" => schema}] = initial["tools"]
    assert ToolName.decode(name) == @name
    assert schema == descriptor.schema
    assert @name in Profiles.supported_names()
    assert length(Profiles.supported_names()) == 57

    assert_receive {:pdf_analysis, handler, request}, 20_000
    assert request["model"] == "gpt-4o"
    assert request["max_tokens"] == 4096
    assert [%{"role" => "user", "content" => [text, red, blue, prompt]}] = request["messages"]
    assert text["type"] == "text"
    assert text["text"] =~ "[PDF text]"
    assert text["text"] =~ "First dense page ordinary document."
    assert text["text"] =~ "Third dense page ordinary document."
    assert text["text"] =~ "Red sparse second page"
    assert prompt == %{"type" => "text", "text" => "Analyze this PDF document."}
    assert_png_color(red, {255, 0, 0})
    assert_png_color(blue, {0, 0, 255})
    assert_registered_cleanup(descriptor.backend_context.session_binding)
    send(handler, :release_analysis)

    assert_receive {:pdf_outer, 1, following}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    [use, result] = pdf_parts(harness.session.id)
    assert %ToolUse{tool: @name, tool_use_id: "ordinary-pdf"} = use
    assert %ToolResult{is_error: false, tool_use_id: "ordinary-pdf"} = result
    assert result.content =~ @analysis
    assert result.projection["result"]["native"] == false
    assert result.projection["result"]["model"] == harness.analysis.name <> "/gpt-4o"
    assert [provenance] = result.projection["result"]["provenance"]

    assert provenance["resolved_input"] ==
             Gaoxy.Test.url(harness.provider.fixture, "/ordinary.pdf")

    assert_final_only(result)
    assert_final_wire(following)
    assert_round_trip_and_store(harness.session.id, [use, result])

    [{old, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    monitor = Process.monitor(old)
    assert :ok = DynamicSupervisor.stop_session(harness.session.id)
    assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
    SessionHarness.ensure_running!(harness.session.id)
    [{new, _}] = Registry.lookup(Synapsis.Session.Registry, harness.session.id)
    refute new == old
    assert :ok = Worker.send_message(harness.session.id, "Recall the completed PDF report")
    assert_receive {:pdf_outer, 2, replay}, 10_000
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    assert_final_wire(replay)
    assert pdf_parts(harness.session.id) == [use, result]
    assert_round_trip_and_store(harness.session.id, [use, result])
    assert %{acquisitions: 1, analyses: 1, outer: 3} = Agent.get(harness.counter, & &1)
  end

  test "multiple documents deduplicate in order and explicit pages use the admitted override with truncation notices",
       %{tmp_dir: root} do
    harness = harness(root, %{"pdfMaxPages" => 2})
    File.cp!(@fixture, Path.join(root, "first.pdf"))
    File.cp!(@fixture, Path.join(root, "second.pdf"))
    override = harness.analysis.name <> "/gpt-4o-mini"

    install(harness, %{
      "pdf" => " first.pdf ",
      "pdfs" => ["second.pdf", "first.pdf"],
      "pages" => "4,2,1-3",
      "model" => override,
      "prompt" => "Compare the selected pages"
    })

    start(harness)
    assert_receive {:pdf_analysis, handler, request}, 20_000
    assert request["model"] == "gpt-4o-mini"

    assert [%{"role" => "user", "content" => [first, red1, second, red2, prompt]}] =
             request["messages"]

    for {text, label} <- [{first, "[PDF 1 text]"}, {second, "[PDF 2 text]"}] do
      assert text["text"] =~ label
      assert text["text"] =~ "requested page selection limited to 2 pages"
      assert text["text"] =~ "First dense page ordinary document."
      refute text["text"] =~ "Third dense page ordinary document."
    end

    assert_png_color(red1, {255, 0, 0})
    assert_png_color(red2, {255, 0, 0})
    assert prompt == %{"type" => "text", "text" => "Compare the selected pages"}
    send(handler, :release_analysis)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    [_, result] = pdf_parts(harness.session.id)
    assert result.is_error == false

    assert Enum.map(result.projection["result"]["provenance"], & &1["rewritten_from"]) == [
             "first.pdf",
             "second.pdf"
           ]

    assert result.content =~ "requested page selection limited to 2 pages"
    assert_final_only(result)
    assert %{analyses: 1, outer: 2} = Agent.get(harness.counter, & &1)
  end

  test "explicit text-only non-native model analyzes usable text and reports omitted rendered pages",
       %{tmp_dir: root} do
    harness = harness(root, %{}, "deepseek", "deepseek-chat")
    File.cp!(@fixture, Path.join(root, "ordinary.pdf"))
    install(harness, %{"pdf" => "ordinary.pdf"})
    start(harness)
    assert_receive {:pdf_analysis, handler, request}, 20_000
    assert request["model"] == "deepseek-chat"
    assert [%{"role" => "user", "content" => [text, prompt]}] = request["messages"]
    assert text["text"] =~ "First dense page ordinary document."
    assert text["text"] =~ "image rendering truncated"
    assert prompt["text"] == "Analyze this PDF document."
    send(handler, :release_analysis)
    assert_receive {:run_event, %{type: "session.completed"}}, 20_000
    [_, result] = pdf_parts(harness.session.id)
    assert result.is_error == false
    assert result.content =~ "image rendering truncated"
    assert_final_only(result)
  end

  defp harness(root, extra \\ %{}, protocol \\ "openai", model \\ "gpt-4o") do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)
    fixture = Gaoxy.Test.open()

    {:ok, provider} =
      Providers.create(%{
        name: "pdf-analyzer-#{System.unique_integer([:positive])}",
        type: protocol,
        base_url: Gaoxy.Test.url(fixture),
        api_key_encrypted: "ordinary-fixture"
      })

    ids = Enum.uniq([model, "gpt-4o-mini"])
    records = for id <- ids, do: elem(Models.create(%{provider_id: provider.id, model: id}), 1)

    on_exit(fn ->
      Enum.each(records, &Models.delete/1)
      Providers.delete(provider.id)
    end)

    config =
      Map.merge(h.agent_config.config, %{
        "pdfModel" => %{
          "primary" => provider.name <> "/" <> model,
          "fallbacks" => [provider.name <> "/gpt-4o-mini"]
        },
        "pdfHost" => %{
          "node_executable" => System.find_executable("node"),
          "helper_path" => Path.join(@root, "packages/tool-host/src/pdf/stdio.mjs")
        },
        "web_allowed_hosts" => ["localhost", "127.0.0.1"]
      })
      |> Map.merge(extra)

    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "fixture"
             })

    Agent.update(h.counter, &Map.merge(&1, %{acquisitions: 0, analyses: 0, outer: 0}))
    Map.merge(h, %{analysis: provider, analysis_fixture: fixture})
  end

  defp install(h, input) do
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "GET", "/ordinary.pdf", fn conn ->
      Agent.update(h.counter, &Map.update!(&1, :acquisitions, fn n -> n + 1 end))

      conn
      |> Plug.Conn.put_resp_content_type("application/pdf")
      |> Plug.Conn.resp(200, File.read!(@fixture))
    end)

    Gaoxy.Test.stub(h.analysis_fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 2_000_000)
      Agent.update(h.counter, &Map.update!(&1, :analyses, fn n -> n + 1 end))
      send(owner, {:pdf_analysis, self(), Jason.decode!(body)})

      receive do
        :release_analysis -> :ok
      after
        10_000 -> :ok
      end

      DeterministicProvider.send_sse(conn, [
        DeterministicProvider.text_chunk(@analysis),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {state.outer, %{state | outer: state.outer + 1}}
        end)

      send(owner, {:pdf_outer, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        adapter = :sys.get_state(data.runtime_pid, 1_000)

        send(
          owner,
          {:pdf_descriptor, :sys.get_state(adapter.root, 1_000).catalog.registry.tools[@name]}
        )
      end

      outer_response(conn, if(index == 0, do: input, else: nil))
    end)
  end

  defp start(h) do
    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Analyze the ordinary PDF report")
  end

  defp outer_response(conn, input) do
    {block, delta, stop} =
      if input do
        {%{
           "type" => "tool_use",
           "id" => "ordinary-pdf",
           "name" => ToolName.encode(@name),
           "input" => %{}
         }, %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}, "tool_use"}
      else
        {%{"type" => "text", "text" => ""},
         %{"type" => "text_delta", "text" => "PDF analysis received"}, "end_turn"}
      end

    events = [
      %{"type" => "content_block_start", "index" => 0, "content_block" => block},
      %{"type" => "content_block_delta", "index" => 0, "delta" => delta},
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => stop}},
      %{"type" => "message_stop"}
    ]

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.resp(200, Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n")))
  end

  defp pdf_parts(id),
    do:
      for(
        message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{tool: @name}, part) or
          match?(%ToolResult{tool_use_id: "ordinary-pdf"}, part),
        do: part
      )

  defp assert_final_only(result) do
    encoded = Jason.encode!(result.projection)

    for raw <- [
          "First dense page ordinary document.",
          "pdfBase64",
          "data:image/png",
          "iVBORw0KGgo"
        ],
        do: refute(encoded =~ raw)

    assert byte_size(encoded) < 32_768
  end

  defp assert_final_wire(request) do
    blocks =
      Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

    assert [result] = Enum.filter(blocks, &(&1["type"] == "tool_result"))
    assert result["is_error"] == false
    assert Jason.encode!(result["content"]) =~ @analysis
    refute Jason.encode!(result["content"]) =~ "iVBORw0KGgo"
    refute Jason.encode!(result["content"]) =~ "First dense page ordinary document."
  end

  defp assert_round_trip_and_store(id, parts) do
    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    persisted = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part
    assert [stored] = persisted
    assert stored.content == List.last(parts).content
    assert stored.projection == List.last(parts).projection
    refute Jason.encode!(stored) =~ "iVBORw0KGgo"
  end

  defp trace_extraction do
    Code.ensure_loaded!(PortSession)
    Code.ensure_loaded!(ResourceRegistry)

    for {module, function, arity} <- [
          {ResourceRegistry, :register, 5},
          {PortSession, :open_port, 2},
          {PortSession, :close, 1}
        ] do
      :erlang.trace_pattern({module, function, arity}, [{:_, [], [{:return_trace}]}], [:local])
    end

    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])

      for {m, f, a} <- [
            {ResourceRegistry, :register, 5},
            {PortSession, :open_port, 2},
            {PortSession, :close, 1}
          ],
          do: :erlang.trace_pattern({m, f, a}, false, [:local])
    end)
  end

  defp assert_registered_cleanup(binding) do
    assert_receive {:trace, effect, :call,
                    {ResourceRegistry, :register, [registry, owner, :pdf, broker, opts]}},
                   5_000

    assert registry == binding.resource_registry
    assert owner == binding.owner_id
    assert opts[:owner_pid] == binding.owner_pid
    assert opts[:incarnation] == binding.incarnation
    refute effect == binding.owner_pid

    assert_receive {:trace, ^effect, :return_from, {ResourceRegistry, :register, 5},
                    {:ok, handle}},
                   5_000

    assert_receive {:trace, ^broker, :return_from, {PortSession, :open_port, 2},
                    {:ok, port, os_pid}},
                   5_000

    assert_receive {:trace, _, :return_from, {PortSession, :close, 1},
                    {:ok, %{cleanup_confirmed: true, exit_status: 0, outcome: :completed}}},
                   5_000

    assert Port.info(port) == nil
    refute File.exists?("/proc/#{os_pid}")
    refute Process.alive?(broker)
    assert {:ok, %{status: :confirmed}} = ResourceRegistry.cleanup_status(registry, handle, owner)
    assert {:ok, supervisor} = ResourceRegistry.worker_supervisor(registry)

    refute Enum.any?(
             Elixir.DynamicSupervisor.which_children(supervisor),
             &(elem(&1, 1) == broker)
           )
  end

  defp assert_png_color(
         %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> encoded}},
         color
       ) do
    <<137, 80, 78, 71, 13, 10, 26, 10, chunks::binary>> = Base.decode64!(encoded)
    entries = png_chunks(chunks, [])
    {"IHDR", <<192::32, 96::32, 8, channels, _::binary>>} = List.keyfind(entries, "IHDR", 0)
    assert channels in [2, 6]
    bpp = if channels == 6, do: 4, else: 3
    raw = for({"IDAT", data} <- entries, do: data) |> IO.iodata_to_binary() |> :zlib.uncompress()
    <<filter, row::binary-size(192 * bpp), _::binary>> = raw
    # PDFium's solid first row uses None or Sub; both expose its first pixel directly.
    assert filter in [0, 1, 2, 3, 4]
    <<r, g, b, _::binary>> = row
    assert {r, g, b} == color
  end

  defp png_chunks(<<>>, acc), do: Enum.reverse(acc)

  defp png_chunks(
         <<size::32, type::binary-size(4), data::binary-size(size), _crc::32, rest::binary>>,
         acc
       ),
       do: png_chunks(rest, [{type, data} | acc])
end
