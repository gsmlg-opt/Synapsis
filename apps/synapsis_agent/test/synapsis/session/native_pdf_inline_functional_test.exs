defmodule Synapsis.Session.NativePDFInlineFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.SessionHarness
  alias Synapsis.Agent.Tools.PDF
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.PDF.PortSession
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{AgentConfigs, Models, Providers}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::pdf"
  @analysis "Both complete ordinary reports include their distinct second pages."
  @prompt "Compare both complete ordinary reports"

  for protocol <- ["anthropic", "google"], acquisition <- [:direct, :redirect] do
    @protocol protocol
    @acquisition acquisition
    test "#{protocol} selected native PDF via #{acquisition} sends complete ordered bytes and replays final analysis after Worker restart",
         %{tmp_dir: root} do
      protocol = @protocol
      acquisition = @acquisition
      h = harness(root, protocol)
      first = ordinary_pdf("First ordinary report", 0)
      second = ordinary_pdf("Second ordinary report", 270_000)
      assert byte_size(second) > 262_144
      refute first == second
      File.write!(Path.join(root, "second ordinary.pdf"), second)

      url = Gaoxy.Test.url(h.provider.fixture, source_path(acquisition))

      input = %{"pdf" => url, "pdfs" => ["second ordinary.pdf"], "prompt" => @prompt}

      assert {:ok, [url_part, file_part, _prompt_part]} =
               Synapsis.Agent.Tools.PDF.Context.native_parts(
                 [
                   %{resolved_input: url, bytes: first},
                   %{resolved_input: Path.join(root, "second ordinary.pdf"), bytes: second}
                 ],
                 %{page_numbers: nil, password: nil, prompt: @prompt, max_pages: 1}
               )

      assert url_part.data["uri"] == url

      assert file_part.data["uri"] ==
               "file://" <>
                 URI.encode(
                   Path.join(root, "second ordinary.pdf"),
                   &(URI.char_unreserved?(&1) or &1 == ?/)
                 )

      assert url_part.extensions == %{} and file_part.extensions == %{}
      install(h, protocol, input, first, acquisition)
      trace_extraction()
      start(h)

      assert_receive {:pdf_outer, 0, initial}, 5_000
      assert_receive {:pdf_descriptor, descriptor}, 5_000
      assert descriptor.backend == PDF
      assert descriptor.codex_exposure == :direct_model_only
      assert [%{"name" => name, "input_schema" => schema}] = initial["tools"]
      assert ToolName.decode(name) == @name
      assert schema == descriptor.schema
      assert_receive {:pdf_analysis, request}, 15_000
      assert_native_wire(request, protocol, [first, second])
      assert_receive {:pdf_outer, 1, following}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      [use, result] = pdf_parts(h.session.id)
      assert %ToolUse{tool: @name, tool_use_id: "ordinary-pdf", input: ^input} = use
      assert %ToolResult{is_error: false, tool_use_id: "ordinary-pdf"} = result
      assert result.content == @analysis
      assert result.projection["result"]["native"] == true
      assert result.projection["result"]["model"] == h.analysis.name <> "/" <> h.model

      assert result.projection["result"]["attempts"] == [
               %{"model" => h.analysis.name <> "/" <> h.model, "status" => "completed"}
             ]

      assert Enum.map(result.projection["result"]["provenance"], & &1["resolved_input"]) == [
               url,
               Path.join(root, "second ordinary.pdf")
             ]

      assert_final_wire(following, [first, second])
      assert_round_trip_and_store(h.session.id, [use, result])
      assert_raw_history(h.session.id, input, [first, second])
      refute_receive {:trace, _, :call, {PortSession, :open_port, _}}, 100
      assert %{acquisitions: 1, analyses: 1, outer: 2} = Agent.get(h.counter, & &1)
      assert_source_requests(h, acquisition)

      [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      monitor = Process.monitor(old)
      assert :ok = DynamicSupervisor.stop_session(h.session.id)
      assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
      SessionHarness.ensure_running!(h.session.id)
      [{new, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      refute new == old
      assert :ok = Worker.send_message(h.session.id, "Recall the completed PDF reports")
      assert_receive {:pdf_outer, 2, replay}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_final_wire(replay, [first, second])
      assert pdf_parts(h.session.id) == [use, result]
      assert_round_trip_and_store(h.session.id, [use, result])
      assert_raw_history(h.session.id, input, [first, second])
      assert %{acquisitions: 1, analyses: 1, outer: 3} = Agent.get(h.counter, & &1)
      assert_source_requests(h, acquisition)
      refute_receive {:trace, _, :call, {PortSession, :open_port, _}}, 100
    end
  end

  defp harness(root, protocol) do
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
        name: "native-pdf-#{System.unique_integer([:positive])}",
        type: protocol,
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
        api_key_encrypted: "ordinary-fixture"
      })

    model = if protocol == "anthropic", do: "claude-sonnet-4-5", else: "gemini-2.5-flash"
    {:ok, record} = Models.create(%{provider_id: provider.id, model: model})

    on_exit(fn ->
      Models.delete(record)
      Providers.delete(provider.id)
    end)

    config =
      Map.merge(h.agent_config.config, %{
        "pdfModel" => provider.name <> "/" <> model,
        "pdfMaxPages" => 1,
        "web_allowed_hosts" => ["localhost", "127.0.0.1"]
      })

    assert {:ok, _} = AgentConfigs.update(h.agent_config, %{tools: [@name], config: config})

    assert :ok =
             Synapsis.Provider.Registry.register(h.provider.name, %{
               type: "anthropic",
               base_url: h.provider.base_url,
               api_key: "fixture"
             })

    Agent.update(
      h.counter,
      &Map.merge(&1, %{acquisitions: 0, analyses: 0, outer: 0, source_requests: []})
    )

    Map.merge(h, %{analysis: provider, analysis_fixture: fixture, model: model})
  end

  defp install(h, protocol, input, first, acquisition) do
    owner = self()

    if acquisition == :redirect do
      for {path, status, location} <- [
            {"/reports/start", 302, "middle?step=1"},
            {"/reports/middle", 307, "../first.pdf"}
          ] do
        Gaoxy.Test.stub(h.provider.fixture, "GET", path, fn conn ->
          record_source_request(h, conn)

          conn
          |> Plug.Conn.put_resp_header("location", location)
          |> Plug.Conn.resp(status, "ordinary redirect")
        end)
      end
    end

    Gaoxy.Test.stub(h.provider.fixture, "GET", "/first.pdf", fn conn ->
      record_source_request(h, conn)
      Agent.update(h.counter, &Map.update!(&1, :acquisitions, fn n -> n + 1 end))
      conn |> Plug.Conn.put_resp_content_type("application/pdf") |> Plug.Conn.resp(200, first)
    end)

    endpoint =
      if protocol == "anthropic",
        do: "/v1/messages",
        else: "/v1beta/models/#{h.model}:streamGenerateContent"

    Gaoxy.Test.stub(h.analysis_fixture, "POST", endpoint, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 2_000_000)
      Agent.update(h.counter, &Map.update!(&1, :analyses, fn n -> n + 1 end))
      send(owner, {:pdf_analysis, Jason.decode!(body)})
      analysis_response(conn, protocol)
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

  defp source_path(:direct), do: "/first.pdf"
  defp source_path(:redirect), do: "/reports/start"

  defp record_source_request(h, conn) do
    target =
      conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

    Agent.update(
      h.counter,
      &Map.update!(&1, :source_requests, fn requests -> requests ++ [target] end)
    )
  end

  defp assert_source_requests(h, acquisition) do
    expected =
      if acquisition == :redirect,
        do: ["/reports/start", "/reports/middle?step=1", "/first.pdf"],
        else: ["/first.pdf"]

    assert Agent.get(h.counter, & &1.source_requests) == expected
  end

  defp analysis_response(conn, "anthropic") do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => @analysis}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
      %{"type" => "message_stop"}
    ]

    sse(conn, events)
  end

  defp analysis_response(conn, "google"),
    do:
      sse(conn, [
        %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => @analysis}], "role" => "model"}}
          ]
        },
        %{"candidates" => [%{"finishReason" => "STOP"}]}
      ])

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )

  defp start(h) do
    SessionHarness.subscribe!(h.session.id)
    SessionHarness.ensure_running!(h.session.id)
    assert :ok = Worker.send_message(h.session.id, "Analyze both ordinary PDF reports")
  end

  defp assert_native_wire(request, "anthropic", bytes) do
    assert [%{"role" => "user", "content" => [first, second, prompt]}] = request["messages"]

    assert [first, second] ==
             Enum.map(
               bytes,
               &%{
                 "type" => "document",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "application/pdf",
                   "data" => Base.encode64(&1)
                 }
               }
             )

    assert prompt == %{"type" => "text", "text" => @prompt}
    assert request["max_tokens"] == 4096
  end

  defp assert_native_wire(request, "google", bytes) do
    assert [%{"role" => "user", "parts" => [first, second, prompt]}] = request["contents"]

    assert [first, second] ==
             Enum.map(
               bytes,
               &%{"inlineData" => %{"mimeType" => "application/pdf", "data" => Base.encode64(&1)}}
             )

    assert prompt == %{"text" => @prompt}
  end

  defp assert_final_wire(request, bytes) do
    blocks =
      Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

    assert [result] = Enum.filter(blocks, &(&1["type"] == "tool_result"))
    assert result["is_error"] == false
    assert Jason.encode!(result["content"]) =~ @analysis
    assert_no_bytes(Jason.encode!(request), bytes)
  end

  defp assert_raw_history(id, input, bytes) do
    assert {:ok, turns} = Store.list_turns(id)
    parts = for turn <- turns, part <- turn.parts, do: part

    assert [%{id: "ordinary-pdf", name: @name, input: ^input}] =
             Enum.filter(parts, &(&1[:type] == "tool_use"))

    assert_no_bytes(Jason.encode!(turns), bytes)
  end

  defp assert_no_bytes(encoded, bytes) do
    for pdf <- bytes, do: refute(encoded =~ Base.encode64(pdf))

    for marker <- [
          "JVBERi0",
          "First ordinary report page",
          "Second ordinary report page",
          "[Partial document:",
          "inlineData",
          "application/pdf"
        ],
        do: refute(encoded =~ marker)
  end

  defp trace_extraction do
    Code.ensure_loaded!(PortSession)
    :erlang.trace_pattern({PortSession, :open_port, 2}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({PortSession, :open_port, 2}, false, [:local])
    end)
  end

  # Two ordinary text pages with a valid xref; the second stream can carry a large PDF comment.
  defp ordinary_pdf(label, padding) do
    first = "BT /F1 12 Tf 40 100 Td (#{label} page one) Tj ET\n"

    second =
      "BT /F1 12 Tf 40 100 Td (#{label} page two) Tj ET\n%" <>
        String.duplicate("x", padding) <> "\n"

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{byte_size(first)} >>\nstream\n#{first}endstream",
      "<< /Length #{byte_size(second)} >>\nstream\n#{second}endstream"
    ]

    {body, offsets} =
      Enum.with_index(objects, 1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, index}, {body, offsets} ->
        {body <> "#{index} 0 obj\n#{object}\nendobj\n", offsets ++ [byte_size(body)]}
      end)

    xref =
      Enum.map_join(
        offsets,
        "",
        &(String.pad_leading(Integer.to_string(&1), 10, "0") <> " 00000 n \n")
      )

    body <>
      "xref\n0 8\n0000000000 65535 f \n" <>
      xref <> "trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
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
end
