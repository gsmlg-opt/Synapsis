defmodule SynapsisWeb.MemoryLive.IndexTest do
  use SynapsisWeb.ConnCase

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

  defp clean_semantic_memories do
    dir = Application.get_env(:synapsis_core, :memory_dir)
    if dir, do: File.rm_rf!(dir)

    if :ets.info(:synapsis_memory_file_index) != :undefined,
      do: :ets.delete_all_objects(:synapsis_memory_file_index)
  end

  setup do
    clean_semantic_memories()
    :ok
  end

  describe "memory page" do
    test "mounts and renders breadcrumb", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Settings"
      assert html =~ "Memory"
    end

    test "shows Knowledge tab by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "Knowledge"
      assert html =~ "Events"
      assert html =~ "Checkpoints"
    end

    test "shows empty state when no memories", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "No memories yet"
    end

    test "displays existing memories", %{conn: conn} do
      create_semantic_memory(%{
        title: "My Test Fact",
        summary: "Important fact about the workspace"
      })

      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "My Test Fact"
      assert html =~ "Important fact about the workspace"
    end

    test "shows New Memory button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "New Memory"
    end

    test "shows kind and scope badges on memories", %{conn: conn} do
      create_semantic_memory(%{kind: "decision", scope: "agent", scope_id: "main"})
      {:ok, _view, html} = live(conn, ~p"/settings/memory")
      assert html =~ "decision"
      assert html =~ "agent"
    end

    test "clicking New Memory shows create form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      view |> element("el-dm-button", "New Memory") |> render_click()
      assert has_element?(view, "#create-memory-form")
    end

    test "create form can save a new memory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      view |> element("el-dm-button", "New Memory") |> render_click()

      view
      |> form("#create-memory-form", %{
        "scope" => "shared",
        "kind" => "fact",
        "title" => "New fact",
        "summary" => "This is a new fact",
        "tags" => "tag1, tag2"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Memory saved"
      assert html =~ "New fact"
    end

    test "switching to Events tab shows events section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      view |> element("el-dm-button", "Events") |> render_click()
      html = render(view)
      assert html =~ "No events yet"
    end

    test "switching to Checkpoints tab shows checkpoints section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      view |> element("el-dm-button", "Checkpoints") |> render_click()
      html = render(view)
      assert html =~ "No checkpoints yet"
    end

    test "archive button removes memory from list", %{conn: conn} do
      mem = create_semantic_memory(%{title: "To Archive"})
      {:ok, view, _html} = live(conn, ~p"/settings/memory")
      assert render(view) =~ "To Archive"

      view |> element("[phx-click=\"archive\"][phx-value-id=\"#{mem.id}\"]") |> render_click()
      html = render(view)
      assert html =~ "Memory archived"
      refute html =~ "To Archive"
    end
  end
end
