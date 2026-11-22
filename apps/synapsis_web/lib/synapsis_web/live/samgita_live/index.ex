defmodule SynapsisWeb.SamgitaLive.Index do
  @moduledoc """
  Samgita connection page: connection settings and generated secrets, events
  received at `/app-server`, and the operator-driven Task attempt flow.
  Network calls to Samgita run in `start_async`, never in the LiveView process.
  """
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents

  alias Synapsis.SamgitaConfig
  alias Synapsis.Samgita.{Devices, Inbox}
  alias SynapsisSamgita.{Events, Inbound}

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
      Events.subscribe_devices()
    end

    {:ok,
     assign(socket,
       page_title: "Samgita",
       revealed: nil,
       marking: nil,
       stepping: nil,
       projects: [],
       device_id: nil,
       devices: [],
       device_statuses: %{},
       identity_options: [],
       executions: [],
       execution_error: false,
       coordinations: [],
       coordination_error: false,
       busy: false
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> load_config() |> load_devices() |> load_events() |> load_connection()}
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
    {:noreply,
     socket
     |> assign(device_id: nil, projects: [], stepping: nil)
     |> load_connection()
     |> run(:connect, fn -> SynapsisSamgita.connect() end)}
  end

  def handle_event("refresh_tasks", _params, socket) do
    id = socket.assigns.device_id
    {:noreply, run(socket, :tasks, fn -> load_tasks(id) end)}
  end

  def handle_event("refresh_executions", _params, socket),
    do: {:noreply, load_connection(socket)}

  def handle_event("select_identity", %{"identity" => identity}, socket) do
    case String.split(identity, ":", parts: 2) do
      [kind, id] ->
        {:noreply, run(socket, :select_identity, fn -> Inbound.select(kind, id) end)}

      _ ->
        {:noreply, put_flash(socket, :error, "Select an Agent identity")}
    end
  end

  def handle_event("device_action", %{"id" => id, "action" => action}, socket)
      when action in ~w(connect disconnect forget) do
    {:noreply,
     run(socket, {:device_action, id}, fn ->
       case action do
         "connect" -> Inbound.connect(id)
         "disconnect" -> Inbound.disconnect(id)
         "forget" -> Inbound.forget(id)
       end
     end)}
  end

  def handle_event("use_device", params, socket) do
    id = blank_device(params["id"])

    if is_nil(id) or Enum.any?(socket.assigns.devices, &(&1["id"] == id)) do
      socket =
        socket
        |> assign(device_id: id, projects: [], marking: nil, stepping: nil)
        |> load_connection()

      {:noreply, run(socket, :tasks, fn -> load_tasks(id) end)}
    else
      {:noreply, put_flash(socket, :error, "Device identity is unavailable")}
    end
  end

  def handle_event("open_mark_processed", %{"id" => id} = params, socket),
    do:
      {:noreply,
       socket
       |> reset_react_form("mark-processed-form")
       |> assign(marking: %{id: id, device_id: blank_device(params["device"])})}

  def handle_event("cancel_mark_processed", _params, socket),
    do: {:noreply, assign(socket, marking: nil)}

  def handle_event("mark_processed", %{"note" => note}, socket) do
    %{id: event_id, device_id: device_id} = socket.assigns.marking

    {:noreply,
     socket
     |> assign(marking: nil)
     |> start_async(:mark_processed, fn ->
       SynapsisSamgita.mark_processed(event_id, String.trim(note), device_id)
     end)}
  end

  def handle_event("claim", %{"project" => project_id, "task" => task_id}, socket) do
    task =
      Enum.find_value(socket.assigns.projects, fn p ->
        Enum.find(p.tasks, &(&1["id"] == task_id))
      end)

    device_id = socket.assigns.device_id
    {:noreply, run(socket, :step, fn -> SynapsisSamgita.claim(project_id, task, device_id) end)}
  end

  def handle_event("attempt_start", %{"id" => id}, socket) do
    device_id = socket.assigns.device_id
    {:noreply, run(socket, :step, fn -> SynapsisSamgita.attempt_start(id, device_id) end)}
  end

  def handle_event("open_progress", %{"id" => id}, socket),
    do: {:noreply, socket |> reset_react_form("step-form") |> assign(stepping: {:progress, id})}

  def handle_event("open_report", %{"id" => id}, socket),
    do: {:noreply, socket |> reset_react_form("step-form") |> assign(stepping: {:report, id})}

  def handle_event("cancel_step", _params, socket), do: {:noreply, assign(socket, stepping: nil)}

  def handle_event("submit_step", params, socket) do
    device_id = socket.assigns.device_id

    fun =
      case socket.assigns.stepping do
        {:progress, id} ->
          summary = String.trim(params["summary"] || "")
          fn -> SynapsisSamgita.attempt_progress(id, summary, device_id) end

        {:report, id} ->
          note = String.trim(params["note"] || "")
          result = if note == "", do: nil, else: %{"note" => note}
          effects = params["effects_resolved"] != "false"
          outcome = if params["outcome"] == "failed", do: "failed", else: "succeeded"
          fn -> SynapsisSamgita.attempt_report(id, outcome, effects, result, device_id) end
      end

    {:noreply, socket |> assign(stepping: nil) |> run(:step, fun)}
  end

  @impl true
  def handle_async(:select_identity, {:ok, {:ok, _device}}, socket),
    do:
      {:noreply,
       socket
       |> assign(busy: false)
       |> reset_react_form("samgita-identity-form")
       |> load_devices()
       |> put_flash(:info, "Identity saved. Confirm this device in Samgita to connect.")}

  def handle_async({:device_action, _id}, {:ok, {:ok, _}}, socket),
    do: {:noreply, socket |> assign(busy: false) |> load_devices() |> load_connection()}

  def handle_async(_name, {:ok, {:error, reason}}, socket) when is_atom(reason),
    do:
      {:noreply,
       socket
       |> assign(busy: false)
       |> load_devices()
       |> put_flash(:error, "Samgita: #{reason}")}

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
    do: {:noreply, socket |> assign(busy: false) |> run(:tasks, fn -> load_tasks(nil) end)}

  def handle_async(_name, {:ok, _result}, socket),
    do: {:noreply, socket |> assign(busy: false) |> load_connection()}

  def handle_async(_name, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(busy: false) |> put_flash(:error, "Samgita request failed")}

  @impl true
  def handle_info({:samgita_inbox_changed, _id}, socket), do: {:noreply, load_events(socket)}

  def handle_info({:samgita_status, status}, socket) do
    socket = assign(socket, legacy_status: status)

    if is_nil(socket.assigns.device_id),
      do: {:noreply, assign(socket, status: status)},
      else: {:noreply, socket}
  end

  def handle_info({:samgita_device_status, status}, socket) do
    socket = load_devices(socket)

    if socket.assigns.device_id == status.device_id,
      do: {:noreply, load_connection(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:samgita_attempt, view}, socket) do
    socket =
      if is_nil(Map.get(view, :device_id)),
        do:
          assign(socket, legacy_attempts: Map.put(socket.assigns.legacy_attempts, view.id, view)),
        else: socket

    if Map.get(view, :device_id) == socket.assigns.device_id,
      do: {:noreply, assign(socket, attempts: Map.put(socket.assigns.attempts, view.id, view))},
      else: {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp run(socket, name, fun), do: socket |> assign(busy: true) |> start_async(name, fun)

  defp load_tasks(device_id) do
    with {:ok, projects} <- SynapsisSamgita.list_projects(device_id) do
      {:ok,
       Enum.map(projects, fn project ->
         tasks =
           case SynapsisSamgita.list_tasks(project["id"], device_id) do
             {:ok, tasks} -> tasks
             _ -> []
           end

         %{id: project["id"], name: project["name"] || project["id"], tasks: tasks}
       end)}
    end
  end

  defp load_config(socket), do: assign(socket, config: SamgitaConfig.get())

  defp load_events(socket) do
    {coordinations, error} =
      case SynapsisSamgita.Coordinator.list(socket.assigns.device_id) do
        entries when is_list(entries) -> {entries, false}
        {:error, _} -> {[], true}
      end

    assign(socket,
      events: Inbox.list(@event_limit),
      coordinations: coordinations,
      coordination_error: error
    )
  end

  defp load_devices(socket) do
    internal =
      Enum.map(Synapsis.AgentConfigs.list_enabled(), fn agent ->
        {"agent:#{agent.id}", "Synapsis · #{agent.label || agent.name}"}
      end)

    local =
      Synapsis.LocalAgentConfigs.list()
      |> Enum.filter(&(&1.kind in ~w(codex sigma)))
      |> Enum.map(&{"local_agent:#{&1.id}", "#{String.capitalize(&1.kind)} · #{&1.name}"})

    assign(socket,
      devices: Devices.list(),
      device_statuses: Map.new(Inbound.list(), &{&1.device_id, &1}),
      identity_options: [{"", "Select an Agent identity"} | internal ++ local]
    )
  end

  defp load_connection(socket) do
    id = socket.assigns.device_id

    {executions, execution_error} =
      if id do
        case SynapsisSamgita.Execution.list(id) do
          entries when is_list(entries) -> {entries, false}
          {:error, _} -> {[], true}
        end
      else
        {[], false}
      end

    socket = load_events(socket)

    assign(socket,
      executions: executions,
      execution_error: execution_error,
      status: if(id, do: Inbound.status(id), else: SynapsisSamgita.status()),
      legacy_status: SynapsisSamgita.status(),
      legacy_attempts: Map.new(SynapsisSamgita.list_attempts(), &{&1.id, &1}),
      attempts: Map.new(SynapsisSamgita.list_attempts(id), &{&1.id, &1})
    )
  end

  defp event_id(entry), do: entry["event"]["event_id"]

  defp event_row_id(%{"device_id" => id} = entry) when is_binary(id),
    do: "samgita-event-#{id}-#{event_id(entry)}"

  defp event_row_id(entry), do: "samgita-event-#{event_id(entry)}"
  defp blank_device(id) when id in [nil, ""], do: nil
  defp blank_device(id), do: id

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
        <:title>Samgita address</:title>
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

          <details id="samgita-server-mode" class="space-y-4">
            <summary class="cursor-pointer text-sm font-medium">
              Server initiated connections (optional)
            </summary>
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
                disabled={@busy or active_attempts?(@legacy_attempts)}
              >
                {if @legacy_status.state == :connected, do: "Reconnect", else: "Connect"}
              </.dm_btn>
              <span :if={active_attempts?(@legacy_attempts)} class="text-xs text-on-surface-variant">
                Finish open attempts before reconnecting.
              </span>
              <span :if={@legacy_status.agent_id} class="text-on-surface-variant">
                Agent <code>{@legacy_status.agent_id}</code>
                · connection <code>{@legacy_status.connection_id}</code>
              </span>
              <span :if={@legacy_status.last_error} class="text-error">{@legacy_status.last_error}</span>
            </div>
          </details>
        </div>
      </.dm_card>

      <.dm_card id="samgita-devices" variant="bordered">
        <:title>Remembered Agent identities</:title>
        <div class="space-y-4">
          <p class="text-sm text-on-surface-variant">
            Select each Agent to connect to Samgita. Confirm new devices in Samgita;
            each identity keeps its own connection and saved device identity.
          </p>
          <.react_form
            for={%{}}
            id="samgita-identity-form"
            values={%{"identity" => ""}}
            draft={react_form_draft(assigns, "samgita-identity-form")}
            phx-submit="select_identity"
            class="flex flex-col sm:flex-row gap-2 sm:items-end"
          >
            <div class="flex-1">
              <.dm_select
                id="samgita-identity"
                name="identity"
                value=""
                label="Agent identity"
                options={@identity_options}
              />
            </div>
            <:actions>
              <.dm_btn
                type="submit"
                native_submit
                variant="primary"
                disabled={@busy or is_nil(@config.base_url)}
              >
                Connect identity
              </.dm_btn>
            </:actions>
          </.react_form>
          <p :if={@devices == []} class="text-sm text-on-surface-variant">
            No remembered identities.
          </p>
          <div
            :for={device <- @devices}
            id={"samgita-device-#{device["id"]}"}
            class="rounded border border-outline-variant p-3 space-y-2"
          >
            <div class="flex flex-wrap items-center gap-2 text-sm">
              <span class="font-medium">{device["name"]}</span>
              <span class="text-on-surface-variant">{device["implementation"]}</span>
              <.dm_badge size="xs" soft>{Map.fetch!(@device_statuses, device["id"]).state}</.dm_badge>
              <span :if={device["agent_id"]} class="font-mono text-xs">{device["agent_id"]}</span>
              <span :if={Map.fetch!(@device_statuses, device["id"]).last_error} class="text-error">
                {Map.fetch!(@device_statuses, device["id"]).last_error}
              </span>
            </div>
            <div class="flex flex-wrap gap-2">
              <.dm_btn
                :if={!device["forgotten"]}
                variant="ghost"
                size="xs"
                phx-click="use_device"
                phx-value-id={device["id"]}
                disabled={@busy}
              >
                {if @device_id == device["id"], do: "Viewing tasks", else: "View tasks"}
              </.dm_btn>
              <.dm_btn
                :if={!device["forgotten"] and !device["enabled"]}
                variant="ghost"
                size="xs"
                phx-click="device_action"
                phx-value-action="connect"
                phx-value-id={device["id"]}
                disabled={@busy}
              >
                Reconnect
              </.dm_btn>
              <.dm_btn
                :if={device["enabled"]}
                variant="ghost"
                size="xs"
                phx-click="device_action"
                phx-value-action="disconnect"
                phx-value-id={device["id"]}
                disabled={@busy}
              >
                Disconnect
              </.dm_btn>
              <.dm_btn
                :if={!device["forgotten"]}
                variant="ghost"
                size="xs"
                phx-click="device_action"
                phx-value-action="forget"
                phx-value-id={device["id"]}
                disabled={@busy}
              >
                Forget device
              </.dm_btn>
            </div>
          </div>
          <.dm_btn
            :if={@device_id}
            variant="ghost"
            size="xs"
            phx-click="use_device"
            phx-value-id=""
            disabled={@busy}
          >
            View server connection tasks
          </.dm_btn>
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
              <tr :for={entry <- @events} id={event_row_id(entry)}>
                <td class="font-mono text-xs">
                  {event_id(entry)}
                  <div :if={entry["device_id"]} class="text-on-surface-variant">
                    {entry["device_id"]}
                  </div>
                </td>
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
                    phx-value-device={entry["device_id"] || ""}
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
                label={"Note for #{@marking.id}"}
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

      <.dm_card id="samgita-coordination" variant="bordered">
        <:title>Project coordination · human review</:title>
        <p :if={@coordination_error} role="status" class="text-sm text-error">
          Coordination records are unavailable.
        </p>
        <p :if={!@coordination_error and @coordinations == []} class="text-sm text-on-surface-variant">
          No manual project requests coordinated for this identity.
        </p>
        <div
          :for={coordination <- @coordinations}
          class="space-y-2 py-2 text-sm"
          data-coordination-event={coordination["event_id"]}
        >
          <div class="flex flex-wrap items-center gap-2">
            <code>{coordination["project_id"]}</code>
            <.dm_badge size="xs" soft>{coordination["phase"]}</.dm_badge>
            <span class="text-xs text-on-surface-variant">Manager device: {coordination["device_id"]}</span>
          </div>
          <p :if={coordination["last_error"]} class="text-error">{coordination["last_error"]}</p>
          <p
            :if={coordination["phase"] == "recovery_required"}
            class="text-xs text-on-surface-variant"
          >
            Interrupted or uncertain work needs reconciliation; no task tree is replayed.
          </p>
          <div
            :for={{_key, child} <- Enum.sort(coordination["children"])}
            class="rounded border border-outline-variant p-2"
            data-coordination-task={child["task_id"]}
          >
            <p>{child["title"]} · <code>{child["task_id"]}</code></p>
            <p class="text-xs">
              Assignee: {child["assignee_agent_id"]} · Task: {child["task_state"]}
            </p>
            <p :if={child["attempt_id"]} class="text-xs">
              Attempt: {child["attempt_id"]} · {child["attempt_state"]}
            </p>
            <p :if={child["task_state"] == "awaiting_review"} class="text-xs text-on-surface-variant">
              Execution submitted. Human review and acceptance are still required.
            </p>
            <p :if={child["result"]} class="whitespace-pre-wrap">{child["result"]["summary"]}</p>
            <code
              :if={child["result"] && child["result"]["runtime"]}
              class="block text-xs whitespace-pre-wrap"
            >{JSON.encode!(child["result"]["runtime"])}</code>
            <div :for={artifact <- child["artifact_references"] || []} class="text-xs break-all">
              {artifact["kind"]}: {artifact["locator"]}
              <span :if={artifact["digest"]}> · {artifact["digest"]}</span>
            </div>
            <p
              :if={child["evidence_scope"] == "event_and_task_state_only"}
              class="text-xs text-on-surface-variant"
            >
              Only event and Task state are visible; no execution report or artifact is available on this host.
            </p>
          </div>
        </div>
      </.dm_card>

      <.dm_card id="samgita-tasks" variant="bordered">
        <:title>
          <div class="flex items-center justify-between w-full gap-3">
            <span>Assigned tasks {if @device_id,
              do: "· #{Enum.find_value(@devices, &if(&1["id"] == @device_id, do: &1["name"]))}"}</span>
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
          Not connected. Connect the selected identity or the server connection to view tasks.
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
            <span
              :if={attempt.state == "leased" && attempt.start_deadline}
              data-role="start-deadline"
              class="text-xs text-warning"
            >
              start by {attempt.start_deadline}
            </span>
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

        <div :if={@device_id} id="samgita-executions" class="mt-4 space-y-2">
          <div class="flex items-center justify-between gap-3">
            <span class="font-medium text-sm">Assigned Task executions</span>
            <.dm_btn variant="ghost" size="xs" phx-click="refresh_executions">
              Refresh execution state
            </.dm_btn>
          </div>
          <p :if={@execution_error} role="status" class="text-sm text-error">
            Execution records are unavailable.
          </p>
          <p :if={!@execution_error and @executions == []} class="text-sm text-on-surface-variant">
            No execution records for this identity.
          </p>
          <div
            :for={execution <- @executions}
            class="rounded border border-outline-variant p-2 text-sm"
            data-task-id={execution["task_id"]}
          >
            <code class="text-xs">{execution["task_id"]}</code>
            <.dm_badge size="xs" soft>{execution["phase"]}</.dm_badge>
            <span :if={execution["last_error"]} class="text-error">{execution["last_error"]}</span>
            <p :if={execution["phase"] == "recovery_required"} class="text-xs text-on-surface-variant">
              Outcome needs reconciliation. This execution will not restart automatically.
            </p>
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
