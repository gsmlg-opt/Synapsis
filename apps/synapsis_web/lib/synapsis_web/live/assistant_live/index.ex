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
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-bold">Assistant</h1>
          <span class="text-xs px-2 py-1 rounded bg-emerald-500/20 text-emerald-300 border border-emerald-600/30">
            Global Assistant Online
          </span>
        </div>

        <div class="bg-gray-900 border border-gray-800 rounded-lg p-4 space-y-3 min-h-64">
          <div :for={message <- @messages} class={message_class(message.role)}>
            <div class="text-xs uppercase tracking-wide text-gray-400 mb-1">
              {message.role}
            </div>
            <p class="whitespace-pre-wrap leading-relaxed">{message.content}</p>
          </div>
        </div>

        <.form for={%{}} as={:assistant} phx-submit="send" class="mt-4 flex gap-3">
          <input
            type="text"
            name="prompt"
            value={@prompt}
            placeholder="Ask global assistant to summarize system status..."
            class="flex-1 rounded-lg bg-gray-900 border border-gray-800 px-3 py-2 text-sm focus:outline-none focus:border-blue-500"
          />
          <button
            type="submit"
            class="px-4 py-2 text-sm rounded-lg bg-blue-600 hover:bg-blue-700 text-white"
          >
            Send
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp message_class(:assistant), do: "rounded-md bg-gray-800/60 border border-gray-700 p-3"
  defp message_class(:user), do: "rounded-md bg-blue-500/10 border border-blue-700/40 p-3"
end
