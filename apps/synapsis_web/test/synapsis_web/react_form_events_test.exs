defmodule SynapsisWeb.ReactFormEventsTest do
  use ExUnit.Case, async: true

  alias SynapsisWeb.{ReactFormEvents, ReactForms}

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest
  @endpoint SynapsisServer.Endpoint

  defmodule RemountView do
    use SynapsisWeb, {:live_view, layout: false}

    @impl true
    def mount(_params, _session, socket), do: {:ok, assign(socket, transport: "stdio")}

    @impl true
    def handle_event("switch_transport", _params, socket),
      do: {:noreply, assign(socket, transport: "streamable_http")}

    @impl true
    def render(assigns) do
      ~H"""
      <.react_form id="remount-form" structure={@transport}>
        <.dm_input name="name" value="server" label="Name" />
        <.dm_react_field name="transport" type="select" label="Transport" />
        <.dm_input :if={@transport == "stdio"} name="command" value="npx" label="Command" />
        <.dm_input :if={@transport == "streamable_http"} name="url" value="" label="URL" />
        <.dm_checkbox name="enabled" value="true" label="Enabled" />
        <:actions>
          <.dm_btn type="submit">Save Changes</.dm_btn>
        </:actions>
      </.react_form>
      """
    end
  end

  defmodule Handler do
    def handle_event("save", %{"name" => ""}, socket),
      do: {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Name is required")}

    def handle_event("save", params, socket),
      do: {:noreply, Phoenix.Component.assign(socket, :saved, params)}
  end

  setup do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}
    {:cont, socket} = ReactFormEvents.on_mount(:default, %{}, %{}, socket)
    %{socket: socket}
  end

  test "typed JSON preserves handler compatibility and retains the typed draft", %{socket: socket} do
    values = %{
      "name" => "Agent",
      "agent" => %{"enabled" => false, "max_tokens" => 0},
      "tools" => ["read"],
      "optional" => nil
    }

    assert {:reply, %{status: "ok"}, socket} =
             ReactFormEvents.dispatch(Handler, "save", "settings--42", values, 1, socket)

    assert socket.assigns.saved == %{
             "name" => "Agent",
             "agent" => %{"enabled" => "false", "max_tokens" => "0"},
             "tools" => ["read"],
             "optional" => ""
           }

    assert socket.assigns.react_form_drafts["settings"] == values
  end

  test "server rejection keeps the draft and the next admitted save clears its error", %{
    socket: socket
  } do
    assert {:reply, %{status: "error", message: "Name is required"}, socket} =
             ReactFormEvents.dispatch(Handler, "save", "settings", %{"name" => ""}, 1, socket)

    assert socket.assigns.react_form_drafts["settings"] == %{"name" => ""}

    assert {:reply, %{status: "ok"}, socket} =
             ReactFormEvents.dispatch(
               Handler,
               "save",
               "settings",
               %{"name" => "Fixed"},
               2,
               socket
             )

    assert socket.assigns.saved["name"] == "Fixed"
  end

  test "a remounted form may restart its local revision", %{socket: socket} do
    {:reply, _, socket} =
      ReactFormEvents.dispatch(Handler, "save", "settings--42", %{"name" => "First"}, 5, socket)

    assert {:reply, %{status: "ok"}, socket} =
             ReactFormEvents.dispatch(
               Handler,
               "save",
               "settings--42",
               %{"name" => "Remounted"},
               1,
               socket
             )

    assert socket.assigns.saved["name"] == "Remounted"
  end

  test "structural remount sends unchanged nested controls and actions in full" do
    {:ok, view, _html} = live_isolated(build_conn(), RemountView)
    old_id = ReactForms.form_mount_id("remount-form", "stdio")
    assert has_element?(view, "[id='#{old_id}'] input[name='name']")

    render_hook(view, "switch_transport", %{})

    new_id = ReactForms.form_mount_id("remount-form", "streamable_http")
    refute has_element?(view, "[id='#{old_id}']")
    assert has_element?(view, "[id='#{new_id}'] input[name='name'][value='server']")
    assert has_element?(view, "[id='#{new_id}'] [data-dm-react-field]")
    assert has_element?(view, "[id='#{new_id}'] input[name='enabled']")
    assert has_element?(view, "[id='#{new_id}'] el-dm-button[type='submit']", "Save Changes")
    assert has_element?(view, "[id='#{new_id}'] input[name='url']")
    refute has_element?(view, "[id='#{new_id}'] input[name='command']")
    refute has_element?(view, "[id='#{new_id}'] [data-phx-skip]")
  end

  test "reset clears retained drafts or replaces them explicitly", %{socket: socket} do
    {:reply, _, socket} =
      ReactFormEvents.dispatch(Handler, "save", "settings--42", %{"name" => "Draft"}, 1, socket)

    socket = ReactForms.reset_react_form(socket, "settings")
    refute Map.has_key?(socket.assigns.react_form_drafts, "settings")
    socket = ReactForms.reset_react_form(socket, "settings", %{"name" => "Stored"})
    assert socket.assigns.react_form_drafts["settings"] == %{"name" => "Stored"}
  end
end
