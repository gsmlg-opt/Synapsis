defmodule SynapsisWeb.SessionLive do
  use SynapsisWeb, :live_view

  @project_path "."

  @impl true
  def mount(_params, _session, socket) do
    sessions = load_sessions()

    {:ok,
     assign(socket,
       sessions: sessions,
       active_session_id: nil,
       project_path: @project_path
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, assign(socket, active_session_id: id)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, active_session_id: nil)}
  end

  @impl true
  def handle_event("create_session", _params, socket) do
    case Synapsis.Sessions.create(socket.assigns.project_path) do
      {:ok, session} ->
        sessions = [session | socket.assigns.sessions]

        {:noreply,
         socket
         |> assign(sessions: sessions)
         |> push_patch(to: ~p"/sessions/#{session.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("delete_session", %{"id" => id}, socket) do
    case Synapsis.Sessions.delete(id) do
      {:ok, _} ->
        sessions = Enum.reject(socket.assigns.sessions, &(&1.id == id))

        socket =
          if socket.assigns.active_session_id == id do
            socket
            |> assign(sessions: sessions, active_session_id: nil)
            |> push_patch(to: ~p"/")
          else
            assign(socket, sessions: sessions)
          end

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete session")}
    end
  end

  defp load_sessions do
    case Synapsis.Sessions.list(@project_path) do
      {:ok, sessions} -> sessions
      _ -> []
    end
  end
end
