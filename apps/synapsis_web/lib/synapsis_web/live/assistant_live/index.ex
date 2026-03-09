defmodule SynapsisWeb.AssistantLive.Index do
  use SynapsisWeb, :live_view

  alias Synapsis.Agent

  @global_project_id "__global__"

  @impl true
  def mount(_params, _session, socket) do
    Agent.start_project(@global_project_id, %{kind: :global_assistant})

    {:ok,
     assign(socket,
       page_title: "Assistant",
       prompt: "",
       messages: [
         %{
           role: :assistant,
           content: "Global assistant is online. Ask about system status or dispatch work."
         }
       ]
     )}
  end

  @impl true
  def handle_event("send", %{"prompt" => prompt}, socket) do
    prompt = String.trim(prompt || "")

    if prompt == "" do
      {:noreply, socket}
    else
      work_id = "global-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

      dispatch_result =
        Agent.dispatch_work(%{
          work_id: work_id,
          project_id: @global_project_id,
          task_type: :ad_hoc_prompt,
          payload: %{prompt: prompt},
          origin: :user
        })

      status = build_status_message(dispatch_result, work_id)

      {:noreply,
       assign(socket,
         prompt: "",
         messages:
           socket.assigns.messages ++
             [
               %{role: :user, content: prompt},
               %{role: :assistant, content: status}
             ]
       )}
    end
  end

  defp build_status_message(:ok, work_id) do
    active_projects = Agent.list_projects() |> Enum.count()
    recent_events = Agent.list_events(project_id: @global_project_id) |> Enum.take(-3)

    """
    Received. Work item `#{work_id}` has been dispatched.
    Active project assistants: #{active_projects}.
    Recent global events: #{format_events(recent_events)}.
    """
    |> String.trim()
  end

  defp build_status_message({:error, reason}, _work_id) do
    "Dispatch failed: #{inspect(reason)}"
  end

  defp format_events([]), do: "none"

  defp format_events(events) do
    events
    |> Enum.map_join(", ", fn event -> Atom.to_string(event.event_type) end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-bold">Assistant</h1>
        <.dm_badge color="success" size="sm">
          Global Assistant Online
        </.dm_badge>
      </div>

      <.dm_card variant="bordered" class="min-h-64">
        <:title>Conversation</:title>
        <div class="space-y-3">
          <.chat_bubble
            :for={message <- @messages}
            role={to_string(message.role)}
          >
            <p class="whitespace-pre-wrap leading-relaxed">{message.content}</p>
          </.chat_bubble>
        </div>
        <:action>
          <.dm_form for={to_form(%{})} as={:assistant} phx-submit="send" class="w-full">
            <div class="flex gap-3 w-full">
              <div class="flex-1">
                <.dm_input
                  type="text"
                  name="prompt"
                  value={@prompt}
                  label=""
                  placeholder="Ask global assistant to summarize system status..."
                />
              </div>
              <.dm_btn type="submit" variant="primary">
                Send
              </.dm_btn>
            </div>
          </.dm_form>
        </:action>
      </.dm_card>
    </div>
    """
  end
end
