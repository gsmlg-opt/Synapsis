defmodule Synapsis.Session.NativeSessionDirectoryEnrichmentFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Runtime.{ProviderEvents, ProviderMessages}
  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.SessionDirectory
  alias Synapsis.{Message, Part.Text}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{Store, Worker}

  @moduletag :tmp_dir
  @name "synapsis::sessions_list"

  setup %{tmp_dir: tmp_dir} do
    previous_node = Application.fetch_env(:synapsis_agent, :filesystem_node)
    node = node_executable()
    Application.put_env(:synapsis_agent, :filesystem_node, node)

    harness =
      SessionHarness.setup_session!(
        tmp_dir: tmp_dir,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    assert {:ok, _} = Synapsis.AgentConfigs.update(harness.agent_config, %{tools: [@name]})
    SessionHarness.subscribe!(harness.session.id)

    on_exit(fn ->
      SessionHarness.cleanup!(harness)

      case previous_node do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    %{harness: harness, id: harness.session.id, node: node}
  end

  test "the real unphased provider producer persists raw text and supplies exact source preview",
       ctx do
    markdown = "# **Legacy** reply\nRead `status` and [details](https://example.test)."
    assert {:ok, _, state} = ProviderEvents.push(ProviderEvents.new(), {:text_delta, markdown})
    assert {:ok, %{message: produced}} = ProviderEvents.finish(state)
    assert produced == %{role: :assistant, content: [%{type: :text, text: markdown}]}
    assert {:ok, [%{role: :assistant, parts: parts}]} = ProviderMessages.to_host([produced])
    assert parts == [%Text{content: markdown}]

    id =
      persist("producer", [
        %Message{role: "user", parts: [%Text{content: "Build the provider report."}]},
        %Message{role: "assistant", parts: parts}
      ])

    assert {:ok, %{sessions: [row]}} =
             Synapsis.SessionDirectory.list(
               %{
                 "search" => id,
                 "include_derived_titles" => true,
                 "include_last_message" => true
               },
               %{session_id: ctx.id, agent_id: ctx.harness.agent_name},
               node_executable: ctx.node
             )

    assert row.derived_title == "Build the provider report."
    assert row.last_message_preview == "Legacy reply Read status and details."
    assert {:ok, raw} = Store.get_turn(id, 1)
    assert [%{type: "text", text: ^markdown}] = raw.parts
    refute Map.has_key?(raw, :phase)
    refute Map.has_key?(hd(raw.parts), :phase)
    refute Map.has_key?(raw, :reply_presentation)
    [_, reloaded] = Message.list_by_session(id)
    assert {:ok, [replayed]} = ProviderMessages.from_host([reloaded])
    assert replayed.role == :assistant
    assert replayed.content == [%{type: :text, text: markdown}]
  end

  test "Worker selects revision three, receives enriched JSON, persists and replays it in the next HTTP request",
       ctx do
    target =
      persist("saved host title", [
        %Message{role: "user", parts: [%Text{content: "Build the native session report."}]},
        %Message{role: "assistant", parts: [%Text{content: "# **Native** report ready. 雪 😀"}]}
      ])

    owner = self()

    Gaoxy.Test.stub(ctx.harness.provider.fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      Agent.update(
        ctx.harness.counter,
        &%{&1 | provider_requests: &1.provider_requests ++ [request]}
      )

      completed = Enum.any?(request["messages"], &(&1["role"] == "tool"))

      chunks =
        if completed do
          [
            DeterministicProvider.text_chunk("Enriched directory received."),
            DeterministicProvider.finish_chunk("stop")
          ]
        else
          send(owner, {:enrichment_catalog, request["tools"]})
          [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, ctx.id)
          {_, data} = :sys.get_state(worker, 1_000)
          runtime = :sys.get_state(data.runtime_pid, 1_000)
          selected = :sys.get_state(runtime.root, 1_000).catalog.registry.tools[@name]
          send(owner, {:enrichment_selected, selected})

          [
            DeterministicProvider.tool_call_chunk(ToolName.encode(@name), "directory-enriched", %{
              "search" => target,
              "include_derived_titles" => true,
              "include_last_message" => true
            }),
            DeterministicProvider.finish_chunk("tool_calls")
          ]
        end

      DeterministicProvider.send_sse(conn, chunks)
    end)

    SessionHarness.ensure_running!(ctx.id)
    assert :ok = Worker.send_message(ctx.id, "Read the enriched directory")
    assert_receive {:enrichment_catalog, [descriptor]}, 5_000
    assert ToolName.decode(descriptor["function"]["name"]) == @name
    assert_receive {:enrichment_selected, selected}, 5_000
    assert selected.tool_name == @name
    assert selected.tool_revision == 3

    for flag <- ~w(include_derived_titles include_last_message) do
      property = descriptor["function"]["parameters"]["properties"][flag]
      assert property["type"] == "boolean"
      assert property["default"] == false
    end

    assert_receive {:run_event, %{type: "session.completed"}}, 10_000
    requests = Agent.get(ctx.harness.counter, & &1.provider_requests)
    assert length(requests) == 2
    durable = Message.list_by_session(ctx.id)

    results =
      for message <- durable,
          part <- message.parts,
          match?(%Synapsis.Part.ToolResult{}, part),
          do: part

    assert [result] = results
    assert result.is_error == false
    assert result.tool_use_id == "directory-enriched"
    page = result.projection["result"]["structured"]
    assert page["source"] == "durable"
    assert page["count"] == 1
    assert [row] = page["sessions"]
    assert row["id"] == target
    assert row["title"] == "saved host title"
    assert row["derived_title"] == "Build the native session report."
    assert row["last_message_preview"] == "Native report ready. 雪 😀"
    assert Jason.decode!(result.content) == page
    ordered = Jason.decode!(result.content, objects: :ordered_objects)
    assert result.content == Jason.encode!(ordered, pretty: true)
    assert byte_size(result.content) <= 65_536
    assert byte_size(Jason.encode!(%{content: result.content, structured: page})) <= 262_144

    next = List.last(requests)

    tool_reply =
      Enum.find(
        next["messages"],
        &(&1["role"] == "tool" and &1["tool_call_id"] == result.tool_use_id)
      )

    assert tool_reply["content"] == result.content
    assert {:ok, replayed} = ProviderMessages.from_host(durable)
    replayed_result = Enum.find(replayed, &(Map.get(&1, :tool_call_id) == result.tool_use_id))
    assert replayed_result.result["structured"] == page
    assert replayed_result.result.content == result.content
    assert SessionDirectory.names() == [@name]
  end

  test "a public enriched page below 64 KiB survives its larger native transport wrapper", ctx do
    marker = "native-enrichment-#{Ecto.UUID.generate()}"
    title = marker <> " " <> String.duplicate("report ", 5) <> "\"雪\""

    ids =
      for index <- 0..119 do
        persist(title, [
          %Message{role: "assistant", parts: [%Text{content: "Visible answer #{index}."}]}
        ])
      end

    context = %{
      session_id: ctx.id,
      agent_id: ctx.harness.agent_name,
      run_id: "directory/ordinary-large-page",
      incarnation: 1,
      catalog_revision: 1
    }

    assert {:ok, [descriptor]} = SessionDirectory.descriptors(context)

    operation =
      Map.merge(context, %{
        tool_name: @name,
        tool_revision: descriptor.tool_revision,
        arguments: %{"search" => marker, "limit" => 200, "include_last_message" => true},
        backend_context: context
      })

    assert {:ok, native} = SessionDirectory.execute(operation)
    assert native.structured.count == 120
    assert native.structured.has_more == false
    assert Enum.sort(Enum.map(native.structured.sessions, & &1.id)) == Enum.sort(ids)
    assert Enum.count(native.structured.sessions, &Map.has_key?(&1, :last_message_preview)) == 100
    assert Jason.decode!(native.content) == Jason.decode!(Jason.encode!(native.structured))
    assert native.content == Jason.encode!(native.structured, pretty: true)
    assert byte_size(native.content) <= 65_536
    wrapper_bytes = byte_size(Jason.encode!(native))
    assert wrapper_bytes > 65_536
    assert wrapper_bytes <= 262_144
  end

  defp persist(title, messages) do
    id = Ecto.UUID.generate()
    assert :ok = Message.persist_list(id, messages, %{id: id, title: title, agent: "archive"})
    on_exit(fn -> Store.delete_session(id) end)
    id
  end

  defp node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
end
