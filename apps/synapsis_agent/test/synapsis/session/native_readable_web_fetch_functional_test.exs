defmodule Synapsis.Session.NativeReadableWebFetchFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{Backend, Web.ReadableFetch}
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.Session.Worker.PendingInputs
  alias Synapsis.Web.Fetch.Document

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "web::fetch"
  @oracle_path Path.expand("../../fixtures/openclaw/488631c/web-fetch.json", __DIR__)
  @external_resource @oracle_path
  @oracle_bytes File.read!(@oracle_path)
  @oracle Jason.decode!(@oracle_bytes)
  @oracle_sha "2fc7a79709a6d23fe109f21958223dae40d9e7e3f17271bc217e45bab5c4fd08"
  @source_marker "3636363636363636"
  @fields %{
    "finalUrl" => "final_url",
    "contentType" => "content_type",
    "extractMode" => "extract_mode",
    "externalContent" => "external_content",
    "rawLength" => "raw_length",
    "fetchedAt" => "fetched_at",
    "tookMs" => "took_ms"
  }

  for {label, ids} <- [
        {"readability and Markdown", ["article", "article-text", "markdown", "markdown-text"]},
        {"plain and exact-number JSON", ["plain", "json", "json-subtype"]},
        {"header, BOM and document charsets", ["declared-charset", "bom", "document-charset"]}
      ] do
    @ids ids
    test "#{label} preserves complete native documents through cache and normal Worker reopen",
         %{tmp_dir: root} do
      assert Base.encode16(:crypto.hash(:sha256, @oracle_bytes), case: :lower) == @oracle_sha
      assert @oracle["pin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
      h = setup_harness(root)
      resources = Enum.map(@ids, &resource(h, &1))
      [first_resource | _] = resources

      calls =
        [first_resource, %{first_resource | id: first_resource.id <> "-cached", cached: true}] ++
          tl(resources)

      install_http(h, resources)
      install_provider(h, calls)
      trace_document_calls()
      SessionHarness.subscribe!(h.session.id)
      SessionHarness.ensure_running!(h.session.id)
      await_ready(h.session.id, System.monotonic_time(:millisecond) + 5_000)
      assert :ok = Worker.switch_model(h.session.id, h.provider.name, "gpt-4o")
      started_at = DateTime.utc_now()
      assert :ok = Worker.send_message(h.session.id, "Read the complete ordinary documents")
      assert_receive {:readable_request, 0, initial}, 5_000
      assert_receive {:readable_descriptor, descriptor, authority}, 5_000
      assert descriptor.backend == Backend
      assert descriptor.tool_revision == 2
      assert descriptor.backend_context.family == :service
      assert descriptor.codex_input_kind == :function
      assert descriptor.schema == ReadableFetch.schema()
      assert descriptor.backend_context.context.web_fetch_adapter == Synapsis.Web.Fetch

      assert {:ok, original} =
               Codex.profile(:service_compat, descriptor.backend_context.context, authority,
                 tools: [@name]
               )

      assert descriptor == original.registry.tools[@name]
      assert [%{"function" => %{"name" => encoded, "parameters" => schema}}] = initial["tools"]
      assert ToolName.decode(encoded) == @name
      assert schema == ReadableFetch.schema()
      assert initial["model"] == "gpt-4o"

      requests =
        for index <- 1..length(calls) do
          assert_receive {:readable_request, ^index, request}, 15_000
          assert_wire(request, Enum.take(calls, index), started_at)
          request
        end

      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      await_ready(h.session.id, System.monotonic_time(:millisecond) + 5_000)
      parts = tool_parts(h.session.id)
      assert_parts_and_store(h.session.id, parts, calls, started_at)
      assert_cache(parts)
      assert_http(h, resources)
      assert_helper_calls(resources)
      final_request = List.last(requests)
      results = wire_results(final_request)
      assert length(results) == length(calls)

      assert Enum.map(results, & &1["content"]) ==
               parts |> Enum.filter(&match?(%ToolResult{}, &1)) |> Enum.map(& &1.content)

      [{old_worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      monitor = Process.monitor(old_worker)
      assert :ok = DynamicSupervisor.stop_session(h.session.id)
      assert_receive {:DOWN, ^monitor, :process, ^old_worker, :shutdown}, 5_000
      refute Process.alive?(old_worker)
      SessionHarness.ensure_running!(h.session.id)
      await_ready(h.session.id, System.monotonic_time(:millisecond) + 5_000)
      [{new_worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      refute new_worker == old_worker
      assert :ok = Worker.send_message(h.session.id, "Recall the complete documents already read")
      replay_index = length(calls) + 1
      assert_receive {:readable_request, ^replay_index, replay}, 15_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_wire(replay, calls, started_at)
      assert wire_results(replay) == results
      assert tool_parts(h.session.id) == parts
      assert_parts_and_store(h.session.id, parts, calls, started_at)
      assert_http(h, resources)
      refute_receive {:trace, _, :call, {Document, :prepare, _}}, 100
      assert length(Agent.get(h.counter, & &1.provider_requests)) == length(calls) + 2
    end
  end

  defp setup_harness(root) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)

    assert {:ok, _} =
             Synapsis.AgentConfigs.update(h.agent_config, %{
               tools: [@name],
               config:
                 Map.put(h.agent_config.config, "web_allowed_hosts", ["localhost", "127.0.0.1"])
             })

    Agent.update(h.counter, &Map.put(&1, :http_paths, []))
    h
  end

  defp resource(h, id) do
    source = Enum.find(@oracle["groups"], &(&1["id"] == id))
    assert source
    path = "/documents/" <> id
    final_path = if id == "article", do: "/readable/article", else: path
    url = Gaoxy.Test.url(h.provider.fixture, path)
    final_url = Gaoxy.Test.url(h.provider.fixture, final_path)
    mode = Map.get(source["args"], "extractMode", "markdown")

    arguments = %{
      "url" => url,
      "extract_mode" => mode,
      "max_chars" => 2_000,
      "instructions" => "Return the complete ordinary document."
    }

    expected =
      source["results"]
      |> hd()
      |> Map.fetch!("details")
      |> Map.drop(["fetchedAt", "tookMs"])
      |> Map.new(fn {key, value} -> {Map.get(@fields, key, key), value} end)
      |> Map.put("url", url)
      |> Map.put("final_url", final_url)

    input = source["input"]

    bytes =
      cond do
        input["bytes"] ->
          :erlang.list_to_binary(input["bytes"])

        input["encoding"] == "latin1" ->
          :unicode.characters_to_binary(input["body"], :utf8, :latin1)

        true ->
          input["body"]
      end

    %{
      id: "readable-" <> id,
      path: path,
      final_path: final_path,
      bytes: bytes,
      header: input["contentType"],
      arguments: arguments,
      expected: expected,
      cached: false
    }
  end

  defp install_http(h, resources) do
    for resource <- resources do
      if resource.path != resource.final_path do
        Gaoxy.Test.stub(h.provider.fixture, "GET", resource.path, fn conn ->
          record_http(h, conn)

          conn
          |> Plug.Conn.put_resp_header("location", resource.final_path)
          |> Plug.Conn.resp(302, "Ordinary article redirect")
        end)
      end

      Gaoxy.Test.stub(h.provider.fixture, "GET", resource.final_path, fn conn ->
        record_http(h, conn)

        conn
        |> Plug.Conn.put_resp_header("content-type", resource.header)
        |> Plug.Conn.resp(200, resource.bytes)
      end)
    end
  end

  defp record_http(h, conn),
    do:
      Agent.update(
        h.counter,
        &Map.update!(&1, :http_paths, fn paths -> paths ++ [conn.request_path] end)
      )

  defp assert_http(h, resources) do
    expected =
      Enum.flat_map(resources, fn resource ->
        if resource.path == resource.final_path,
          do: [resource.path],
          else: [resource.path, resource.final_path]
      end)

    assert Agent.get(h.counter, & &1.http_paths) == expected
  end

  defp install_provider(h, calls) do
    owner = self()

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, bytes, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
      request = Jason.decode!(bytes)

      index =
        Agent.get_and_update(h.counter, fn state ->
          {length(state.provider_requests),
           %{state | provider_requests: state.provider_requests ++ [request]}}
        end)

      send(owner, {:readable_request, index, request})

      if index == 0 do
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        runtime = :sys.get_state(data.runtime_pid, 1_000)
        catalog = :sys.get_state(runtime.root, 1_000).catalog
        send(owner, {:readable_descriptor, catalog.registry.tools[@name], catalog.authority})
      end

      chunks =
        case Enum.at(calls, index) do
          nil ->
            [
              DeterministicProvider.text_chunk("Complete readable documents received"),
              DeterministicProvider.finish_chunk("stop")
            ]

          call ->
            [
              DeterministicProvider.tool_call_chunk(
                ToolName.encode(@name),
                call.id,
                call.arguments
              ),
              DeterministicProvider.finish_chunk("tool_calls")
            ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)
  end

  defp wire_results(request), do: Enum.filter(request["messages"], &(&1["role"] == "tool"))

  defp assert_wire(request, calls, started_at) do
    results = wire_results(request)
    assert Enum.map(results, & &1["tool_call_id"]) == Enum.map(calls, & &1.id)

    Enum.zip(results, calls)
    |> Enum.each(fn {message, call} ->
      assert Map.keys(message) |> Enum.sort() == ["content", "role", "tool_call_id"]
      document = Jason.decode!(message["content"])
      assert_document(document, call, started_at)
    end)
  end

  defp assert_document(document, call, started_at) do
    assert is_integer(document["took_ms"]) and document["took_ms"] >= 0
    assert {:ok, fetched_at, 0} = DateTime.from_iso8601(document["fetched_at"])
    assert DateTime.compare(fetched_at, started_at) in [:eq, :gt]
    assert DateTime.compare(fetched_at, DateTime.utc_now()) in [:eq, :lt]
    expected = if call.cached, do: Map.put(call.expected, "cached", true), else: call.expected

    actual =
      document
      |> Map.drop(["fetched_at", "took_ms"])
      |> Map.update!("text", &normalize_marker/1)

    actual =
      if Map.has_key?(actual, "title"),
        do: Map.update!(actual, "title", &normalize_marker/1),
        else: actual

    assert actual == expected

    assert div(
             byte_size(:unicode.characters_to_binary(document["text"], :utf8, {:utf16, :little})),
             2
           ) ==
             document["length"]
  end

  defp normalize_marker(text) do
    assert [[marker]] =
             Regex.scan(~r/<<<EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>/, text,
               capture: :all_but_first
             )

    assert [[^marker]] =
             Regex.scan(~r/<<<END_EXTERNAL_UNTRUSTED_CONTENT id="([0-9a-f]{16})">>>/, text,
               capture: :all_but_first
             )

    refute marker == @source_marker
    String.replace(text, "id=\"" <> marker <> "\"", "id=\"" <> @source_marker <> "\"")
  end

  defp tool_parts(id),
    do:
      for(
        message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{tool: @name}, part) or match?(%ToolResult{}, part),
        do: part
      )

  defp assert_parts_and_store(id, parts, calls, started_at) do
    uses = Enum.filter(parts, &match?(%ToolUse{}, &1))
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    assert length(uses) == length(calls)
    assert length(results) == length(calls)

    for {use, call} <- Enum.zip(uses, calls) do
      assert %ToolUse{tool: @name, tool_use_id: call_id, input: arguments} = use
      assert call_id == call.id
      assert arguments == call.arguments
    end

    for {result, call} <- Enum.zip(results, calls) do
      assert %ToolResult{tool_use_id: call_id, is_error: false} = result
      assert call_id == call.id
      document = Jason.decode!(result.content)
      assert_document(document, call, started_at)

      assert result.projection == %{
               "version" => 1,
               "result" =>
                 document |> Map.put("content", result.content) |> Map.put("is_error", false)
             }
    end

    for part <- parts do
      assert {:ok, dump} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    stored_uses = for turn <- turns, part <- turn.parts, part[:type] == "tool_use", do: part
    stored_results = for turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part

    assert Enum.map(stored_uses, &Map.take(&1, [:id, :name, :input])) ==
             Enum.map(calls, &%{id: &1.id, name: @name, input: &1.arguments})

    assert Enum.map(
             stored_results,
             &Map.take(&1, [:tool_use_id, :content, :projection, :is_error])
           ) ==
             Enum.map(results, &Map.take(&1, [:tool_use_id, :content, :projection, :is_error]))
  end

  defp assert_cache(parts) do
    results = Enum.filter(parts, &match?(%ToolResult{}, &1))
    original = hd(results).content |> Jason.decode!()
    cached = Enum.at(results, 1).content |> Jason.decode!()
    assert cached == Map.put(original, "cached", true)
  end

  defp trace_document_calls do
    Code.ensure_loaded!(Document)
    :erlang.trace_pattern({Document, :prepare, 3}, true, [:local])
    :erlang.trace(:all, true, [:call, {:tracer, self()}])

    on_exit(fn ->
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Document, :prepare, 3}, false, [:local])
    end)
  end

  defp assert_helper_calls(resources) do
    for resource <- resources do
      assert_receive {:trace, _, :call, {Document, :prepare, [bytes, metadata, options]}}, 1_000
      assert bytes == resource.bytes

      assert metadata == %{
               "url" => resource.arguments["url"],
               "finalUrl" => resource.expected["final_url"],
               "status" => 200,
               "contentType" => resource.header,
               "extractMode" => resource.arguments["extract_mode"],
               "maxChars" => resource.arguments["max_chars"]
             }

      assert Keyword.fetch!(options, :node_executable) ==
               Application.fetch_env!(:synapsis_agent, :filesystem_node)
    end

    refute_receive {:trace, _, :call, {Document, :prepare, _}}, 100
  end

  defp await_ready(id, deadline) do
    [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, id)
    {state, data} = :sys.get_state(worker, 1_000)

    if state == :idle and data.pending_inputs.booted and not data.runtime_active and
         not PendingInputs.changing_agent?(data) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        receive do
        after
          10 -> await_ready(id, deadline)
        end
      else
        flunk("Worker did not finish its ordinary boot/readiness lane")
      end
    end
  end
end
