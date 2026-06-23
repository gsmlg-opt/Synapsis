defmodule SynapsisWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the Synapsis web interface.

  Most components come from `phoenix_duskmoon` via `use PhoenixDuskmoon.Component`.
  This module holds app-specific components only.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  import SynapsisWeb.MessageHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: SynapsisServer.Endpoint,
    router: SynapsisServer.Router,
    statics: SynapsisWeb.static_paths()

  @doc """
  Dashboard statistic card with icon, value, and label.
  """
  attr :icon, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :color, :string, default: "primary"
  attr :to, :string, default: nil
  attr :class, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <.dm_card variant="bordered" class={@class}>
      <div class="flex items-center gap-4">
        <div class={"text-#{@color}"}>
          <.dm_mdi name={@icon} class="w-8 h-8" />
        </div>
        <div>
          <div class={"text-2xl font-bold text-#{@color}"}>{@value}</div>
          <div class="text-sm text-on-surface-variant">{@label}</div>
        </div>
      </div>
    </.dm_card>
    """
  end

  @doc """
  Empty state placeholder with icon, message, and optional CTA.
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :string, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class={["text-center py-12", @class]}>
      <.dm_mdi name={@icon} class="w-12 h-12 text-on-surface-variant/50 mx-auto mb-3" />
      <h3 class="text-lg font-medium text-on-surface-variant">{@title}</h3>
      <p :if={@description} class="text-sm text-on-surface-variant mt-1">{@description}</p>
      <div :if={@action != []} class="mt-4">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  Chat message bubble — right-aligned for user, left-aligned for assistant/system.
  """
  attr :role, :string, required: true, values: ~w(user assistant system)
  attr :label, :string, default: nil
  attr :avatar, :string, default: nil
  attr :time, :string, default: nil
  attr :status, :string, default: nil
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def chat_bubble(assigns) do
    assigns =
      assigns
      |> assign(:align, if(assigns.role == "user", do: "end", else: "start"))
      |> assign(:color, if(assigns.role == "user", do: "primary", else: nil))
      |> assign(:variant, if(assigns.role == "user", do: "filled", else: "tonal"))
      |> assign(:author, chat_author(assigns.role, assigns.label))
      |> assign(:display_avatar, chat_avatar(assigns.role, assigns.avatar, assigns.label))

    ~H"""
    <.dm_chat
      align={@align}
      color={@color}
      variant={@variant}
      size="sm"
      author={@author}
      avatar={@display_avatar}
      time={@time}
      status={@status}
      class={@class}
    >
      {render_slot(@inner_block)}
    </.dm_chat>
    """
  end

  defp chat_author("user", _label), do: "You"
  defp chat_author("assistant", label) when label not in [nil, ""], do: label
  defp chat_author("assistant", _label), do: "Assistant"
  defp chat_author("system", _label), do: "System"

  defp chat_avatar(_role, avatar, _label) when avatar not in [nil, ""], do: avatar
  defp chat_avatar("user", _avatar, _label), do: "U"
  defp chat_avatar("assistant", _avatar, nil), do: "AI"
  defp chat_avatar("assistant", _avatar, ""), do: "AI"
  defp chat_avatar("assistant", _avatar, label), do: initials(label, "AI")
  defp chat_avatar("system", _avatar, _label), do: "S"

  defp initials(value, fallback) when is_binary(value) do
    initials =
      value
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.first/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(2)
      |> Enum.join()

    if initials == "", do: fallback, else: String.upcase(initials)
  end

  defp initials(_value, fallback), do: fallback

  @doc """
  Compaction marker — visual indicator that messages were compacted/summarized.
  Shows a collapsible summary of the compacted content.
  """
  attr :count, :integer, required: true
  attr :summary, :string, required: true
  attr :class, :string, default: nil

  def compaction_marker(assigns) do
    ~H"""
    <div class={["flex justify-center my-3", @class]}>
      <details class="group w-full max-w-[90%]">
        <summary class="flex items-center gap-2 cursor-pointer text-xs text-on-surface-variant hover:text-on-surface-variant py-2">
          <div class="flex-1 border-t border-outline-variant" />
          <.dm_mdi name="archive-outline" class="w-4 h-4 shrink-0" />
          <span class="shrink-0">{@count} messages compacted</span>
          <.dm_mdi
            name="chevron-down"
            class="w-3.5 h-3.5 transition-transform group-open:rotate-180 shrink-0"
          />
          <div class="flex-1 border-t border-outline-variant" />
        </summary>
        <div class="mt-2 mx-4 p-3 rounded-lg bg-surface-container text-xs text-on-surface-variant max-h-48 overflow-y-auto whitespace-pre-wrap">
          {@summary}
        </div>
      </details>
    </div>
    """
  end

  @doc """
  Heartbeat notification card — displayed when a heartbeat runs and produces results.
  """
  attr :name, :string, required: true
  attr :timestamp, :string, default: nil
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def heartbeat_card(assigns) do
    ~H"""
    <div class={["flex justify-start", @class]}>
      <div class="rounded-lg px-3 py-2 max-w-[80%] text-sm bg-secondary/10 border border-secondary/20">
        <div class="flex items-center gap-2 mb-1 text-xs text-secondary">
          <.dm_mdi name="heart-pulse" class="w-3.5 h-3.5" />
          <span class="font-medium">{@name}</span>
          <span :if={@timestamp} class="text-on-surface-variant">{@timestamp}</span>
        </div>
        <div class="text-on-surface whitespace-pre-wrap">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Embedded Code Agent panel — shown inline in chat when an agent spawns a sub-agent.
  Displays task description, live tool calls, and completion summary.
  """
  attr :prompt, :string, required: true
  attr :status, :string, default: "running", values: ~w(running complete error)
  attr :tool_calls, :list, default: []
  attr :completion, :string, default: nil
  attr :class, :string, default: nil

  def code_agent_panel(assigns) do
    ~H"""
    <details
      class={["border border-primary/20 rounded-lg overflow-hidden text-sm", @class]}
      open={@status == "running"}
    >
      <summary class="bg-surface-container px-3 py-2 flex items-center gap-2 cursor-pointer select-none list-none">
        <.dm_mdi name="robot-outline" class="w-4 h-4 text-primary shrink-0" />
        <span class="font-medium text-xs text-primary">Code Agent</span>
        <span class="flex-1 text-xs text-on-surface-variant italic truncate pl-1" title={@prompt}>
          {String.slice(@prompt, 0, 60)}{if String.length(@prompt) > 60, do: "…", else: ""}
        </span>
        <span :if={@status == "running"} class="text-xs text-on-surface-variant animate-pulse">
          Running…
        </span>
        <.dm_badge :if={@status == "complete"} variant="success" size="sm">done</.dm_badge>
        <.dm_badge :if={@status == "error"} variant="error" size="sm">failed</.dm_badge>
      </summary>
      <div class="p-3 space-y-2">
        <details :if={@tool_calls != []}>
          <summary class="text-xs cursor-pointer text-on-surface-variant hover:text-on-surface-variant select-none">
            {length(@tool_calls)} tool call{if length(@tool_calls) != 1, do: "s", else: ""}
          </summary>
          <div class="mt-2 space-y-1">
            <div :for={tc <- @tool_calls}>
              <.tool_call_display name={tc.name} status={tc.status} />
            </div>
          </div>
        </details>
        <div
          :if={@completion}
          class="text-xs text-on-surface border-t border-outline-variant pt-2 whitespace-pre-wrap"
        >
          {@completion}
        </div>
      </div>
    </details>
    """
  end

  @doc """
  Memory indicator — shows when context was recalled from a previous session or workspace.
  """
  attr :source, :string, default: "previous session"
  attr :class, :string, default: nil

  def memory_indicator(assigns) do
    ~H"""
    <div class={["flex items-center gap-1.5 text-xs text-info/70 py-1", @class]}>
      <.dm_mdi name="brain" class="w-3.5 h-3.5" />
      <span class="italic">Recalled from {@source}</span>
    </div>
    """
  end

  @doc """
  Tool invocation display with status indicator.
  """
  attr :name, :string, required: true
  attr :status, :string, required: true, values: ~w(pending running complete error)
  attr :class, :string, default: nil

  slot :params
  slot :result

  def tool_call_display(assigns) do
    ~H"""
    <.dm_chat_tool
      name={@name}
      status={chat_tool_status(@status)}
      open={@status in ~w(running error)}
      class={@class}
    >
      <:name_slot>
        <span class="inline-flex items-center gap-2">
          <.dm_mdi name="wrench" class="h-4 w-4 text-on-surface-variant" />
          <span class="font-medium">{@name}</span>
        </span>
      </:name_slot>
      <:call :if={@params != []}>
        <div class="text-xs text-on-surface-variant">
          {render_slot(@params)}
        </div>
      </:call>
      <:result :if={@result != []}>
        <div class="text-xs">
          {render_slot(@result)}
        </div>
      </:result>
    </.dm_chat_tool>
    """
  end

  defp chat_tool_status("complete"), do: "success"
  defp chat_tool_status("completed"), do: "success"
  defp chat_tool_status(status) when status in ~w(pending running success error), do: status
  defp chat_tool_status(_), do: "pending"

  @doc """
  Read-only form field with label and value display.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :monospace, :boolean, default: false
  attr :class, :string, default: nil

  def readonly_field(assigns) do
    ~H"""
    <div class={@class}>
      <.dm_label>{@label}</.dm_label>
      <div class={[
        "bg-surface-container-high text-on-surface-variant rounded px-3 py-2 border border-outline-variant",
        if(@monospace, do: "font-mono text-sm whitespace-pre-wrap")
      ]}>
        {@value}
      </div>
    </div>
    """
  end

  @doc """
  Toggle button group for mode selection.
  """
  attr :current_mode, :string, required: true
  attr :modes, :list, required: true
  attr :on_change, :string, required: true
  attr :class, :string, default: nil

  def mode_toggle(assigns) do
    ~H"""
    <div class={["flex gap-0 bg-surface-container-high rounded-lg p-0.5", @class]}>
      <.dm_btn
        :for={{value, label} <- @modes}
        variant={if(@current_mode == value, do: "primary", else: "ghost")}
        size="sm"
        phx-click={@on_change}
        phx-value-mode={value}
      >
        {label}
      </.dm_btn>
    </div>
    """
  end

  @doc """
  Shared layout for settings pages with consistent left navigation.
  """
  attr :current_path, :string, required: true
  attr :content_class, :string, default: "max-w-5xl"
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def settings_layout(assigns) do
    ~H"""
    <div class={["flex min-h-full", @class]} data-testid="settings-layout">
      <.settings_sidebar current_path={@current_path} />
      <main class="flex-1 min-w-0 p-6">
        <div class={["mx-auto", @content_class]}>
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end

  @doc """
  Settings navigation sidebar with active state.
  """
  attr :current_path, :string, required: true
  attr :class, :string, default: nil

  def settings_sidebar(assigns) do
    items = [
      %{to: ~p"/settings", icon: "view-dashboard-outline", label: "Overview"},
      %{to: ~p"/settings/providers", icon: "cloud", label: "Providers"},
      %{to: ~p"/settings/models", icon: "tune", label: "Default Model"},
      %{to: ~p"/settings/memory", icon: "brain", label: "Memory"},
      %{to: ~p"/settings/mcp", icon: "server-network", label: "MCP Servers"}
    ]

    assigns =
      assigns
      |> assign(:items, items)
      |> assign(:active_path, active_menu_id(assigns.current_path, items))

    ~H"""
    <aside
      class={[
        "hidden w-64 shrink-0 border-r border-outline-variant bg-secondary px-5 py-6 text-secondary-content md:block",
        @class
      ]}
      data-testid="settings-sidebar"
      aria-label="Settings navigation"
    >
      <.dm_left_menu active={@active_path} size="lg" class="app-left-menu">
        <:title>Settings</:title>
        <:menu :for={item <- @items}>
          <.dm_link
            navigate={item.to}
            aria-current={if(@active_path == item.to, do: "page")}
            class={settings_sidebar_item_class(@active_path == item.to)}
          >
            <.dm_mdi name={item.icon} class="w-5 h-5 shrink-0" /> {item.label}
          </.dm_link>
        </:menu>
      </.dm_left_menu>
    </aside>
    """
  end

  @doc """
  Bottom status bar with 4-mode selector and session status indicator.

  Modes: bypass_permissions, ask_before_edits, edit_automatically, plan_mode.
  """
  attr :current_mode, :string, required: true
  attr :session_status, :string, default: "idle"
  attr :on_mode_change, :string, required: true
  attr :has_session, :boolean, default: true
  attr :context_label, :string, default: nil
  attr :model_label, :string, default: nil
  attr :class, :string, default: nil

  @session_modes [
    {"bypass_permissions", "Bypass", "shield-off-outline"},
    {"ask_before_edits", "Ask", "shield-check-outline"},
    {"edit_automatically", "Auto-edit", "pencil-outline"},
    {"plan_mode", "Plan", "file-document-outline"}
  ]

  def session_status_bar(assigns) do
    assigns = assign(assigns, :modes, @session_modes)

    ~H"""
    <div class={[
      "flex items-center justify-between bg-surface-container border-t border-outline-variant px-3 py-1",
      @class
    ]}>
      <div :if={@has_session} class="flex gap-0 bg-surface-container-high rounded-lg p-0.5">
        <.dm_btn
          :for={{value, label, icon} <- @modes}
          variant={if(@current_mode == value, do: "primary", else: "ghost")}
          size="xs"
          phx-click={@on_mode_change}
          phx-value-mode={value}
        >
          <.dm_mdi name={icon} class="w-3.5 h-3.5" />
          <span class="hidden sm:inline">{label}</span>
        </.dm_btn>
      </div>
      <div :if={!@has_session} class="text-xs text-on-surface-variant">
        No active session
      </div>
      <div
        data-session-status-meta
        class="flex min-w-0 items-center gap-3 text-xs text-on-surface-variant"
      >
        <span
          :if={@context_label not in [nil, ""]}
          data-session-context-size
          class="hidden font-mono tabular-nums sm:inline"
        >
          Context: {@context_label}
        </span>
        <span
          :if={@model_label not in [nil, ""]}
          data-session-model
          class="hidden max-w-48 truncate font-mono sm:inline"
          title={@model_label}
        >
          Model: {@model_label}
        </span>
        <span class={[
          "inline-block w-2 h-2 rounded-full",
          status_dot_color(@session_status)
        ]}>
        </span>
        {@session_status}
      </div>
    </div>
    """
  end

  defp status_dot_color("idle"), do: "bg-primary"
  defp status_dot_color("streaming"), do: "bg-info animate-pulse"
  defp status_dot_color("tool_executing"), do: "bg-warning animate-pulse"
  defp status_dot_color("error"), do: "bg-error"
  defp status_dot_color(_), do: "bg-on-surface/30"

  @doc """
  Breadcrumb navigation with proper link support.

  Custom breadcrumb navigation with proper link support.
  """
  attr :class, :string, default: nil

  slot :crumb, required: true do
    attr :to, :string
  end

  def breadcrumb(assigns) do
    ~H"""
    <nav aria-label="Breadcrumb" class={["text-sm", @class]}>
      <ol class="flex items-center gap-1 text-on-surface-variant">
        <li :for={{crumb, idx} <- Enum.with_index(@crumb)} class="flex items-center gap-1">
          <.dm_mdi :if={idx > 0} name="chevron-right" class="w-4 h-4 text-on-surface-variant/50" />
          <.dm_link
            :if={crumb[:to]}
            navigate={crumb.to}
            class="hover:text-on-surface transition-colors"
          >
            {render_slot(crumb)}
          </.dm_link>
          <span :if={!crumb[:to]} class="text-on-surface">
            {render_slot(crumb)}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  Global status bar shown at the bottom of every page.

  Displays system status indicator and links to settings/agents.
  """
  def global_status_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between bg-surface-container border-t border-outline-variant px-3 py-1 shrink-0">
      <div class="flex items-center gap-3">
        <.dm_link
          navigate={~p"/agent/agents"}
          class="flex items-center gap-1.5 text-xs text-on-surface-variant hover:text-on-surface transition-colors"
        >
          <.dm_mdi name="robot-outline" class="w-3.5 h-3.5" />
          <span class="hidden sm:inline">Agents</span>
        </.dm_link>
        <.dm_link
          navigate={~p"/workspace"}
          class="flex items-center gap-1.5 text-xs text-on-surface-variant hover:text-on-surface transition-colors"
        >
          <.dm_mdi name="file-tree-outline" class="w-3.5 h-3.5" />
          <span class="hidden sm:inline">Workspace</span>
        </.dm_link>
      </div>
      <div class="flex items-center gap-3">
        <div class="flex items-center gap-1.5 text-xs text-on-surface-variant">
          <span class="inline-block w-2 h-2 rounded-full bg-primary"></span>
          <span class="hidden sm:inline">Ready</span>
        </div>
        <.dm_link
          navigate={~p"/settings"}
          class="flex items-center gap-1 text-xs text-on-surface-variant hover:text-on-surface transition-colors"
        >
          <.dm_mdi name="cog-outline" class="w-3.5 h-3.5" />
          <span class="hidden sm:inline">Settings</span>
        </.dm_link>
      </div>
    </div>
    """
  end

  defp settings_sidebar_item_class(true) do
    [
      "app-left-menu-item",
      "app-left-menu-item-active"
    ]
  end

  defp settings_sidebar_item_class(false) do
    "app-left-menu-item"
  end

  defp active_menu_id(current_path, items) do
    items
    |> Enum.map(& &1.to)
    |> Enum.filter(&settings_path_active?(current_path, &1))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp settings_path_active?(current_path, "/settings"), do: current_path == "/settings"

  defp settings_path_active?(current_path, path) do
    current_path == path or String.starts_with?(current_path, path <> "/")
  end

  @doc """
  Renders a message's parts, dispatching to the appropriate sub-component per part type.
  """
  attr :message, :map, required: true
  attr :assistant_label, :string, default: nil
  attr :assistant_avatar, :string, default: nil
  attr :can_regenerate, :boolean, default: false
  attr :class, :string, default: nil

  def message_parts(assigns) do
    assigns =
      assigns
      |> assign(:message_label, message_label(assigns.message, assigns.assistant_label))
      |> assign(:message_avatar, message_avatar(assigns.message, assigns.assistant_avatar))
      |> assign(:message_time, message_time(assigns.message))
      |> assign(:message_status, message_status(assigns.message))

    ~H"""
    <div :for={part <- @message.parts || []} class={@class}>
      <%= case part do %>
        <% %Synapsis.Part.Text{content: content} -> %>
          <%= cond do %>
            <% @message.role == "system" and compaction_summary?(content) -> %>
              <% {count, summary} = parse_compaction(content) %>
              <.compaction_marker count={count} summary={summary} />
            <% @message.role == "system" and memory_recall?(content) -> %>
              <.memory_indicator source={detect_memory_source(content)} />
              <.chat_bubble role="system" time={@message_time} status={@message_status}>
                <.dm_markdown content={content} theme="auto" />
              </.chat_bubble>
            <% true -> %>
              <.chat_bubble
                role={@message.role}
                label={@message_label}
                avatar={@message_avatar}
                time={@message_time}
                status={@message_status}
              >
                <.dm_markdown content={content} theme="auto" />
              </.chat_bubble>
          <% end %>
        <% %Synapsis.Part.Reasoning{content: content} -> %>
          <.reasoning_block content={content} />
        <% %Synapsis.Part.ToolUse{tool: tool, tool_use_id: _id, input: input, status: status} -> %>
          <.tool_call_display name={tool} status={to_string(status)}>
            <:params>
              <pre class="max-h-32 overflow-y-auto">{Jason.encode!(input || %{}, pretty: true)}</pre>
            </:params>
          </.tool_call_display>
        <% %Synapsis.Part.ToolResult{content: content, is_error: is_error} -> %>
          <div class={[
            "text-xs border rounded-lg p-2 max-h-64 overflow-y-auto",
            if(is_error,
              do: "border-error/30 bg-error/5",
              else: "border-outline-variant bg-surface-container"
            )
          ]}>
            <pre class="whitespace-pre-wrap">{content}</pre>
          </div>
        <% %Synapsis.Part.File{path: path, content: content} -> %>
          <div class="border border-outline-variant rounded-lg p-2 text-xs">
            <div class="flex items-center gap-1 mb-1 text-on-surface-variant">
              <.dm_mdi name="file-document-outline" class="w-3.5 h-3.5" />
              <span class="font-mono">{path}</span>
            </div>
            <pre class="whitespace-pre-wrap max-h-64 overflow-y-auto">{content}</pre>
          </div>
        <% _ -> %>
          <div></div>
      <% end %>
    </div>

    <div
      :if={@message.role == "assistant" and @can_regenerate}
      class="flex justify-start pl-1 -mt-2"
    >
      <.dm_btn
        variant="ghost"
        size="xs"
        phx-click="regenerate"
        phx-value-id={@message.id}
        class="gap-1 text-on-surface-variant/60 hover:text-on-surface-variant"
      >
        <.dm_mdi name="refresh" class="w-3.5 h-3.5" /> Regenerate
      </.dm_btn>
    </div>
    """
  end

  defp message_label(%{role: "assistant"}, assistant_label), do: assistant_label
  defp message_label(_message, _assistant_label), do: nil

  defp message_avatar(%{role: "assistant"}, assistant_avatar), do: assistant_avatar
  defp message_avatar(_message, _assistant_avatar), do: nil

  defp message_time(%{inserted_at: %DateTime{} = inserted_at}) do
    Calendar.strftime(inserted_at, "%H:%M:%S")
  end

  defp message_time(%{inserted_at: %NaiveDateTime{} = inserted_at}) do
    Calendar.strftime(inserted_at, "%H:%M:%S")
  end

  defp message_time(_message), do: nil

  defp message_status(%{role: "user", token_count: count}) when is_integer(count) and count > 0 do
    "in: #{count}"
  end

  defp message_status(%{role: "assistant", token_count: count})
       when is_integer(count) and count > 0 do
    "out: #{count}"
  end

  defp message_status(%{token_count: count}) when is_integer(count) and count > 0 do
    "#{count} tokens"
  end

  defp message_status(_message), do: nil

  @doc """
  Collapsible reasoning/thinking trace block.
  """
  attr :content, :string, required: true
  attr :collapsed, :boolean, default: true
  attr :class, :string, default: nil

  def reasoning_block(assigns) do
    ~H"""
    <.dm_chat_reasoning summary="Thinking" open={!@collapsed} class={@class}>
      <:summary_slot>
        <span class="inline-flex items-center gap-2 text-xs text-on-surface-variant">
          <.dm_mdi name="thought-bubble-outline" class="h-4 w-4" /> Thinking
        </span>
      </:summary_slot>
      <div class="max-h-48 overflow-y-auto whitespace-pre-wrap text-xs leading-relaxed text-on-surface-variant">
        {@content}
      </div>
    </.dm_chat_reasoning>
    """
  end

  @doc """
  Inline permission approval card for tool use requests.
  """
  attr :tool, :string, required: true
  attr :tool_use_id, :string, required: true
  attr :input, :map, default: %{}
  attr :level, :string, default: "write"
  attr :class, :string, default: nil

  def permission_card(assigns) do
    ~H"""
    <.dm_card variant="bordered" class={["border-warning/50", @class]}>
      <div class="flex items-start gap-3">
        <.dm_mdi name="shield-alert-outline" class="w-5 h-5 text-warning shrink-0 mt-0.5" />
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-1">
            <span class="font-medium text-sm">{@tool}</span>
            <.dm_badge variant="warning" size="sm">{@level}</.dm_badge>
          </div>
          <pre class="text-xs text-on-surface-variant max-h-24 overflow-y-auto mb-2">{Jason.encode!(@input || %{}, pretty: true)}</pre>
          <div class="flex gap-2">
            <.dm_btn
              variant="primary"
              size="xs"
              phx-click="approve_tool"
              phx-value-tool-use-id={@tool_use_id}
            >
              Approve
            </.dm_btn>
            <.dm_btn
              variant="ghost"
              size="xs"
              phx-click="deny_tool"
              phx-value-tool-use-id={@tool_use_id}
            >
              Deny
            </.dm_btn>
          </div>
        </div>
      </div>
    </.dm_card>
    """
  end

  @doc """
  Pulsing streaming indicator shown while the assistant is generating.
  """
  attr :class, :string, default: nil

  def streaming_indicator(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 text-xs text-on-surface-variant", @class]}>
      <.dm_chat_typing />
      <span>Generating...</span>
    </div>
    """
  end

  @doc """
  Prominent agent working indicator shown above the chat input area.

  Displays animated bouncing dots, "Agent is working..." text,
  and a Stop button to cancel the current operation.
  """
  attr :status, :string, required: true
  attr :on_cancel, :string, default: "cancel_stream"
  attr :class, :string, default: nil

  def agent_working_indicator(assigns) do
    ~H"""
    <div class={[
      "flex items-center justify-between px-4 py-2 border-b border-outline-variant bg-surface-container",
      @class
    ]}>
      <div class="flex items-center gap-2.5">
        <span class="inline-flex items-center gap-1" aria-hidden="true">
          <span class="agent-dot agent-dot-1 inline-block w-2 h-2 rounded-full bg-primary"></span>
          <span class="agent-dot agent-dot-2 inline-block w-2 h-2 rounded-full bg-primary"></span>
          <span class="agent-dot agent-dot-3 inline-block w-2 h-2 rounded-full bg-primary"></span>
        </span>
        <span class="text-sm text-on-surface-variant font-medium">
          <%= if @status == "tool_executing" do %>
            Agent is executing tools…
          <% else %>
            Agent is working…
          <% end %>
        </span>
      </div>
      <.dm_btn
        variant="ghost"
        size="xs"
        phx-click={@on_cancel}
        class="text-error hover:bg-error/10"
      >
        <.dm_mdi name="stop" class="w-4 h-4" />
        <span>Stop</span>
      </.dm_btn>
    </div>
    """
  end

  @doc """
  Session list sidebar item with title, agent, status dot, and delete button.
  """
  attr :session, :map, required: true
  attr :active, :boolean, default: false
  attr :class, :string, default: nil

  def session_list_item(assigns) do
    ~H"""
    <div
      data-session-row={@session.id}
      aria-current={if @active, do: "page", else: nil}
      class={[
        "group flex items-center gap-3 rounded-md border px-3 py-2.5 cursor-pointer transition-colors text-sm",
        if(@active,
          do: "border-primary/30 bg-primary-container text-on-primary-container shadow-sm",
          else:
            "border-transparent text-on-surface hover:border-outline-variant hover:bg-surface-container-high"
        ),
        @class
      ]}
    >
      <button
        type="button"
        phx-click="switch_session"
        phx-value-id={@session.id}
        class="flex min-w-0 flex-1 items-center gap-3 border-0 bg-transparent p-0 text-left text-inherit"
      >
        <span class={[
          "inline-block w-2 h-2 rounded-full shrink-0",
          status_dot_color(@session.status || "idle")
        ]}>
        </span>
        <div class="min-w-0 flex-1">
          <div class="truncate font-medium">
            {@session.title || "Session #{String.slice(@session.id || "", 0..7)}"}
          </div>
          <div class={[
            "text-xs truncate",
            if(@active, do: "text-on-primary-container/70", else: "text-on-surface-variant")
          ]}>
            {session_agent_label(@session)}
          </div>
        </div>
      </button>
      <button
        type="button"
        phx-click="confirm_delete_session"
        phx-value-id={@session.id}
        aria-label={"Delete #{session_title(@session)}"}
        class={[
          "inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border-0 bg-transparent p-0 text-inherit opacity-0 transition-opacity",
          "hover:bg-surface-container-high focus:opacity-100 focus:outline-none focus:ring-2 focus:ring-primary/60",
          "group-hover:opacity-100 group-focus-within:opacity-100"
        ]}
      >
        <.dm_mdi name="delete-outline" class="w-3.5 h-3.5" />
      </button>
    </div>
    """
  end

  defp session_title(%{title: title}) when is_binary(title) and title != "", do: title

  defp session_title(%{id: id}) when is_binary(id) do
    "Session #{String.slice(id, 0..7)}"
  end

  defp session_title(_session), do: "session"

  defp session_agent_label(%{agent: agent}) when is_binary(agent) and agent != "" do
    agent
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp session_agent_label(_session), do: "Main"
end
