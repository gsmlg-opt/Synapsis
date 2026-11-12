defmodule SynapsisWeb.SamgitaLive.Index do
  @moduledoc """
  Samgita connection page: connection settings and generated secrets, events
  received at `/app-server`, and the operator-driven Task attempt flow.
  Network calls to Samgita run in `start_async`, never in the LiveView process.
  """
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  alias Synapsis.SamgitaConfig
  alias Synapsis.Samgita.Inbox
  alias SynapsisSamgita.Events

  @event_limit 100
  @secret_labels %{
    "app_server_token" => "App-server token (Samgita → Synapsis)",
    "agent_credential" => "Agent credential (Synapsis → Samgita)"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe()
      SynapsisSamgita.subscribe()
      SynapsisSamgita.subscribe_attempts()
    end

    {:ok,
     assign(socket,
       page_title: "Samgita",
       revealed: nil,
       marking: nil,
       stepping: nil,
       projects: [],
       busy: false
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> load_config() |> load_events() |> load_connection()}
  end

  @impl true
  def handle_event("save_base_url", %{"base_url" => url}, socket) do
    case SamgitaConfig.put_base_url(url) do
      :ok -> {:noreply, socket |> load_config() |> put_flash(:info, "Samgita URL saved")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Enter an http(s) URL with a host")}
    end
  end

  def handle_event("rotate_secret", %{"kind" => kind}, socket)
      when is_map_key(@secret_labels, kind) do
    {:ok, secret} = SamgitaConfig.rotate_secret(String.to_existing_atom(kind))
    {:noreply, socket |> assign(revealed: %{kind: kind, secret: secret}) |> load_config()}
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, revealed: nil)}

  def handle_event("connect", _params, socket) do
    {:noreply, run(socket, :connect, fn -> SynapsisSamgita.connect() end)}
  end

  def handle_event("refresh_tasks", _params, socket) do
    {:noreply, run(socket, :tasks, &load_tasks/0)}
  end

  def handle_event("open_mark_processed", %{"id" => id}, socket),
    do: {:noreply, socket |> reset_react_form("mark-processed-form") |> assign(marking: id)}

  def handle_event("cancel_mark_processed", _params, socket),
    do: {:noreply, assign(socket, marking: nil)}

  def handle_event("mark_processed", %{"note" => note}, socket) do
    event_id = socket.assigns.marking

    {:noreply,
     socket
     |> assign(marking: nil)
     |> start_async(:mark_processed, fn ->
       SynapsisSamgita.mark_processed(event_id, String.trim(note))
     end)}
  end

  def handle_event("claim", %{"project" => project_id, "task" => task_id}, socket) do
    task =
      Enum.find_value(socket.assigns.projects, fn p ->
        Enum.find(p.tasks, &(&1["id"] == task_id))
      end)

    {:noreply, run(socket, :step, fn -> SynapsisSamgita.claim(project_id, task) end)}
  end

  def handle_event("attempt_start", %{"id" => id}, socket),
    do: {:noreply, run(socket, :step, fn -> SynapsisSamgita.attempt_start(id) end)}

  def handle_event("open_progress", %{"id" => id}, socket),
    do: {:noreply, socket |> reset_react_form("step-form") |> assign(stepping: {:progress, id})}

  def handle_event("open_report", %{"id" => id}, socket),
    do: {:noreply, socket |> reset_react_form("step-form") |> assign(stepping: {:report, id})}

  def handle_event("cancel_step", _params, socket), do: {:noreply, assign(socket, stepping: nil)}

  def handle_event("submit_step", params, socket) do
    fun =
      case socket.assigns.stepping do
        {:progress, id} ->
          summary = String.trim(params["summary"] || "")
          fn -> SynapsisSamgita.attempt_progress(id, summary) end

        {:report, id} ->
          note = String.trim(params["note"] || "")
          result = if note == "", do: nil, else: %{"note" => note}
          effects = params["effects_resolved"] != "false"
          outcome = if params["outcome"] == "failed", do: "failed", else: "succeeded"
          fn -> SynapsisSamgita.attempt_report(id, outcome, effects, result) end
      end

    {:noreply, socket |> assign(stepping: nil) |> run(:step, fun)}
  end

  @impl true
  def handle_async(:mark_processed, {:ok, {:ok, %{reported: true}}}, socket),
    do:
      {:noreply,
       socket |> load_events() |> put_flash(:info, "Marked processed and reported to Samgita")}

  def handle_async(:mark_processed, {:ok, {:ok, %{reported: {:error, code}}}}, socket),
    do:
      {:noreply,
       socket
       |> load_events()
       |> put_flash(:error, "Marked processed locally; not reported to Samgita: #{code}")}

  def handle_async(:mark_processed, {:ok, {:error, _}}, socket),
    do: {:noreply, socket |> load_events() |> put_flash(:error, "Event could not be updated")}

  def handle_async(_name, {:ok, {:error, %{code: code}}}, socket),
    do: {:noreply, socket |> assign(busy: false) |> put_flash(:error, "Samgita: #{code}")}

  def handle_async(:tasks, {:ok, {:ok, projects}}, socket),
    do: {:noreply, assign(socket, busy: false, projects: projects)}

  def handle_async(:connect, {:ok, {:ok, _status}}, socket),
    do: {:noreply, socket |> assign(busy: false) |> run(:tasks, &load_tasks/0)}

  def handle_async(_name, {:ok, _result}, socket),
    do: {:noreply, socket |> assign(busy: false) |> load_connection()}

  def handle_async(_name, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(busy: false) |> put_flash(:error, "Samgita request failed")}

  @impl true
  def handle_info({:samgita_inbox_changed, _id}, socket), do: {:noreply, load_events(socket)}

  def handle_info({:samgita_status, status}, socket),
    do: {:noreply, assign(socket, status: status)}

  def handle_info({:samgita_attempt, view}, socket) do
    {:noreply, assign(socket, attempts: Map.put(socket.assigns.attempts, view.id, view))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp run(socket, name, fun), do: socket |> assign(busy: true) |> start_async(name, fun)

  defp load_tasks do
    with {:ok, projects} <- SynapsisSamgita.list_projects() do
      {:ok,
       Enum.map(projects, fn project ->
         tasks =
           case SynapsisSamgita.list_tasks(project["id"]) do
             {:ok, tasks} -> tasks
             _ -> []
           end

         %{id: project["id"], name: project["name"] || project["id"], tasks: tasks}
       end)}
    end
  end

  defp load_config(socket), do: assign(socket, config: SamgitaConfig.get())
  defp load_events(socket), do: assign(socket, events: Inbox.list(@event_limit))

  defp load_connection(socket) do
    assign(socket,
      status: SynapsisSamgita.status(),
      attempts: Map.new(SynapsisSamgita.list_attempts(), &{&1.id, &1})
    )
  end

  defp event_id(entry), do: entry["event"]["event_id"]

  defp status_variant("completed"), do: "success"
  defp status_variant("succeeded"), do: "success"
  defp status_variant("running"), do: "info"
  defp status_variant(s) when s in ["failed", "rejected", "lost"], do: "error"
  defp status_variant(_), do: "warning"

  defp secret_label(kind), do: Map.fetch!(@secret_labels, kind)

  defp active_attempts?(attempts),
    do: Enum.any?(Map.values(attempts), &(&1.state in ["leased", "running"]))

  defp active_attempt?(attempts, task_id),
    do:
      Enum.any?(
        Map.values(attempts),
        &(&1.task_id == task_id and &1.state in ["leased", "running"])
      )

  @impl true
  def render(assigns) do
    assigns = assign(assigns, secret_kinds: Map.keys(@secret_labels) |> Enum.sort())

    ~H"""
    <div class="max-w-6xl mx-auto p-4 sm:p-6 space-y-6">
      <div class="flex items-center justify-between gap-3">
        <h1 class="text-2xl font-bold">Samgita</h1>
        <.dm_badge variant={if @status.state == :connected, do: "success", else: "warning"} soft>
          {@status.state}
        </.dm_badge>
      </div>

      <.dm_card id="samgita-connection" variant="bordered">
        <:title>Connection</:title>
        <div class="space-y-4">
          <.react_form
            for={%{}}
            id="samgita-url-form"
            values={%{"base_url" => @config.base_url || ""}}
            draft={react_form_draft(assigns, "samgita-url-form")}
            phx-submit="save_base_url"
            class="flex flex-col sm:flex-row gap-2 sm:items-end"
          >
            <div class="flex-1">
              <.dm_input
                id="samgita-base-url"
                type="text"
                name="base_url"
                value={@config.base_url || ""}
                placeholder="http://10.100.10.28:4870"
                label="Samgita URL"
              />
            </div>
            <:actions>
              <.dm_btn type="submit" native_submit variant="primary">Save</.dm_btn>
            </:actions>
          </.react_form>

          <div class="grid gap-3 sm:grid-cols-2">
            <div
              :for={kind <- @secret_kinds}
              class="flex items-center justify-between gap-3 rounded border border-outline-variant p-3"
            >
              <div class="text-sm">
                <div class="font-medium">{secret_label(kind)}</div>
                <div data-role={"#{kind}-status"} class="text-xs text-on-surface-variant">
                  {if Map.fetch!(@config, String.to_existing_atom(kind <> "?")),
                    do: "configured",
                    else: "not set"}
                </div>
              </div>
              <.dm_btn
                variant="ghost"
                size="xs"
                phx-click="rotate_secret"
                phx-value-kind={kind}
                confirm="Generating a new value invalidates the current one in Samgita. Continue?"
                confirm_title="Generate new secret?"
                confirm_text="Generate"
              >
                Generate
              </.dm_btn>
            </div>
          </div>

          <div :if={@revealed} role="status" class="rounded border border-primary p-3 space-y-2">
            <div class="text-sm">
              Copy the {secret_label(@revealed.kind)} into Samgita now. It will not be shown again.
            </div>
            <code data-role="revealed-secret" class="block break-all text-sm">{@revealed.secret}</code>
            <.dm_btn variant="ghost" size="xs" phx-click="dismiss_secret">Done</.dm_btn>
          </div>

          <div class="flex flex-wrap items-center gap-3 text-sm">
            <.dm_btn
              variant="primary"
              size="sm"
              phx-click="connect"
              disabled={@busy or active_attempts?(@attempts)}
            >
              {if @status.state == :connected, do: "Reconnect", else: "Connect"}
            </.dm_btn>
            <span :if={active_attempts?(@attempts)} class="text-xs text-on-surface-variant">
              Finish open attempts before reconnecting.
            </span>
            <span :if={@status.agent_id} class="text-on-surface-variant">
              Agent <code>{@status.agent_id}</code> · connection <code>{@status.connection_id}</code>
            </span>
            <span :if={@status.last_error} class="text-error">{@status.last_error}</span>
          </div>
        </div>
      </.dm_card>

      <.dm_card id="samgita-events" variant="bordered" padding="none">
        <:title><span class="px-4">Events received</span></:title>
        <p :if={@events == []} class="p-4 text-sm text-on-surface-variant">No events received yet.</p>
        <div :if={@events != []} class="overflow-x-auto">
          <table class="table table-compact w-full text-sm">
            <thead>
              <tr>
                <th>Event</th><th>Type</th><th>Project</th><th>Status</th><th>Received</th><th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={entry <- @events} id={"samgita-event-#{event_id(entry)}"}>
                <td class="font-mono text-xs">{event_id(entry)}</td>
                <td>{entry["event"]["type"]}</td>
                <td class="font-mono text-xs">{entry["event"]["project_ref"]}</td>
                <td>
                  <.dm_badge variant={status_variant(entry["processing_status"])} size="xs" soft>
                    {entry["processing_status"]}
                  </.dm_badge>
                  <span class="text-xs text-on-surface-variant ml-1">{entry["acceptance"]}</span>
                  <div :if={entry["note"]} class="text-xs text-on-surface-variant">
                    {entry["note"]}
                  </div>
                </td>
                <td class="text-xs text-on-surface-variant">{entry["received_at"]}</td>
                <td>
                  <.dm_btn
                    :if={entry["processing_status"] == "pending"}
                    variant="ghost"
                    size="xs"
                    phx-click="open_mark_processed"
                    phx-value-id={event_id(entry)}
                  >
                    Mark processed
                  </.dm_btn>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@marking} class="p-4 border-t border-outline-variant">
          <.react_form
            for={%{}}
            id="mark-processed-form"
            values={%{"note" => ""}}
            draft={react_form_draft(assigns, "mark-processed-form")}
            phx-submit="mark_processed"
            class="flex flex-col sm:flex-row gap-2 sm:items-end"
          >
            <div class="flex-1">
              <.dm_input
                id="mark-processed-note"
                type="text"
                name="note"
                value=""
                label={"Note for #{@marking}"}
              />
            </div>
            <:actions>
              <.dm_btn type="submit" native_submit variant="primary" size="sm">
                Mark processed
              </.dm_btn>
              <.dm_btn type="button" variant="ghost" size="sm" phx-click="cancel_mark_processed">
                Cancel
              </.dm_btn>
            </:actions>
          </.react_form>
        </div>
      </.dm_card>

      <.dm_card id="samgita-tasks" variant="bordered">
        <:title>
          <div class="flex items-center justify-between w-full gap-3">
            <span>Assigned tasks</span>
            <.dm_btn
              :if={@status.state == :connected}
              variant="ghost"
              size="xs"
              phx-click="refresh_tasks"
              disabled={@busy}
            >
              Refresh
            </.dm_btn>
          </div>
        </:title>
        <p :if={@status.state != :connected} class="text-sm text-on-surface-variant">
          Not connected. Save the URL and agent credential, then Connect.
        </p>
        <div :if={@status.state == :connected} class="space-y-4">
          <p :if={@projects == []} class="text-sm text-on-surface-variant">No projects loaded.</p>
          <div :for={project <- @projects} class="space-y-2">
            <div class="font-medium text-sm">{project.name}</div>
            <p :if={project.tasks == []} class="text-xs text-on-surface-variant">
              No tasks assigned to this agent.
            </p>
            <div :for={task <- project.tasks} class="flex items-center justify-between gap-3 text-sm">
              <span>{task["title"]}
              <span class="text-xs text-on-surface-variant">({task["state"]})</span></span>
              <.dm_btn
                :if={task["state"] == "open" and not active_attempt?(@attempts, task["id"])}
                variant="ghost"
                size="xs"
                phx-click="claim"
                phx-value-project={project.id}
                phx-value-task={task["id"]}
                disabled={@busy}
              >
                Claim
              </.dm_btn>
            </div>
          </div>
        </div>

        <div :if={map_size(@attempts) > 0} class="mt-4 space-y-2">
          <div class="font-medium text-sm">Attempts</div>
          <div
            :for={attempt <- Map.values(@attempts)}
            id={"samgita-attempt-#{attempt.id}"}
            class="flex flex-wrap items-center gap-2 text-sm rounded border border-outline-variant p-2"
          >
            <code class="text-xs">{attempt.id}</code>
            <.dm_badge variant={status_variant(attempt.state)} size="xs" soft>
              {attempt.state}
            </.dm_badge>
            <span class="text-xs text-on-surface-variant">v{attempt.version} · lease {attempt.lease_expires_at}</span>
            <span :if={attempt.last_error} class="text-xs text-error">{attempt.last_error}</span>
            <div class="ml-auto flex gap-2">
              <.dm_btn
                :if={attempt.state == "leased"}
                variant="ghost"
                size="xs"
                phx-click="attempt_start"
                phx-value-id={attempt.id}
                disabled={@busy}
              >
                Start
              </.dm_btn>
              <.dm_btn
                :if={attempt.state == "running"}
                variant="ghost"
                size="xs"
                phx-click="open_progress"
                phx-value-id={attempt.id}
              >
                Progress
              </.dm_btn>
              <.dm_btn
                :if={attempt.state == "running"}
                variant="ghost"
                size="xs"
                phx-click="open_report"
                phx-value-id={attempt.id}
              >
                Report
              </.dm_btn>
            </div>
          </div>
        </div>

        <div :if={@stepping} class="mt-4 border-t border-outline-variant pt-4">
          <.react_form
            for={%{}}
            id="step-form"
            values={
              %{"summary" => "", "outcome" => "succeeded", "effects_resolved" => "true", "note" => ""}
            }
            draft={react_form_draft(assigns, "step-form")}
            structure={elem(@stepping, 0)}
            phx-submit="submit_step"
            class="space-y-3"
          >
            <.dm_input
              :if={elem(@stepping, 0) == :progress}
              id="step-summary"
              type="text"
              name="summary"
              value=""
              label="Progress summary"
              required
            />
            <.dm_select
              :if={elem(@stepping, 0) == :report}
              id="step-outcome"
              name="outcome"
              value="succeeded"
              label="Outcome"
              options={[{"succeeded", "Succeeded"}, {"failed", "Failed"}]}
            />
            <.dm_select
              :if={elem(@stepping, 0) == :report}
              id="step-effects"
              name="effects_resolved"
              value="true"
              label="Side effects resolved"
              options={[{"true", "Yes — nothing left in flight"}, {"false", "No — hold the task"}]}
            />
            <.dm_input
              :if={elem(@stepping, 0) == :report}
              id="step-note"
              type="text"
              name="note"
              value=""
              label="Result note"
            />
            <:actions>
              <.dm_btn type="submit" native_submit variant="primary" size="sm">
                {if elem(@stepping, 0) == :progress, do: "Send progress", else: "Send report"}
              </.dm_btn>
              <.dm_btn type="button" variant="ghost" size="sm" phx-click="cancel_step">
                Cancel
              </.dm_btn>
            </:actions>
          </.react_form>
        </div>
      </.dm_card>
    </div>
    """
  end
end
