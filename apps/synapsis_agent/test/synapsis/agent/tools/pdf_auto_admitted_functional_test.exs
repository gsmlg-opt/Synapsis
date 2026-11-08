defmodule Synapsis.Agent.Tools.PDFAutoAdmittedFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.TestSupport.{DeterministicProvider, SessionHarness}
  alias Synapsis.Agent.Tools.PDF
  alias Synapsis.Agent.Tools.PDF.Model
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.ToolName
  alias Synapsis.Session.{DynamicSupervisor, Store, Worker}
  alias Synapsis.{AgentConfigs, Models, Providers, Sessions}

  @moduletag :tmp_dir
  @moduletag timeout: 90_000
  @name "synapsis::pdf"
  @outer_model "claude-sonnet-4-6"
  @analysis "The ordinary report contains its first and third text pages and red and blue figures."
  @prompt "Describe the ordinary report"
  @root Path.expand("../../../../../..", __DIR__)
  @fixture Path.join(@root, "apps/synapsis_core/test/fixtures/pdf/ordinary.pdf")

  setup do
    for type <- [:model, :provider], do: Synapsis.DataCase.clear_config_store(type)
    :ok
  end

  for lane <- [:anthropic, :google, :extracted_image, :text_extraction, :custom_vision, :active] do
    @lane lane
    test "automatic #{@lane} selection uses the complete admitted candidate list, real PDF analysis and completed history across ordinary Worker reopen",
         %{tmp_dir: root} do
      lane = @lane
      h = harness(root, lane)

      # An absent additive feature must fail directly before any fixture conversation starts.
      assert {:ok, preparation} = Model.prepare(%{}, h.model_context)
      assert refs(preparation.models) == h.expected
      File.cp!(@fixture, Path.join(root, "ordinary.pdf"))
      input = %{"pdf" => "ordinary.pdf", "prompt" => @prompt}
      install(h, input)
      SessionHarness.subscribe!(h.session.id)
      SessionHarness.ensure_running!(h.session.id)
      assert_worker_idle!(h.session.id)
      assert :ok = Sessions.switch_model(h.session.id, h.outer.provider.name, @outer_model)
      assert :ok = Worker.send_message(h.session.id, "Analyze the ordinary report")

      assert_receive {:pdf_auto_outer, 0, first}, 10_000
      assert first["model"] == @outer_model
      assert_receive {:pdf_auto_descriptor, 0, descriptor}, 5_000
      assert descriptor.backend == PDF
      assert descriptor.codex_exposure == :direct_model_only
      assert refs(descriptor.backend_context.models) == h.expected

      assert Enum.map(descriptor.backend_context.models, & &1.provider_id) ==
               h.expected_provider_ids

      assert [%{"name" => name, "input_schema" => schema}] = first["tools"]
      assert ToolName.decode(name) == @name
      assert schema == descriptor.schema
      assert_receive {:pdf_auto_analysis, request}, 20_000
      assert_analysis_wire(h, request)
      assert_receive {:pdf_auto_outer, 1, following}, 10_000
      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      [use, result] = pdf_parts(h.session.id)
      assert %ToolUse{tool: @name, tool_use_id: "auto-pdf", input: ^input} = use
      assert %ToolResult{is_error: false, tool_use_id: "auto-pdf"} = result

      content =
        if lane == :text_extraction,
          do: @analysis <> "\n\n[Partial document: image rendering truncated.]",
          else: @analysis

      assert result.content == content

      assert result.projection["result"] == %{
               "content" => content,
               "is_error" => false,
               "model" => hd(h.expected),
               "native" => lane in [:anthropic, :google],
               "attempts" => [%{"model" => hd(h.expected), "status" => "completed"}],
               "provenance" => [
                 %{
                   "resolved_input" => Path.join(root, "ordinary.pdf"),
                   "rewritten_from" => "ordinary.pdf"
                 }
               ]
             }

      assert_final_wire(following, content)
      assert_saved(h.session.id, [use, result])
      assert Agent.get(h.counter, & &1.analyses) == 1

      # Fresh ordinary metadata/model-order edits affect the next admission while saved results stay intact.
      {fresh_expected, fresh_provider_ids} =
        if lane == :custom_vision do
          [first_model, second_model] = h.analysis.models
          assert {:ok, _} = Models.update(first_model, %{selection_order: 4})

          assert {:ok, _} =
                   Models.update(second_model, %{selection_order: 0, input: ["image", "text"]})

          assert {:ok, _} =
                   Providers.update(h.analysis.provider.id, %{
                     config: %{
                       "media_understanding" => %{
                         "capabilities" => ["image"],
                         "autoPriority" => %{"image" => 5}
                       }
                     }
                   })

          assert :ok = Synapsis.Config.Store.reload(:model)
          assert :ok = Synapsis.Config.Store.reload(:provider)
          {["pdf-custom/custom-a", "pdf-other/other-vision"], h.expected_provider_ids}
        else
          {h.expected, h.expected_provider_ids}
        end

      [{old, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      monitor = Process.monitor(old)
      assert :ok = DynamicSupervisor.stop_session(h.session.id)
      assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
      SessionHarness.ensure_running!(h.session.id)
      [{new, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
      assert new != old
      assert :ok = Worker.send_message(h.session.id, "Recall the completed ordinary report")
      assert_receive {:pdf_auto_outer, 2, replay}, 10_000
      assert_receive {:pdf_auto_descriptor, 2, fresh_descriptor}, 5_000
      assert refs(fresh_descriptor.backend_context.models) == fresh_expected

      assert Enum.map(fresh_descriptor.backend_context.models, & &1.provider_id) ==
               fresh_provider_ids

      if lane == :custom_vision,
        do:
          refute(
            fresh_descriptor.backend_context.fingerprint == descriptor.backend_context.fingerprint
          )

      assert_receive {:run_event, %{type: "session.completed"}}, 20_000
      assert_final_wire(replay, content)
      assert pdf_parts(h.session.id) == [use, result]
      assert_saved(h.session.id, [use, result])
      assert %{analyses: 1, outer: 3} = Agent.get(h.counter, & &1)
    end
  end

  defp harness(root, lane) do
    h =
      SessionHarness.setup_session!(
        tmp_dir: root,
        install_provider?: false,
        session_config: %{"subagents" => false, "memory_context" => false}
      )

    on_exit(fn -> SessionHarness.cleanup!(h) end)

    outer =
      account(h.provider.name, nil, "anthropic", [%{id: @outer_model}], 99, h.provider.fixture)

    {analysis, defaults, accounts, expected} = lane_accounts(lane, outer)

    config =
      Map.merge(h.agent_config.config, %{
        "pdfHost" => %{
          "node_executable" => System.find_executable("node"),
          "helper_path" => Path.join(@root, "packages/tool-host/src/pdf/stdio.mjs")
        },
        "web_allowed_hosts" => ["localhost", "127.0.0.1"]
      })

    assert {:ok, _} =
             AgentConfigs.update(h.agent_config, %{
               provider: defaults.provider.name,
               model: defaults.default_model,
               tools: [@name],
               config: config
             })

    Agent.update(h.counter, &Map.merge(&1, %{analyses: 0, outer: 0}))
    by_name = Map.new([outer | accounts], &{&1.provider.name, &1.provider.id})

    expected_provider_ids =
      Enum.map(expected, fn ref -> Map.fetch!(by_name, hd(String.split(ref, "/", parts: 2))) end)

    Map.merge(h, %{
      outer: outer,
      analysis: analysis,
      expected: expected,
      expected_provider_ids: expected_provider_ids,
      lane: lane,
      model_context: %{
        configured_default: %{provider: defaults.provider.name, model: defaults.default_model},
        active_model: %{provider: outer.provider.name, model: @outer_model, supports_images: true}
      }
    })
  end

  defp lane_accounts(lane, _outer) when lane in [:anthropic, :google] do
    a = account("pdf-a-native", "anthropic", "anthropic", [vision("claude-sonnet-4-5")], 1)
    g = account("pdf-g-native", "google", "google", [vision("gemini-2.5-flash")], 2)
    o = account("pdf-z-generic", "openai", "openai", [vision("gpt-4o")], 3)

    if lane == :anthropic do
      {a, Map.put(a, :default_model, "claude-sonnet-4-5"), [a, g, o],
       ["pdf-a-native/claude-sonnet-4-5", "pdf-g-native/gemini-2.5-flash", "pdf-z-generic/gpt-4o"]}
    else
      {g, Map.put(g, :default_model, "gemini-2.5-flash"), [a, g, o],
       ["pdf-g-native/gemini-2.5-flash", "pdf-a-native/claude-sonnet-4-5", "pdf-z-generic/gpt-4o"]}
    end
  end

  defp lane_accounts(:extracted_image, _outer) do
    image = account("pdf-image", "openai", "openai", [vision("gpt-4o")], 1)
    custom = account("pdf-other", nil, "openai", [vision("other-vision")], 2)

    {image, Map.put(image, :default_model, "gpt-4o"), [image, custom],
     ["pdf-image/gpt-4o", "pdf-other/other-vision"]}
  end

  defp lane_accounts(:text_extraction, _outer) do
    text = account("pdf-text", "minimax", "openai", [%{id: "deepseek-chat", input: ["text"]}], 1)
    image = account("pdf-image", "openai", "openai", [vision("gpt-4o")], 2)

    {text, Map.put(text, :default_model, "deepseek-chat"), [text, image],
     ["pdf-text/deepseek-chat", "pdf-image/gpt-4o"]}
  end

  defp lane_accounts(:custom_vision, _outer) do
    custom = account("pdf-custom", nil, "openai", [vision("custom-z"), vision("custom-a")], 1)
    other = account("pdf-other", nil, "openai", [vision("other-vision")], 2)

    {custom, Map.put(custom, :default_model, "text-default"), [custom, other],
     ["pdf-custom/custom-z", "pdf-other/other-vision"]}
  end

  defp lane_accounts(:active, outer) do
    {outer, Map.put(outer, :default_model, @outer_model), [],
     [outer.provider.name <> "/" <> @outer_model]}
  end

  defp account(name, profile, type, models, index, fixture \\ nil) do
    fixture = fixture || Gaoxy.Test.open()
    config = if profile, do: %{"media_understanding" => %{"profile" => profile}}, else: %{}
    id = "00000000-0000-4000-8000-" <> String.pad_leading(to_string(index), 12, "0")

    assert {:ok, provider} =
             Providers.create(%{
               id: id,
               name: name,
               type: type,
               base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
               api_key_encrypted: "ordinary-fixture",
               config: config
             })

    assert {:ok, records} =
             Models.import(
               provider.id,
               Enum.with_index(models, fn attrs, i -> Map.put(attrs, :selection_order, i) end)
             )

    on_exit(fn ->
      Enum.each(records, &Models.delete/1)
      Providers.delete(provider.id)
    end)

    %{provider: provider, models: records, fixture: fixture}
  end

  defp install(h, input) do
    owner = self()

    if h.lane != :active do
      endpoint =
        case h.lane do
          :anthropic -> "/v1/messages"
          :google -> "/v1beta/models/gemini-2.5-flash:streamGenerateContent"
          _ -> "/v1/chat/completions"
        end

      Gaoxy.Test.stub(h.analysis.fixture, "POST", endpoint, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 2_000_000)
        analyze_response(h, owner, conn, Jason.decode!(body))
      end)
    end

    Gaoxy.Test.stub(h.provider.fixture, "POST", "/v1/messages", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 2_000_000)
      request = Jason.decode!(body)

      if h.lane == :active and List.wrap(request["tools"]) == [] do
        analyze_response(h, owner, conn, request)
      else
        index =
          Agent.get_and_update(h.counter, fn state ->
            {state.outer, %{state | outer: state.outer + 1}}
          end)

        send(owner, {:pdf_auto_outer, index, request})
        [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, h.session.id)
        {_, data} = :sys.get_state(worker, 1_000)
        adapter = :sys.get_state(data.runtime_pid, 1_000)

        send(
          owner,
          {:pdf_auto_descriptor, index,
           :sys.get_state(adapter.root, 1_000).catalog.registry.tools[@name]}
        )

        outer_response(conn, if(index == 0, do: input, else: nil))
      end
    end)
  end

  defp analyze_response(h, owner, conn, request) do
    Agent.update(h.counter, &Map.update!(&1, :analyses, fn n -> n + 1 end))
    send(owner, {:pdf_auto_analysis, request})

    case h.lane do
      lane when lane in [:anthropic, :active] ->
        text_response(conn, @analysis)

      :google ->
        sse(conn, [
          %{
            "candidates" => [
              %{"content" => %{"parts" => [%{"text" => @analysis}], "role" => "model"}}
            ]
          },
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      _ ->
        DeterministicProvider.send_sse(conn, [
          DeterministicProvider.text_chunk(@analysis),
          DeterministicProvider.finish_chunk("stop")
        ])
    end
  end

  defp assert_analysis_wire(h, request) do
    model = hd(h.analysis.models).model
    if h.lane != :google, do: assert(request["model"] == model)
    bytes = File.read!(@fixture)

    case h.lane do
      :anthropic ->
        assert [%{"role" => "user", "content" => [document, prompt]}] = request["messages"]

        assert document == %{
                 "type" => "document",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "application/pdf",
                   "data" => Base.encode64(bytes)
                 }
               }

        assert prompt == %{"type" => "text", "text" => @prompt}

      :google ->
        assert [%{"role" => "user", "parts" => [document, prompt]}] = request["contents"]

        assert document == %{
                 "inlineData" => %{
                   "mimeType" => "application/pdf",
                   "data" => Base.encode64(bytes)
                 }
               }

        assert prompt == %{"text" => @prompt}

      :text_extraction ->
        assert [%{"role" => "user", "content" => [text, prompt]}] = request["messages"]
        assert text["text"] =~ "First dense page ordinary document."
        assert text["text"] =~ "Third dense page ordinary document."
        assert text["text"] =~ "image rendering truncated"
        assert prompt == %{"type" => "text", "text" => @prompt}

      :active ->
        assert [%{"role" => "user", "content" => [text, red, blue, prompt]}] = request["messages"]
        assert text["text"] =~ "First dense page ordinary document."
        assert text["text"] =~ "Third dense page ordinary document."

        for image <- [red, blue] do
          assert image["type"] == "image"
          assert image["source"]["media_type"] == "image/png"
          assert_png(image["source"]["data"])
        end

        assert prompt == %{"type" => "text", "text" => @prompt}

      _ ->
        assert [%{"role" => "user", "content" => [text, red, blue, prompt]}] = request["messages"]
        assert text["text"] =~ "First dense page ordinary document."
        assert text["text"] =~ "Third dense page ordinary document."

        for image <- [red, blue] do
          assert %{
                   "type" => "image_url",
                   "image_url" => %{"url" => "data:image/png;base64," <> encoded}
                 } = image

          assert_png(encoded)
        end

        assert prompt == %{"type" => "text", "text" => @prompt}
    end
  end

  defp assert_png(encoded) do
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = Base.decode64!(encoded)
  end

  defp outer_response(conn, nil), do: text_response(conn, "PDF analysis received")

  defp outer_response(conn, input) do
    sse(conn, [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{
          "type" => "tool_use",
          "id" => "auto-pdf",
          "name" => ToolName.encode(@name),
          "input" => %{}
        }
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
      %{"type" => "message_stop"}
    ])
  end

  defp text_response(conn, text) do
    sse(conn, [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
      %{"type" => "message_stop"}
    ])
  end

  defp sse(conn, events),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
      )

  defp refs(models), do: Enum.map(models, & &1.reference)
  defp vision(id), do: %{id: id, input: ["text", "image"]}

  defp pdf_parts(id),
    do:
      for(
        message <- Synapsis.Message.list_by_session(id),
        part <- message.parts,
        match?(%ToolUse{tool: @name}, part) or match?(%ToolResult{tool_use_id: "auto-pdf"}, part),
        do: part
      )

  defp assert_final_wire(request, content) do
    blocks =
      Enum.flat_map(request["messages"], &List.wrap(&1["content"])) |> Enum.filter(&is_map/1)

    assert [result] = Enum.filter(blocks, &(&1["type"] == "tool_result"))
    assert result["is_error"] == false

    case result["content"] do
      text when is_binary(text) -> assert text == content
      blocks when is_list(blocks) -> assert Enum.map_join(blocks, "", & &1["text"]) == content
    end
  end

  defp assert_saved(id, [use, result]) do
    for part <- [use, result] do
      assert {:ok, dumped} = Synapsis.Part.dump(part)
      assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Synapsis.Part.load()
    end

    assert {:ok, turns} = Store.list_turns(id)

    for {turn, index} <- Enum.with_index(turns),
        do: assert({:ok, ^turn} = Store.get_turn(id, index))

    assert [stored] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_result", do: part)

    assert stored.content == result.content
    assert stored.projection == result.projection

    assert [%{id: "auto-pdf", name: @name, input: input}] =
             for(turn <- turns, part <- turn.parts, part[:type] == "tool_use", do: part)

    assert input == use.input
  end

  defp assert_worker_idle!(session_id) do
    assert [{worker, _}] = Registry.lookup(Synapsis.Session.Registry, session_id)
    observe_worker_idle!(worker, System.monotonic_time(:millisecond) + 10_000)
  end

  defp observe_worker_idle!(worker, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    assert remaining > 0,
           "Worker did not reach :idle with runtime_active: false before fixture setup deadline"

    {status, data} = :sys.get_state(worker, min(remaining, 1_000))

    case {status, data.runtime_active} do
      {:idle, false} ->
        :ok

      observed ->
        remaining = deadline - System.monotonic_time(:millisecond)
        assert remaining > 0, "Worker readiness deadline exceeded; observed #{inspect(observed)}"
        Process.sleep(min(remaining, 20))
        observe_worker_idle!(worker, deadline)
    end
  end
end
