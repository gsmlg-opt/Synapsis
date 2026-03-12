defmodule SynapsisWeb.MemoryLive.ShowTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.{SemanticMemory, MemoryEvent, Repo}

  defp create_semantic_memory(attrs) do
    defaults = %{
      scope: "shared",
      scope_id: "",
      kind: "fact",
      title: "Test Memory Title",
      summary: "Test summary content for this memory",
      tags: ["test", "sample"],
      source: "human",
      importance: 0.8,
      confidence: 0.9,
      freshness: 1.0,
      contributed_by: "test_agent"
    }

    %SemanticMemory{}
    |> SemanticMemory.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp create_history_event(memory_id, scope, scope_id) do
    sid = if scope_id == "" or is_nil(scope_id), do: "_shared", else: scope_id

    %MemoryEvent{}
    |> MemoryEvent.changeset(%{
      scope: scope,
      scope_id: sid,
      agent_id: "ui_user",
      type: "memory_updated",
      importance: 0.6,
      payload: %{
        memory_id: memory_id,
        action: "update",
        previous: %{title: "Old Title", summary: "Old summary"}
      }
    })
    |> Repo.insert!()
  end

  setup do
    Repo.delete_all(MemoryEvent)
    Repo.delete_all(SemanticMemory)
    :ok
  end

  describe "show page" do
    test "mounts and renders memory details", %{conn: conn} do
      mem = create_semantic_memory(%{title: "Architecture Decision", kind: "decision"})
      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      assert html =~ "Architecture Decision"
      # Kind, scope, source are rendered as badge text
      assert html =~ "decision" or html =~ "primary"
    end

    test "renders breadcrumb navigation", %{conn: conn} do
      mem = create_semantic_memory(%{title: "Breadcrumb Test"})
      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      assert html =~ "Settings"
      assert html =~ "Memory"
      assert html =~ "Breadcrumb Test"
    end

    test "shows summary content", %{conn: conn} do
      mem = create_semantic_memory(%{summary: "This is the detailed summary"})
      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      assert html =~ "This is the detailed summary"
    end

    test "shows tags", %{conn: conn} do
      mem = create_semantic_memory(%{tags: ["elixir", "architecture"]})
      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      assert html =~ "elixir"
      assert html =~ "architecture"
    end

    test "shows metadata fields", %{conn: conn} do
      mem =
        create_semantic_memory(%{importance: 0.9, confidence: 0.85, contributed_by: "my_agent"})

      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      assert html =~ "0.9"
      assert html =~ "0.85"
      assert html =~ "my_agent"
      assert html =~ "Importance"
      assert html =~ "Confidence"
    end

    test "redirects to index for invalid id", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      {:ok, conn} =
        live(conn, ~p"/settings/memory/#{fake_id}")
        |> follow_redirect(conn)

      assert html_response(conn, 200) =~ "Memory not found"
    end

    test "clicking edit enables edit mode", %{conn: conn} do
      mem = create_semantic_memory(%{})
      {:ok, view, _html} = live(conn, ~p"/settings/memory/#{mem.id}")

      refute has_element?(view, "#edit-memory-form")

      view |> element("[phx-click=\"edit\"]") |> render_click()

      assert has_element?(view, "#edit-memory-form")
    end

    test "cancel edit returns to view mode", %{conn: conn} do
      mem = create_semantic_memory(%{})
      {:ok, view, _html} = live(conn, ~p"/settings/memory/#{mem.id}")

      view |> element("[phx-click=\"edit\"]") |> render_click()
      assert has_element?(view, "#edit-memory-form")

      view |> element("[phx-click=\"cancel_edit\"]") |> render_click()
      refute has_element?(view, "#edit-memory-form")
    end

    test "saving edit updates memory", %{conn: conn} do
      mem = create_semantic_memory(%{title: "Original Title", summary: "Original summary"})
      {:ok, view, _html} = live(conn, ~p"/settings/memory/#{mem.id}")

      view |> element("[phx-click=\"edit\"]") |> render_click()

      view
      |> form("#edit-memory-form", %{
        "title" => "Updated Title",
        "summary" => "Updated summary",
        "kind" => "decision",
        "tags" => "tag1, tag2",
        "importance" => "0.7",
        "confidence" => "0.8"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Memory updated"
      assert html =~ "Updated Title"
      assert html =~ "Updated summary"
    end

    test "archiving memory redirects to index", %{conn: conn} do
      mem = create_semantic_memory(%{title: "To Archive"})
      {:ok, view, _html} = live(conn, ~p"/settings/memory/#{mem.id}")

      {:ok, conn} =
        view
        |> element("[phx-click=\"archive\"]")
        |> render_click()
        |> follow_redirect(conn)

      assert html_response(conn, 200) =~ "Memory archived"
    end

    test "shows change history when events exist", %{conn: conn} do
      mem = create_semantic_memory(%{})
      create_history_event(mem.id, mem.scope, mem.scope_id)

      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      assert html =~ "Change History"
      assert html =~ "ui_user"
    end

    test "hides change history when no events", %{conn: conn} do
      mem = create_semantic_memory(%{})
      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      refute html =~ "Change History"
    end

    test "shows evidence events when present", %{conn: conn} do
      mem = create_semantic_memory(%{evidence_event_ids: ["evt_abc12345", "evt_def67890"]})
      {:ok, _view, html} = live(conn, ~p"/settings/memory/#{mem.id}")

      assert html =~ "Evidence Events"
      assert html =~ "evt_abc1"
    end
  end
end
