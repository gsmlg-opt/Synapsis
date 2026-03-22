defmodule SynapsisWeb.AssistantLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "assistant page" do
    test "mounts and renders assistant header", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/assistant")
      assert html =~ "Assistant"
      assert has_element?(view, "h1", "Assistants")
    end

    test "renders default assistant cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/assistant")

      assert html =~ "Build"
      assert html =~ "Workspace-driven coding assistant"
    end
  end
end
