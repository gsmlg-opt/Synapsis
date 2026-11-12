defmodule SynapsisWeb.LocalAgentLive.Index do
  @moduledoc """
  Local Agents page: process status and start/stop for each local agent, its
  threads, and a conversation view that streams `SynapsisLocalAgents.Event`s.
  Adapter requests run in `start_async`; the LiveView never blocks on an agent.
  """
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  alias SynapsisLocalAgents.Event

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: SynapsisLocalAgents.subscribe_all()

    {:ok,
     socket
     |> assign(
       page_title: "Local Agents",
       agent_id: nil,
       thread_id: nil,
       threads: [],
       messages: [],
       streaming: %{},
       current_turn: nil,
       turn_status: nil,
       turn_error: nil,
       subscribed: nil
     )
     |> load_agents()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    agent_id = params["agent_id"]
    thread_id = params["thread_id"]

    socket =
      socket |> subscribe_agent(agent_id) |> assign(agent_id: agent_id, thread_id: thread_id)

    socket =
      cond do
        is_nil(agent_id) or not running?(socket, agent_id) ->
          assign(socket,
            threads: [],
            messages: [],
            streaming: %{},
            current_turn: nil,
            turn_status: nil
          )

        thread_id ->
          socket
          |> assign(messages: [], streaming: %{}, current_turn: nil, turn_status: nil)
          |> start_async(:thread, fn -> open_thread(agent_id, thread_id) end)

        true ->
          start_async(socket, :threads, fn -> SynapsisLocalAgents.list_threads(agent_id) end)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_agent", %{"id" => id}, socket) do
    case SynapsisLocalAgents.start(id) do
      :ok ->
        {:noreply, load_agents(socket)}

      {:error, reason} ->
        {:noreply,
         socket |> load_agents() |> put_flash(:error, "Start failed: #{inspect(reason)}")}
    end
  end

  def handle_event("stop_agent", %{"id" => id}, socket) do
    :ok = SynapsisLocalAgents.stop(id)
    {:noreply, load_agents(socket)}
  end

  def handle_event("new_thread", _params, socket) do
    agent_id = socket.assigns.agent_id

    {:noreply,
     start_async(socket, :new_thread, fn -> SynapsisLocalAgents.start_thread(agent_id) end)}
  end

  def handle_event("send_message", %{"text" => text}, socket) do
    text = String.trim(text || "")
    %{agent_id: agent_id, thread_id: thread_id} = socket.assigns

    if text == "" or is_nil(thread_id) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> reset_react_form("local-agent-message-form")
       |> update(
         :messages,
         &(&1 ++ [%{id: "local-#{System.unique_integer([:positive])}", role: :user, text: text}])
       )
       |> assign(turn_status: nil)
       |> start_async(:turn, fn -> SynapsisLocalAgents.start_turn(agent_id, thread_id, text) end)}
    end
  end

  def handle_event("interrupt_turn", _params, socket) do
    %{agent_id: agent_id, thread_id: thread_id, current_turn: turn_id} = socket.assigns

    {:noreply,
     start_async(socket, :interrupt, fn ->
       SynapsisLocalAgents.interrupt_turn(agent_id, thread_id, turn_id)
     end)}
  end

  @impl true
  def handle_async(:threads, {:ok, {:ok, threads}}, socket),
    do: {:noreply, assign(socket, threads: threads)}

  def handle_async(:thread, {:ok, {:ok, thread}}, socket) do
    messages = Enum.flat_map(thread.turns, & &1.items)
    {:noreply, assign(socket, messages: messages)}
  end

  def handle_async(:new_thread, {:ok, {:ok, %{id: thread_id}}}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/local-agents/#{socket.assigns.agent_id}/threads/#{thread_id}")}
  end

  def handle_async(:turn, {:ok, {:ok, %{turn_id: turn_id}}}, socket) do
    {:noreply, assign(socket, current_turn: socket.assigns.current_turn || turn_id)}
  end

  def handle_async(:interrupt, {:ok, :ok}, socket), do: {:noreply, socket}

  def handle_async(name, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, "#{name} failed: #{inspect(reason)}")}

  def handle_async(name, {:exit, reason}, socket),
    do: {:noreply, put_flash(socket, :error, "#{name} failed: #{inspect(reason)}")}

  @impl true
  def handle_info({:local_agent_event, %Event{type: :status, agent_id: id}}, socket) do
    socket = load_agents(socket)
    # A freshly started agent can now serve the page it was opened on.
    if id == socket.assigns.agent_id and running?(socket, id) and socket.assigns.threads == [] and
         is_nil(socket.assigns.thread_id) do
      {:noreply, start_async(socket, :threads, fn -> SynapsisLocalAgents.list_threads(id) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:local_agent_event, %Event{thread_id: thread_id} = event}, socket)
      when thread_id == socket.assigns.thread_id and not is_nil(thread_id) do
    {:noreply, apply_event(socket, event)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_event(socket, %Event{type: :turn_started, turn_id: turn_id}),
    do: assign(socket, current_turn: turn_id, turn_status: "running", turn_error: nil)

  defp apply_event(socket, %Event{type: :item_delta, item_id: item_id, data: %{delta: delta}}) do
    streaming =
      Map.update(
        socket.assigns.streaming,
        item_id,
        %{order: map_size(socket.assigns.streaming), text: delta},
        fn s ->
          %{s | text: s.text <> delta}
        end
      )

    assign(socket, streaming: streaming)
  end

  defp apply_event(socket, %Event{
         type: :item_completed,
         item_id: id,
         data: %{item: %{type: "agentMessage", text: text}}
       }) do
    socket
    |> update(:messages, &(&1 ++ [%{id: id, role: :agent, text: text}]))
    |> update(:streaming, &Map.delete(&1, id))
  end

  defp apply_event(socket, %Event{type: :interaction, data: %{method: method, decision: decision}}) do
    update(
      socket,
      :messages,
      &(&1 ++
          [
            %{
              id: "note-#{System.unique_integer([:positive])}",
              role: :note,
              text: "#{method}: #{decision}"
            }
          ])
    )
  end

  defp apply_event(socket, %Event{type: :turn_completed, data: %{status: status} = data}) do
    # Keep any text still streaming as a finished agent message.
    pending =
      socket.assigns.streaming
      |> Enum.sort_by(fn {_id, s} -> s.order end)
      |> Enum.map(fn {id, s} -> %{id: id, role: :agent, text: s.text} end)

    socket
    |> update(:messages, &(&1 ++ pending))
    |> assign(streaming: %{}, current_turn: nil, turn_status: status, turn_error: data[:error])
  end

  defp apply_event(socket, _event), do: socket

  defp open_thread(agent_id, thread_id) do
    with {:ok, _} <- SynapsisLocalAgents.resume_thread(agent_id, thread_id),
         do: SynapsisLocalAgents.read_thread(agent_id, thread_id)
  end

  defp subscribe_agent(%{assigns: %{subscribed: id}} = socket, id), do: socket

  defp subscribe_agent(socket, id) do
    if connected?(socket) do
      if socket.assigns.subscribed,
        do:
          Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "local_agent:#{socket.assigns.subscribed}")

      if id, do: SynapsisLocalAgents.subscribe(id)
    end

    assign(socket, subscribed: id)
  end

  defp load_agents(socket), do: assign(socket, agents: SynapsisLocalAgents.list())

  defp running?(socket, id),
    do: Enum.any?(socket.assigns.agents, &(&1.config.id == id and &1.status.state == :running))

  defp status_variant(:running), do: "success"
  defp status_variant(:crashed), do: "error"
  defp status_variant(:starting), do: "info"
  defp status_variant(_), do: "warning"

  defp streaming_list(streaming),
    do:
      streaming
      |> Enum.sort_by(fn {_id, s} -> s.order end)
      |> Enum.map(fn {id, s} -> %{id: id, text: s.text} end)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, selected: Enum.find(assigns.agents, &(&1.config.id == assigns.agent_id)))

    ~H"""
    <div class="max-w-7xl mx-auto p-4 sm:p-6">
      <h1 class="text-2xl font-bold mb-4">Local Agents</h1>
      <div class="grid gap-4 md:grid-cols-[18rem_1fr]">
        <div class="space-y-2">
          <p :if={@agents == []} class="text-sm text-on-surface-variant">
            No local agents configured. Install <code>codex</code> and restart Synapsis.
          </p>
          <div
            :for={agent <- @agents}
            id={"local-agent-#{agent.config.id}"}
            class={[
              "rounded border p-3 space-y-2",
              if(agent.config.id == @agent_id, do: "border-primary", else: "border-outline-variant")
            ]}
          >
            <div class="flex items-center justify-between gap-2">
              <.link patch={~p"/local-agents/#{agent.config.id}"} class="font-medium">{agent.config.name}</.link>
              <.dm_badge
                data-role="status"
                variant={status_variant(agent.status.state)}
                size="xs"
                soft
              >
                {agent.status.state}
              </.dm_badge>
            </div>
            <div class="text-xs text-on-surface-variant">{agent.config.kind}</div>
            <div :if={agent.status.last_error} class="text-xs text-error break-all">
              {agent.status.last_error}
            </div>
            <div class="flex gap-2">
              <.dm_btn
                :if={agent.status.state in [:stopped, :crashed]}
                variant="primary"
                size="xs"
                phx-click="start_agent"
                phx-value-id={agent.config.id}
              >
                Start
              </.dm_btn>
              <.dm_btn
                :if={agent.status.state in [:starting, :running]}
                variant="ghost"
                size="xs"
                phx-click="stop_agent"
                phx-value-id={agent.config.id}
              >
                Stop
              </.dm_btn>
            </div>
          </div>
        </div>

        <div class="min-w-0">
          <p :if={is_nil(@selected)} class="text-sm text-on-surface-variant">Select an agent.</p>
          <p
            :if={@selected && @selected.status.state != :running}
            class="text-sm text-on-surface-variant"
          >
            Start {@selected.config.name} to see its sessions.
          </p>

          <div
            :if={@selected && @selected.status.state == :running && is_nil(@thread_id)}
            class="space-y-3"
          >
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold">Sessions</h2>
              <.dm_btn variant="primary" size="sm" phx-click="new_thread">New session</.dm_btn>
            </div>
            <div data-role="thread-list" class="space-y-1">
              <p :if={@threads == []} class="text-sm text-on-surface-variant">No sessions yet.</p>
              <.link
                :for={thread <- @threads}
                patch={~p"/local-agents/#{@agent_id}/threads/#{thread.id}"}
                class="block rounded border border-outline-variant p-2 hover:bg-surface-container"
              >
                <div class="text-sm truncate">{thread.title || thread.id}</div>
                <div class="text-xs text-on-surface-variant">{thread.updated_at}</div>
              </.link>
            </div>
          </div>

          <div
            :if={@selected && @selected.status.state == :running && @thread_id}
            class="flex flex-col gap-3"
          >
            <div class="flex items-center justify-between gap-2">
              <.link patch={~p"/local-agents/#{@agent_id}"} class="link text-sm">← Sessions</.link>
              <div class="flex items-center gap-2">
                <.dm_badge :if={@turn_status} data-role="turn-status" variant="info" size="xs" soft>
                  {@turn_status}
                </.dm_badge>
                <.dm_btn :if={@current_turn} variant="ghost" size="xs" phx-click="interrupt_turn">
                  Interrupt
                </.dm_btn>
              </div>
            </div>

            <div :if={@turn_error} data-role="turn-error" role="alert" class="text-sm text-error">
              {@turn_error}
            </div>

            <div data-role="agent-stream" class="space-y-2">
              <div
                :for={message <- @messages}
                class={[
                  "rounded p-3 text-sm whitespace-pre-wrap",
                  message.role == :user && "bg-primary-container text-on-primary-container ml-8",
                  message.role == :agent && "bg-surface-container mr-8",
                  message.role == :note && "text-xs text-on-surface-variant"
                ]}
              >
                {message.text}
              </div>
              <div
                :for={item <- streaming_list(@streaming)}
                class="rounded p-3 text-sm whitespace-pre-wrap bg-surface-container mr-8"
              >
                {item.text}
              </div>
            </div>

            <.react_form
              for={%{}}
              id="local-agent-message-form"
              values={%{"text" => ""}}
              draft={react_form_draft(assigns, "local-agent-message-form")}
              phx-submit="send_message"
              class="space-y-2"
            >
              <.dm_textarea
                id="local-agent-message"
                name="text"
                value=""
                rows={3}
                label="Message"
                resize="vertical"
              />
              <:actions>
                <.dm_btn type="submit" native_submit variant="primary" size="sm">Send</.dm_btn>
              </:actions>
            </.react_form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
