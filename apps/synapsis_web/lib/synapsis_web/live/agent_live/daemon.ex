defmodule SynapsisWeb.AgentLive.Daemon do
  @moduledoc "Dense operational console for the agent daemon and its durable work."
  use SynapsisWeb, :live_view

  import SynapsisWeb.AgentLive.Components

  alias Synapsis.Agent.{Daemon, Routines, Runs}
  alias Synapsis.Backplane

  @topic "agent:daemon"
  @refresh_events [
    "agent.daemon.status",
    "agent.run.queued",
    "agent.run.started",
    "agent.run.completed",
    "agent.run.failed",
    "agent.run.cancelled",
    "agent.run.interrupted",
    "agent.routine.triggered",
    "agent.routine.updated",
    "backplane.sync.started",
    "backplane.sync.completed",
    "backplane.sync.failed",
    "backplane.capabilities.updated"
  ]
  @default_status %{
    ready: false,
    active_run: nil,
    queued_count: 0,
    last_seen_at: nil,
    last_error: nil
  }
  @secret_assignment ~r/(?i)\b(api[_-]?key|access[_-]?token|authorization|password|credential|secret)\b(\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)/u
  @bearer_token ~r/(?i)\bbearer\s+[^\s,;]+/u

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Synapsis.PubSub, @topic)

    {:ok,
     socket
     |> assign(
       page_title: "Agent Daemon",
       operation: nil,
       manual_form: to_form(%{"prompt" => ""}, as: :manual),
       routine_form: new_routine_form(),
       connection_form: new_connection_form()
     )
     |> refresh()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.agent_shell active={:daemon}>
      <div id="agent-daemon-console" class="mx-auto flex max-w-7xl flex-col gap-4">
        <header class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-xs font-semibold uppercase tracking-widest text-primary">Operations</p>
            <h1 class="text-2xl font-bold text-on-surface">Agent Daemon</h1>
            <p class="text-sm text-on-surface-variant">
              Runtime health, durable work, routines, and capability sources.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.dm_badge
              id="daemon-process-state"
              variant={if(@daemon_running?, do: "success", else: "error")}
              size="sm"
              soft
            >
              {if(@daemon_running?, do: "Running", else: "Unavailable")}
            </.dm_badge>
            <.dm_badge id="daemon-readiness" variant={readiness_variant(@daemon_status)} size="sm">
              {readiness_label(@daemon_status)}
            </.dm_badge>
          </div>
        </header>

        <div
          :if={@operation}
          id="daemon-operation-state"
          role="status"
          aria-live="polite"
          class="flex items-center gap-2 rounded-md border border-primary/30 bg-primary-container px-3 py-2 text-sm text-on-primary-container"
        >
          <.dm_loading_spinner size="xs" />
          <span>{@operation.label}</span>
        </div>

        <section aria-label="Daemon status" class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <.dm_card variant="bordered" class="bg-surface-container">
            <p class="text-xs uppercase tracking-wide text-on-surface-variant">Active run</p>
            <div id="active-run" class="mt-2 min-h-10">
              <%= if active = @daemon_status[:active_run] do %>
                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p class="font-mono text-sm font-semibold text-on-surface">{active[:id]}</p>
                    <p class="text-xs text-on-surface-variant">
                      {active[:kind]} · {active[:phase] || active[:status]}
                    </p>
                  </div>
                  <.dm_btn
                    phx-click="cancel_run"
                    phx-value-id={active[:id]}
                    variant="error"
                    size="xs"
                    loading={operation?(@operation, {:cancel_run, active[:id]})}
                    disabled={operation_busy?(@operation)}
                  >
                    Cancel
                  </.dm_btn>
                </div>
              <% else %>
                <p class="text-sm text-on-surface-variant">Idle</p>
              <% end %>
            </div>
          </.dm_card>

          <.dm_card variant="bordered" class="bg-surface-container">
            <p class="text-xs uppercase tracking-wide text-on-surface-variant">Queue</p>
            <p id="daemon-queue-count" class="mt-2 text-2xl font-bold text-on-surface">
              {@daemon_status[:queued_count] || 0}
            </p>
            <p class="text-xs text-on-surface-variant">waiting runs</p>
          </.dm_card>

          <.dm_card variant="bordered" class="bg-surface-container">
            <p class="text-xs uppercase tracking-wide text-on-surface-variant">Last heartbeat</p>
            <p class="mt-2 text-sm font-semibold text-on-surface">
              {format_time(@daemon_status[:last_seen_at])}
            </p>
            <p class="text-xs text-on-surface-variant">daemon liveness</p>
          </.dm_card>
        </section>

        <section
          id="daemon-capability-counts"
          aria-label="Imported Backplane capabilities"
          class="grid grid-cols-2 gap-3 lg:grid-cols-4"
        >
          <.dm_card variant="bordered" class="bg-surface-container" padding="sm">
            <p class="text-xs uppercase tracking-wide text-on-surface-variant">
              Imported providers
            </p>
            <p id="daemon-provider-count" class="mt-1 text-xl font-bold text-on-surface">
              {@capability_counts.providers}
            </p>
          </.dm_card>
          <.dm_card variant="bordered" class="bg-surface-container" padding="sm">
            <p class="text-xs uppercase tracking-wide text-on-surface-variant">Imported models</p>
            <p id="daemon-model-count" class="mt-1 text-xl font-bold text-on-surface">
              {@capability_counts.models}
            </p>
          </.dm_card>
          <.dm_card variant="bordered" class="bg-surface-container" padding="sm">
            <p class="text-xs uppercase tracking-wide text-on-surface-variant">Imported skills</p>
            <p id="daemon-skill-count" class="mt-1 text-xl font-bold text-on-surface">
              {@capability_counts.skills}
            </p>
          </.dm_card>
          <.dm_card variant="bordered" class="bg-surface-container" padding="sm">
            <p class="text-xs uppercase tracking-wide text-on-surface-variant">
              Imported MCP servers
            </p>
            <p id="daemon-mcp-count" class="mt-1 text-xl font-bold text-on-surface">
              {@capability_counts.mcp}
            </p>
          </.dm_card>
        </section>

        <section aria-label="Routine recency" class="grid grid-cols-1 gap-3 lg:grid-cols-3">
          <.dm_card id="last-heartbeat" variant="bordered" class="bg-surface-container">
            <:title><span class="text-sm font-semibold">Last heartbeat</span></:title>
            <.run_glance run={@last_heartbeat} empty="No heartbeat runs" />
          </.dm_card>

          <.dm_card id="last-dream" variant="bordered" class="bg-surface-container">
            <:title><span class="text-sm font-semibold">Last dream</span></:title>
            <.run_glance run={@last_dream} empty="No dream runs" />
          </.dm_card>

          <.dm_card id="recent-failures" variant="bordered" class="bg-surface-container">
            <:title><span class="text-sm font-semibold">Recent failures</span></:title>
            <p :if={@failures == []} class="text-sm text-on-surface-variant">No recent failures</p>
            <ul :if={@failures != []} class="space-y-2">
              <li :for={run <- @failures} class="border-l-2 border-error pl-2">
                <p class="text-xs font-semibold text-on-surface">{field(run, :kind)}</p>
                <p class="text-xs text-error">{bounded(sanitize_error(field(run, :error)), 120)}</p>
              </li>
            </ul>
          </.dm_card>
        </section>

        <.dm_card id="manual-run" variant="bordered" class="bg-surface-container-high" shadow="sm">
          <:title><span class="text-sm font-semibold">Manual run</span></:title>
          <.dm_form for={@manual_form} id="manual-run-form" phx-submit="submit_manual">
            <.dm_textarea
              field={@manual_form[:prompt]}
              label="Prompt"
              placeholder="Describe the bounded task for the daemon"
              rows={3}
              maxlength={4_000}
              required
            />
            <:actions>
              <span class="text-xs text-on-surface-variant">Queued behind active work</span>
              <.dm_btn
                type="submit"
                variant="primary"
                size="sm"
                loading={operation?(@operation, :submit_manual)}
                disabled={operation_busy?(@operation)}
              >
                Queue run
              </.dm_btn>
            </:actions>
          </.dm_form>
        </.dm_card>

        <.dm_card id="daemon-runs" variant="bordered" class="bg-surface-container" padding="none">
          <:title><span class="text-sm font-semibold">Recent runs</span></:title>
          <p :if={@runs == []} class="p-4 text-sm text-on-surface-variant">No durable runs yet.</p>
          <div :if={@runs != []} class="overflow-x-auto">
            <.dm_table data={@runs} compact zebra hover>
              <:col :let={run} label="Run" class="font-mono text-xs">
                {bounded(field(run, :id), 16)}
              </:col>
              <:col :let={run} label="Kind / status">
                <div class="flex flex-col items-start gap-1">
                  <span class="text-xs text-on-surface">{field(run, :kind)}</span>
                  <.dm_badge variant={status_variant(field(run, :status))} size="xs" soft>
                    {field(run, :status)}
                  </.dm_badge>
                </div>
              </:col>
              <:col :let={run} label="Prompt" class="min-w-56 text-xs">
                {bounded(field(run, :prompt), 120)}
              </:col>
              <:col :let={run} label="Times" class="min-w-44 text-xs text-on-surface-variant">
                <p>{format_time(field(run, :started_at) || field(run, :inserted_at))}</p>
                <p>{format_time(field(run, :finished_at))}</p>
              </:col>
              <:col :let={run} label="Result / error" class="min-w-52 text-xs">
                <span class={field(run, :error) && "text-error"}>{run_result(run)}</span>
              </:col>
            </.dm_table>
          </div>
        </.dm_card>

        <.dm_card id="daemon-routines" variant="bordered" class="bg-surface-container" padding="none">
          <:title>
            <div class="flex items-center justify-between gap-3">
              <span class="text-sm font-semibold">Routines</span>
              <.dm_badge variant="secondary" size="xs" soft>{length(@routines)} configured</.dm_badge>
            </div>
          </:title>
          <div class="grid grid-cols-1 xl:grid-cols-[minmax(0,1fr)_20rem]">
            <div class="grid grid-cols-1 gap-px bg-outline-variant lg:grid-cols-2 xl:border-r xl:border-outline-variant">
              <p
                :if={@routines == []}
                class="bg-surface-container p-4 text-sm text-on-surface-variant"
              >
                No routines configured.
              </p>
              <article
                :for={routine <- @routines}
                id={"routine-#{field(routine, :id)}"}
                class="flex min-w-0 flex-col gap-3 bg-surface-container p-4"
              >
                <div class="flex flex-wrap items-start justify-between gap-2">
                  <div class="min-w-0">
                    <p class="truncate text-sm font-semibold text-on-surface">
                      {field(routine, :name)}
                    </p>
                    <p class="font-mono text-xs text-on-surface-variant">
                      {field(routine, :schedule)}
                    </p>
                  </div>
                  <div class="flex items-center gap-1">
                    <.dm_badge variant="secondary" size="xs" soft>{field(routine, :kind)}</.dm_badge>
                    <.dm_badge
                      variant={if(field(routine, :enabled), do: "success", else: "warning")}
                      size="xs"
                      soft
                    >
                      {if(field(routine, :enabled), do: "Enabled", else: "Disabled")}
                    </.dm_badge>
                  </div>
                </div>

                <dl class="grid grid-cols-1 gap-2 text-xs sm:grid-cols-3">
                  <div>
                    <dt class="text-on-surface-variant">Toolset</dt>
                    <dd class="font-medium text-on-surface">{routine_toolset(routine)}</dd>
                  </div>
                  <div>
                    <dt class="text-on-surface-variant">Last</dt>
                    <dd class="font-medium text-on-surface">
                      {format_time(field(routine, :last_run_at))}
                    </dd>
                  </div>
                  <div>
                    <dt class="text-on-surface-variant">Next</dt>
                    <dd class="font-medium text-on-surface">
                      {format_time(field(routine, :next_run_at))}
                    </dd>
                  </div>
                </dl>

                <div class="mt-auto flex flex-wrap items-center justify-between gap-2">
                  <.dm_badge
                    :if={field(routine, :last_status)}
                    variant={status_variant(field(routine, :last_status))}
                    size="xs"
                    soft
                  >
                    {field(routine, :last_status)}
                  </.dm_badge>
                  <div class="ml-auto flex gap-2">
                    <.dm_btn
                      phx-click="trigger_routine"
                      phx-value-id={field(routine, :id)}
                      variant="primary"
                      size="xs"
                      loading={operation?(@operation, {:trigger_routine, field(routine, :id)})}
                      disabled={!field(routine, :enabled) || operation_busy?(@operation)}
                    >
                      Run now
                    </.dm_btn>
                    <.dm_btn
                      phx-click="set_routine_enabled"
                      phx-value-id={field(routine, :id)}
                      phx-value-enabled={if(field(routine, :enabled), do: "false", else: "true")}
                      variant={if(field(routine, :enabled), do: "error", else: "secondary")}
                      size="xs"
                      loading={operation?(@operation, {:set_routine_enabled, field(routine, :id)})}
                      disabled={operation_busy?(@operation)}
                    >
                      {if(field(routine, :enabled), do: "Disable", else: "Enable")}
                    </.dm_btn>
                  </div>
                </div>
              </article>
            </div>

            <div class="bg-surface-container-high p-4">
              <h3 class="mb-3 text-sm font-semibold text-on-surface">Create routine</h3>
              <.dm_form for={@routine_form} id="routine-create-form" phx-submit="create_routine">
                <.dm_input
                  field={@routine_form[:name]}
                  type="text"
                  label="Name"
                  maxlength={255}
                  required
                />
                <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-1">
                  <.dm_select
                    field={@routine_form[:kind]}
                    label="Kind"
                    options={[
                      {"schedule", "Schedule"},
                      {"heartbeat", "Heartbeat"},
                      {"dream", "Dream"}
                    ]}
                  />
                  <.dm_input
                    field={@routine_form[:schedule]}
                    type="text"
                    label="Schedule (UTC cron)"
                    maxlength={255}
                    required
                  />
                </div>
                <.dm_select
                  field={@routine_form[:tool_profile]}
                  label="Toolset"
                  options={[
                    {"assistant_basic", "Basic"},
                    {"assistant_workspace", "Workspace"},
                    {"assistant_coding", "Coding"},
                    {"assistant_dream", "Dream"}
                  ]}
                />
                <.dm_textarea
                  field={@routine_form[:prompt]}
                  label="Prompt"
                  rows={4}
                  maxlength={4_000}
                  required
                />
                <input type="hidden" name="routine[enabled]" value="false" />
                <.dm_checkbox field={@routine_form[:enabled]} value="true" label="Enabled" />
                <:actions>
                  <.dm_btn
                    type="submit"
                    variant="primary"
                    size="sm"
                    loading={operation?(@operation, :create_routine)}
                    disabled={operation_busy?(@operation)}
                  >
                    Create routine
                  </.dm_btn>
                </:actions>
              </.dm_form>
            </div>
          </div>
        </.dm_card>

        <.dm_card
          id="backplane-connections"
          variant="bordered"
          class="bg-surface-container"
          padding="none"
        >
          <:title>
            <div class="flex items-center justify-between gap-3">
              <span class="text-sm font-semibold">Backplane connections</span>
              <.dm_badge variant="secondary" size="xs" soft>{length(@connections)} sources</.dm_badge>
            </div>
          </:title>
          <p :if={@connections == []} class="p-4 text-sm text-on-surface-variant">
            No Backplane connections configured.
          </p>
          <div
            :if={@connections != []}
            class="grid grid-cols-1 gap-px bg-outline-variant xl:grid-cols-2"
          >
            <article
              :for={connection <- @connections}
              id={"connection-#{field(connection, :id)}"}
              class="flex min-w-0 flex-col gap-3 bg-surface-container p-4"
            >
              <div class="flex flex-wrap items-start justify-between gap-2">
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-on-surface">
                    {field(connection, :name)}
                  </p>
                  <p class="truncate font-mono text-xs text-on-surface-variant">
                    {field(connection, :endpoint) || field(connection, :base_url)}
                  </p>
                </div>
                <div class="flex items-center gap-1">
                  <.dm_badge variant={status_variant(field(connection, :status))} size="xs" soft>
                    {field(connection, :status)}
                  </.dm_badge>
                  <.dm_badge :if={field(connection, :stale)} variant="warning" size="xs" soft>
                    Stale
                  </.dm_badge>
                </div>
              </div>

              <dl class="grid grid-cols-2 gap-x-4 gap-y-2 text-xs sm:grid-cols-4">
                <div>
                  <dt class="text-on-surface-variant">Models</dt>
                  <dd class="font-semibold text-on-surface">
                    {imported_count(connection, "models")} models
                  </dd>
                </div>
                <div>
                  <dt class="text-on-surface-variant">Skills</dt>
                  <dd class="font-semibold text-on-surface">
                    {imported_count(connection, "skills")} skills
                  </dd>
                </div>
                <div>
                  <dt class="text-on-surface-variant">Tools</dt>
                  <dd class="font-semibold text-on-surface">
                    {imported_count(connection, "tools")} tools
                  </dd>
                </div>
                <div>
                  <dt class="text-on-surface-variant">Last sync</dt>
                  <dd class="font-medium text-on-surface">
                    {format_time(field(connection, :last_synced_at))}
                  </dd>
                </div>
              </dl>

              <p
                :if={field(connection, :last_error)}
                class="rounded bg-error-container px-2 py-1 text-xs text-on-error-container"
              >
                {connection_error(connection)}
              </p>

              <div class="flex flex-wrap justify-end gap-2">
                <.dm_btn
                  phx-click="test_connection"
                  phx-value-id={field(connection, :id)}
                  variant="secondary"
                  size="xs"
                  loading={operation?(@operation, {:test_connection, field(connection, :id)})}
                  disabled={operation_busy?(@operation)}
                >
                  Test
                </.dm_btn>
                <.dm_btn
                  phx-click="refresh_connection"
                  phx-value-id={field(connection, :id)}
                  variant="secondary"
                  size="xs"
                  loading={operation?(@operation, {:refresh_connection, field(connection, :id)})}
                  disabled={!field(connection, :enabled) || operation_busy?(@operation)}
                >
                  Refresh
                </.dm_btn>
                <.dm_btn
                  phx-click="set_connection_enabled"
                  phx-value-id={field(connection, :id)}
                  phx-value-enabled={if(field(connection, :enabled), do: "false", else: "true")}
                  variant={if(field(connection, :enabled), do: "error", else: "primary")}
                  size="xs"
                  loading={operation?(@operation, {:set_connection_enabled, field(connection, :id)})}
                  disabled={operation_busy?(@operation)}
                >
                  {if(field(connection, :enabled), do: "Disable", else: "Enable")}
                </.dm_btn>
              </div>
            </article>
          </div>

          <section
            id="backplane-create"
            class="border-t border-outline-variant bg-surface-container-high p-4"
          >
            <h3 class="mb-3 text-sm font-semibold text-on-surface">Add capability source</h3>
            <.dm_form
              for={@connection_form}
              id="backplane-create-form"
              phx-submit="create_connection"
            >
              <div class="grid grid-cols-1 gap-3 lg:grid-cols-3">
                <.dm_input
                  field={@connection_form[:name]}
                  type="text"
                  label="Name"
                  placeholder="production"
                  maxlength={255}
                  required
                />
                <.dm_input
                  field={@connection_form[:endpoint]}
                  type="url"
                  label="Endpoint"
                  placeholder="https://backplane.example"
                  maxlength={2_048}
                  required
                />
                <.dm_input
                  field={@connection_form[:credential]}
                  type="password"
                  label="Credential (optional)"
                  autocomplete="new-password"
                  maxlength={4_096}
                />
              </div>
              <div class="flex flex-wrap gap-4">
                <input type="hidden" name="connection[enabled]" value="false" />
                <.dm_checkbox field={@connection_form[:enabled]} value="true" label="Enabled" />
                <input type="hidden" name="connection[sync_on_start]" value="false" />
                <.dm_checkbox
                  field={@connection_form[:sync_on_start]}
                  value="true"
                  label="Sync on start"
                />
              </div>
              <:actions>
                <span class="text-xs text-on-surface-variant">
                  Credentials are encrypted and never displayed.
                </span>
                <.dm_btn
                  type="submit"
                  variant="primary"
                  size="sm"
                  loading={operation?(@operation, :create_connection)}
                  disabled={operation_busy?(@operation)}
                >
                  Add connection
                </.dm_btn>
              </:actions>
            </.dm_form>
          </section>
        </.dm_card>
      </div>
    </.agent_shell>
    """
  end

  @impl true
  def handle_event("submit_manual", %{"manual" => %{"prompt" => prompt}}, socket) do
    prompt = String.trim(prompt)

    cond do
      prompt == "" ->
        {:noreply, put_flash(socket, :error, "A prompt is required")}

      String.length(prompt) > 4_000 ->
        {:noreply, put_flash(socket, :error, "Prompt is limited to 4,000 characters")}

      true ->
        start_operation(
          socket,
          %{
            key: :submit_manual,
            label: "Queueing run",
            success: "Run queued",
            failure: "Unable to queue the run",
            reset: :manual_form
          },
          fn -> dependency(:daemon, Daemon).submit(prompt, %{source: "web"}) end
        )
    end
  end

  def handle_event("cancel_run", %{"id" => run_id}, socket) do
    start_operation(
      socket,
      %{
        key: {:cancel_run, run_id},
        label: "Cancelling run",
        success: "Cancellation requested",
        failure: "Unable to cancel the run"
      },
      fn -> dependency(:daemon, Daemon).cancel(run_id) end
    )
  end

  def handle_event("create_connection", %{"connection" => params}, socket)
      when is_map(params) do
    attrs = connection_attrs(params)

    if attrs.name == "" or attrs.endpoint == "" do
      {:noreply, put_flash(socket, :error, "Name and endpoint are required")}
    else
      start_operation(
        socket,
        %{
          key: :create_connection,
          label: "Creating connection",
          success: "Connection created",
          failure: "Unable to create the connection",
          reset: :connection_form
        },
        fn -> dependency(:backplane, Backplane).create(attrs) end
      )
    end
  end

  def handle_event("test_connection", %{"id" => connection_id}, socket) do
    connection_action(
      socket,
      {:test_connection, connection_id},
      "Testing connection",
      fn -> dependency(:backplane, Backplane).test(connection_id) end,
      "Connection test passed"
    )
  end

  def handle_event("refresh_connection", %{"id" => connection_id}, socket) do
    connection_action(
      socket,
      {:refresh_connection, connection_id},
      "Refreshing connection",
      fn -> dependency(:backplane, Backplane).refresh(connection_id) end,
      "Connection refreshed"
    )
  end

  def handle_event(
        "set_connection_enabled",
        %{"id" => connection_id, "enabled" => enabled},
        socket
      )
      when enabled in ["true", "false"] do
    enabled? = enabled == "true"

    connection_action(
      socket,
      {:set_connection_enabled, connection_id},
      if(enabled?, do: "Enabling connection", else: "Disabling connection"),
      fn -> dependency(:backplane, Backplane).update(connection_id, %{enabled: enabled?}) end,
      if(enabled?, do: "Connection enabled", else: "Connection disabled")
    )
  end

  def handle_event("create_routine", %{"routine" => params}, socket) when is_map(params) do
    attrs = %{
      "name" => params |> Map.get("name", "") |> String.trim(),
      "kind" => Map.get(params, "kind", "schedule"),
      "schedule" => params |> Map.get("schedule", "") |> String.trim(),
      "tool_profile" => Map.get(params, "tool_profile", "assistant_basic"),
      "prompt" => params |> Map.get("prompt", "") |> String.trim(),
      "enabled" => Map.get(params, "enabled") == "true"
    }

    start_operation(
      socket,
      %{
        key: :create_routine,
        label: "Creating routine",
        success: "Routine created",
        failure: "Unable to create the routine",
        reset: :routine_form
      },
      fn -> dependency(:routines, Routines).create(attrs) end
    )
  end

  def handle_event("set_routine_enabled", %{"id" => routine_id, "enabled" => enabled}, socket)
      when enabled in ["true", "false"] do
    routine_action(
      socket,
      {:set_routine_enabled, routine_id},
      if(enabled == "true", do: "Enabling routine", else: "Disabling routine"),
      fn ->
        dependency(:routines, Routines).update(routine_id, %{"enabled" => enabled == "true"})
      end,
      if(enabled == "true", do: "Routine enabled", else: "Routine disabled")
    )
  end

  def handle_event("trigger_routine", %{"id" => routine_id}, socket) do
    routine_action(
      socket,
      {:trigger_routine, routine_id},
      "Queueing routine",
      fn -> dependency(:routines, Routines).trigger(routine_id) end,
      "Routine queued"
    )
  end

  @impl true
  def handle_info({:agent_daemon_event, %{event: event}}, socket) when event in @refresh_events do
    {:noreply, refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:daemon_operation, {:ok, result}, socket) do
    {:noreply, finish_operation(socket, result)}
  end

  def handle_async(:daemon_operation, {:exit, _reason}, socket) do
    {:noreply, fail_operation(socket)}
  end

  attr :run, :any, required: true
  attr :empty, :string, required: true

  defp run_glance(assigns) do
    ~H"""
    <%= if @run do %>
      <p class="text-sm font-medium text-on-surface">{bounded(field(@run, :prompt), 120)}</p>
      <div class="mt-2 flex items-center justify-between gap-2">
        <.dm_badge variant={status_variant(field(@run, :status))} size="xs" soft>
          {field(@run, :status)}
        </.dm_badge>
        <span class="text-xs text-on-surface-variant">
          {format_time(field(@run, :finished_at) || field(@run, :inserted_at))}
        </span>
      </div>
    <% else %>
      <p class="text-sm text-on-surface-variant">{@empty}</p>
    <% end %>
    """
  end

  defp refresh(socket) do
    {daemon_running?, status} = daemon_status()

    runs =
      safe_value(fn -> dependency(:runs, Runs).list_recent(limit: 25) end, [])
      |> safe_runs()

    routines = safe_value(fn -> dependency(:routines, Routines).list(nil) end, [])

    source_connections = safe_value(fn -> dependency(:backplane, Backplane).list() end, [])
    connections = safe_connections(source_connections)

    assign(socket,
      daemon_status: status,
      daemon_running?: daemon_running?,
      runs: runs,
      routines: routines,
      connections: connections,
      capability_counts: imported_capability_counts(source_connections),
      last_heartbeat: Enum.find(runs, &(field(&1, :kind) == "heartbeat")),
      last_dream: Enum.find(runs, &(field(&1, :kind) == "dream")),
      failures: runs |> Enum.filter(&(field(&1, :status) == "failed")) |> Enum.take(3)
    )
  end

  defp daemon_status do
    case safe_call(fn -> dependency(:daemon, Daemon).status() end) do
      {:ok, status} when is_map(status) -> {true, status}
      _error -> {false, @default_status}
    end
  end

  defp imported_capability_counts(connections) when is_list(connections) do
    %{
      providers: artifact_id_count(connections, "provider_id"),
      models: imported_surface_count(connections, "models"),
      skills: imported_surface_count(connections, "skills"),
      mcp: artifact_id_count(connections, "mcp_id")
    }
  end

  defp imported_capability_counts(_connections) do
    %{providers: 0, models: 0, skills: 0, mcp: 0}
  end

  defp artifact_id_count(connections, key) do
    connections
    |> Enum.map(&artifact_id(&1, key))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp artifact_id(connection, "provider_id"),
    do: connection |> field(:artifacts) |> field(:provider_id)

  defp artifact_id(connection, "mcp_id"),
    do: connection |> field(:artifacts) |> field(:mcp_id)

  defp imported_surface_count(connections, surface) do
    Enum.reduce(connections, 0, fn connection, total ->
      case imported_count(connection, surface) do
        count when is_integer(count) and count >= 0 -> total + count
        _invalid -> total
      end
    end)
  end

  defp connection_action(socket, key, label, action, success_message) do
    start_operation(
      socket,
      %{key: key, label: label, success: success_message, failure: "Backplane operation failed"},
      action
    )
  end

  defp routine_action(socket, key, label, action, success_message) do
    start_operation(
      socket,
      %{key: key, label: label, success: success_message, failure: "Routine operation failed"},
      action
    )
  end

  defp start_operation(%{assigns: %{operation: nil}} = socket, operation, action) do
    {:noreply,
     socket
     |> assign(operation: operation)
     |> start_async(:daemon_operation, fn -> safe_action(action) end)}
  end

  defp start_operation(socket, _operation, _action), do: {:noreply, socket}

  defp finish_operation(socket, :ok), do: complete_operation(socket)
  defp finish_operation(socket, {:ok, _result}), do: complete_operation(socket)
  defp finish_operation(socket, _result), do: fail_operation(socket)

  defp complete_operation(socket) do
    operation = socket.assigns.operation

    socket
    |> assign(operation: nil)
    |> reset_operation_form(operation[:reset])
    |> refresh()
    |> put_flash(:info, operation.success)
  end

  defp fail_operation(%{assigns: %{operation: operation}} = socket) when is_map(operation) do
    socket
    |> assign(operation: nil)
    |> put_flash(:error, operation.failure)
  end

  defp fail_operation(socket), do: assign(socket, operation: nil)

  defp reset_operation_form(socket, :manual_form),
    do: assign(socket, manual_form: to_form(%{"prompt" => ""}, as: :manual))

  defp reset_operation_form(socket, :routine_form),
    do: assign(socket, routine_form: new_routine_form())

  defp reset_operation_form(socket, :connection_form),
    do: assign(socket, connection_form: new_connection_form())

  defp reset_operation_form(socket, _reset), do: socket

  defp operation?(%{key: key}, key), do: true
  defp operation?(_operation, _key), do: false

  defp operation_busy?(operation), do: not is_nil(operation)

  defp dependency(key, default) do
    :synapsis_web
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp safe_value(fun, fallback) do
    fun.()
  rescue
    _error -> fallback
  catch
    :exit, _reason -> fallback
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_action(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp readiness_label(%{ready: true}), do: "Ready"
  defp readiness_label(_status), do: "Recovering"
  defp readiness_variant(%{ready: true}), do: "success"
  defp readiness_variant(_status), do: "warning"

  defp status_variant("completed"), do: "success"
  defp status_variant(status) when status in ["ok", "ready"], do: "success"
  defp status_variant(status) when status in ["error", "failed"], do: "error"

  defp status_variant(status) when status in ["cancelled", "interrupted", "degraded"],
    do: "warning"

  defp status_variant(status) when status in ["running", "waiting_approval", "syncing"],
    do: "primary"

  defp status_variant(_status), do: "secondary"

  defp field(record, key) when is_map(record),
    do: Map.get(record, key, Map.get(record, Atom.to_string(key)))

  defp field(_record, _key), do: nil

  defp run_result(run) do
    result = field(run, :summary) || sanitize_error(field(run, :error)) || "Pending"
    bounded(result, 160)
  end

  defp imported_count(connection, surface) do
    counts = field(connection, :counts) || %{}

    Enum.find_value(counts, 0, fn {key, value} ->
      if to_string(key) == surface, do: value
    end)
  end

  defp connection_error(connection) do
    bounded(sanitize_error(field(connection, :last_error)), 200)
  end

  defp safe_runs(runs) when is_list(runs), do: Enum.map(runs, &safe_run/1)
  defp safe_runs(_runs), do: []

  defp safe_run(run) do
    %{
      id: field(run, :id),
      kind: field(run, :kind),
      status: field(run, :status),
      prompt: field(run, :prompt),
      summary: field(run, :summary),
      error: sanitize_error(field(run, :error)),
      inserted_at: field(run, :inserted_at),
      started_at: field(run, :started_at),
      finished_at: field(run, :finished_at)
    }
  end

  defp safe_connections(connections) when is_list(connections),
    do: Enum.map(connections, &safe_connection/1)

  defp safe_connections(_connections), do: []

  defp safe_connection(connection) do
    credential = field(connection, :credential)

    %{
      id: field(connection, :id),
      name: field(connection, :name),
      endpoint: field(connection, :endpoint),
      base_url: field(connection, :base_url),
      enabled: field(connection, :enabled),
      status: field(connection, :status),
      stale: field(connection, :stale),
      last_synced_at: field(connection, :last_synced_at),
      last_error:
        connection
        |> field(:last_error)
        |> redact_value(credential)
        |> sanitize_error(),
      counts: %{
        "models" => imported_count(connection, "models"),
        "skills" => imported_count(connection, "skills"),
        "tools" => imported_count(connection, "tools")
      }
    }
  end

  defp sanitize_error(nil), do: nil

  defp sanitize_error(value) do
    value
    |> safe_text()
    |> String.replace(@bearer_token, "Bearer [REDACTED]")
    |> String.replace(@secret_assignment, "\\1\\2[REDACTED]")
  end

  defp redact_value(value, credential)
       when is_binary(value) and is_binary(credential) and credential != "",
       do: String.replace(value, credential, "[REDACTED]")

  defp redact_value(value, _credential), do: value

  defp safe_text(value) when is_binary(value) do
    if String.valid?(value), do: value, else: "[invalid text]"
  end

  defp safe_text(value), do: inspect(value, limit: 20, printable_limit: 200)

  defp routine_toolset(routine) do
    field(routine, :toolset) || field(routine, :toolset_id) || field(routine, :tool_profile) ||
      "default"
  end

  defp new_routine_form do
    to_form(
      %{
        "name" => "",
        "kind" => "schedule",
        "schedule" => "0 * * * *",
        "tool_profile" => "assistant_basic",
        "prompt" => "",
        "enabled" => true
      },
      as: :routine
    )
  end

  defp new_connection_form do
    to_form(
      %{
        "name" => "",
        "endpoint" => "",
        "credential" => "",
        "enabled" => true,
        "sync_on_start" => true
      },
      as: :connection
    )
  end

  defp connection_attrs(params) do
    attrs = %{
      name: params |> Map.get("name", "") |> String.trim(),
      endpoint: params |> Map.get("endpoint", "") |> String.trim(),
      enabled: Map.get(params, "enabled") == "true",
      sync_on_start: Map.get(params, "sync_on_start") == "true"
    }

    case Map.get(params, "credential") do
      credential when is_binary(credential) and credential != "" ->
        Map.put(attrs, :credential, credential)

      _blank ->
        attrs
    end
  end

  defp bounded(nil, _limit), do: "—"
  defp bounded(value, limit), do: value |> to_string() |> String.slice(0, limit)

  defp format_time(%DateTime{} = time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M:%S UTC")

  defp format_time(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _offset} -> format_time(datetime)
      {:error, _reason} -> bounded(time, 30)
    end
  end

  defp format_time(_time), do: "Never"
end
