defmodule SynapsisWeb.AssistantLive.IndexTest do
  use SynapsisWeb.ConnCase

  describe "assistant page" do
    test "mounts and renders assistant header", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/assistant")
      assert html =~ "Assistant"
      assert has_element?(view, "h1", "Assistant")
      assert html =~ "Global Assistant Online"
    end

    test "submits prompt and shows assistant dispatch response", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/assistant")

      html =
        view
        |> form("form", %{"prompt" => "what is current system status?"})
        |> render_submit()

      assert html =~ "what is current system status?"
      assert html =~ "has been dispatched"
      assert html =~ "Active project assistants"
    end
  end
end
