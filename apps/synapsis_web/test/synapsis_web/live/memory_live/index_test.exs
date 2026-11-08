defmodule SynapsisWeb.MemoryLive.IndexTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.Memory

  defp create_semantic_memory(attrs) do
    defaults = %{
      scope: "shared",
      scope_id: "",
      kind: "fact",
      title: "Test Memory",
      summary: "Test summary content",
      tags: ["test"],
      source: "human",
      importance: 1.0,
      confidence: 1.0,
      freshness: 1.0
    }

    {:ok, memory} = Memory.store_semantic(Map.merge(defaults, attrs))
    memory
  end

  setup do
    Synapsis.DataCase.reset_memory_store()
    :ok
  end

  defp knowledge(conn) do
    {:ok, view, _} = live(conn, ~p"/agent/memory")
    html = view |> element("el-dm-button", "Knowledge") |> render_click()
    {:ok, view, html}
  end

  test "defaults to workspace memory inside Agent navigation", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agent/memory")
    assert html =~ "Workspace Markdown"
    assert has_element?(view, "#memory-agent-form")
    refute has_element?(view, "#memory-scope-filter")
    refute has_element?(view, "[data-testid='settings-sidebar']")
    assert has_element?(view, "#agent-mobile-nav a[href='/agent/memory'][aria-current='page']")
  end

  test "reads configured agent workspace Markdown with line numbers and rejects arbitrary roots",
       %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "agent-memory-view-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "memory"))
    File.write!(Path.join(root, "MEMORY.md"), "# Persistent memory\nUse scoped tests.\n")
    File.write!(Path.join(root, "memory/2026-10-24.md"), "Daily notes\n")
    name = "memory-view-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: name, config: %{"workspace_path" => root}})

    on_exit(fn ->
      Synapsis.Config.Store.delete(:agent, agent.id)
      File.rm_rf!(root)
    end)

    {:ok, view, _} = live(conn, ~p"/agent/memory")
    view |> form("#memory-agent-form", agent: name) |> render_change()
    html = render_async(view)
    assert html =~ "MEMORY.md"
    assert html =~ "memory/2026-10-24.md"
    view |> element("[phx-click='read_workspace'][phx-value-path='MEMORY.md']") |> render_click()
    assert render_async(view) =~ "Use scoped tests."
    assert has_element?(view, "#workspace-memory-content", "Lines 1")

    render_hook(view, "select_agent", %{"agent" => "/tmp"})
    assert render(view) =~ "Select a configured agent"
    render_hook(view, "read_workspace", %{"path" => "/etc/passwd"})
    assert render(view) =~ "Select a listed workspace memory file"
  end

  test "missing workspace files render an empty state without creating memory", %{conn: conn} do
    root =
      Path.join(System.tmp_dir!(), "agent-memory-missing-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    name = "memory-empty-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: name, config: %{"workspace_path" => root}})

    on_exit(fn ->
      Synapsis.Config.Store.delete(:agent, agent.id)
      File.rm_rf!(root)
    end)

    {:ok, view, _} = live(conn, ~p"/agent/memory")
    view |> form("#memory-agent-form", agent: name) |> render_change()
    assert render_async(view) =~ "No workspace memory files yet."
    refute File.exists?(Path.join(root, "MEMORY.md"))
    refute File.exists?(Path.join(root, "memory"))
  end

  test "uninitialized workspace reports unavailable rather than an empty successful read", %{
    conn: conn
  } do
    root =
      Path.join(System.tmp_dir!(), "agent-workspace-absent-#{System.unique_integer([:positive])}")

    name = "memory-absent-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: name, config: %{"workspace_path" => root}})

    on_exit(fn -> Synapsis.Config.Store.delete(:agent, agent.id) end)
    {:ok, view, _} = live(conn, ~p"/agent/memory")
    view |> form("#memory-agent-form", agent: name) |> render_change()
    html = render_async(view)
    assert html =~ "Workspace is unavailable or has not been initialized"
    refute html =~ "No workspace memory files yet."
    refute File.exists?(root)
  end

  test "host tab does not query on entry and later disablement blocks recall", %{conn: conn} do
    alias Synapsis.Memory.Settings
    alias Synapsis.Config.Store
    Synapsis.DataCase.clear_config_store(:memory)
    Store.reload(:memory)

    on_exit(fn ->
      Synapsis.DataCase.clear_config_store(:memory)
      Store.reload(:memory)
    end)

    server = Gaoxy.Test.open()
    endpoint = String.trim_trailing(Gaoxy.Test.url(server), "/")
    parent = self()

    Gaoxy.Test.stub(server, "POST", "/memory/synapsis/call/recall", fn conn ->
      send(parent, :unexpected_recall)
      Plug.Conn.send_resp(conn, 500, "unexpected recall")
    end)

    config = %{
      "backend" => "workspace",
      "host_agent" => %{"enabled" => true, "endpoint" => endpoint, "agent_id" => "synapsis"}
    }

    assert {:ok, _} = Settings.save(config)
    {:ok, view, _} = live(conn, ~p"/agent/memory")
    view |> element("el-dm-button", "Host agent") |> render_click()
    assert has_element?(view, "#host-memory-query")
    refute_receive :unexpected_recall
    assert {:ok, _} = Settings.save(put_in(config, ["host_agent", "enabled"], false))
    render_hook(view, "recall_host", %{"query" => "remember"})
    refute has_element?(view, "#host-memory-query")
    refute has_element?(view, "#host-memory-state")
    assert has_element?(view, "#memory-agent-form")
    refute_receive :unexpected_recall
  end

  test "long source lines show the reader notice without a misleading next page", %{conn: conn} do
    root =
      Path.join(System.tmp_dir!(), "agent-memory-long-line-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "MEMORY.md"),
      String.duplicate("x", 12_100) <> "\nnext source line\n"
    )

    name = "memory-long-#{System.unique_integer([:positive])}"

    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{name: name, config: %{"workspace_path" => root}})

    on_exit(fn ->
      Synapsis.Config.Store.delete(:agent, agent.id)
      File.rm_rf!(root)
    end)

    {:ok, view, _} = live(conn, ~p"/agent/memory")
    view |> form("#memory-agent-form", agent: name) |> render_change()
    render_async(view)
    view |> element("[phx-click='read_workspace'][phx-value-path='MEMORY.md']") |> render_click()
    html = render_async(view)

    assert html =~
             "Excerpt stops within a source line. Read the source file to retrieve the full line."

    refute has_element?(view, "[phx-click='read_workspace'][phx-value-from]")
    refute html =~ "next source line"
  end

  describe "memory page" do
    test "mounts and renders breadcrumb", %{conn: conn} do
      {:ok, _view, html} = knowledge(conn)
      assert html =~ "Agent"
      assert html =~ "Memory"
    end

    test "shows Knowledge tab when selected", %{conn: conn} do
      {:ok, view, html} = knowledge(conn)
      assert html =~ "Knowledge"
      assert html =~ "Events"
      assert html =~ "Checkpoints"
      assert has_element?(view, "#memory-scope-filter")
      assert has_element?(view, "#memory-kind-filter")
      assert has_element?(view, "#memory-source-filter")
      assert_unique_form_ids(html)
    end

    test "shows empty state when no memories", %{conn: conn} do
      {:ok, _view, html} = knowledge(conn)
      assert html =~ "No memories yet"
    end

    test "displays existing memories", %{conn: conn} do
      create_semantic_memory(%{
        title: "My Test Fact",
        summary: "Important fact about the workspace"
      })

      {:ok, _view, html} = knowledge(conn)
      assert html =~ "My Test Fact"
      assert html =~ "Important fact about the workspace"
    end

    test "shows New Memory button", %{conn: conn} do
      {:ok, _view, html} = knowledge(conn)
      assert html =~ "New Memory"
    end

    test "shows kind and scope badges on memories", %{conn: conn} do
      create_semantic_memory(%{kind: "decision", scope: "agent", scope_id: "main"})
      {:ok, _view, html} = knowledge(conn)
      assert html =~ "decision"
      assert html =~ "agent"
    end

    test "clicking New Memory shows create form", %{conn: conn} do
      {:ok, view, _html} = knowledge(conn)
      view |> element("el-dm-button", "New Memory") |> render_click()
      assert has_element?(view, "#create-memory-form")
      assert_unique_form_ids(render(view))
    end

    test "create form can save a new memory", %{conn: conn} do
      {:ok, view, _html} = knowledge(conn)
      view |> element("el-dm-button", "New Memory") |> render_click()

      view
      |> react_form_submit("create-memory-form", %{
        "scope" => "shared",
        "kind" => "fact",
        "title" => "New fact",
        "summary" => "This is a new fact",
        "tags" => "tag1, tag2"
      })

      html = render(view)
      assert html =~ "Memory saved"
      assert html =~ "New fact"
    end

    test "switching to Events tab shows events section", %{conn: conn} do
      {:ok, view, _html} = knowledge(conn)
      view |> element("el-dm-button", "Events") |> render_click()
      html = render(view)
      assert html =~ "No events yet"
      assert has_element?(view, "#memory-event-type-filter")
      assert_unique_form_ids(html)
    end

    test "switching to Checkpoints tab shows checkpoints section", %{conn: conn} do
      {:ok, view, _html} = knowledge(conn)
      view |> element("el-dm-button", "Checkpoints") |> render_click()
      html = render(view)
      assert html =~ "No checkpoints yet"
    end

    test "archive button removes memory from list", %{conn: conn} do
      mem = create_semantic_memory(%{title: "To Archive"})
      {:ok, view, _html} = knowledge(conn)
      assert render(view) =~ "To Archive"

      view |> element("[phx-click=\"archive\"][phx-value-id=\"#{mem.id}\"]") |> render_click()
      html = render(view)
      assert html =~ "Memory archived"
      refute html =~ "To Archive"
    end
  end
end
