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
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def chat_bubble(assigns) do
    ~H"""
    <div class={[
      "flex",
      if(@role == "user", do: "justify-end", else: "justify-start"),
      @class
    ]}>
      <div class={[
        "rounded-lg px-3 py-2 max-w-[80%] text-sm",
        if(@role == "user",
          do: "bg-primary-container text-on-primary-container",
          else: "bg-surface-container-high text-on-surface"
        )
      ]}>
        <div :if={@label && @role == "assistant"} class="text-xs font-medium text-primary/70 mb-1">
          {@label}
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

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
  Embedded Code Agent panel — shown inline in chat when the Assistant spawns a sub-agent.
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
    <div class={["border border-outline-variant rounded-lg p-3 text-sm", @class]}>
      <div class="flex items-center gap-2 mb-1">
        <.dm_mdi name="wrench" class="w-4 h-4 text-on-surface-variant" />
        <span class="font-medium">{@name}</span>
        <.dm_badge variant={tool_status_color(@status)} size="sm">
          {@status}
        </.dm_badge>
      </div>
      <div :if={@params != []} class="text-xs text-on-surface-variant mt-1">
        {render_slot(@params)}
      </div>
      <div :if={@result != []} class="text-xs mt-2 border-t border-outline-variant pt-2">
        {render_slot(@result)}
      </div>
    </div>
    """
  end

  defp tool_status_color("pending"), do: "ghost"
  defp tool_status_color("running"), do: "warning"
  defp tool_status_color("complete"), do: "success"
  defp tool_status_color("error"), do: "error"

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
  Settings navigation sidebar with active state.
  """
  attr :current_path, :string, required: true
  attr :class, :string, default: nil

  def settings_sidebar(assigns) do
    items = [
      %{to: ~p"/settings/providers", icon: "cloud", label: "Providers"},
      %{to: ~p"/settings/models", icon: "tune", label: "Default Model"},
      %{to: ~p"/settings/memory", icon: "brain", label: "Memory"},
      %{to: ~p"/settings/skills", icon: "lightning-bolt", label: "Skills"},
      %{to: ~p"/settings/mcp", icon: "puzzle", label: "MCP Servers"},
      %{to: ~p"/settings/lsp", icon: "code-braces", label: "LSP Servers"}
    ]

    assigns = assign(assigns, :items, items)

    ~H"""
    <nav class={["hidden md:block w-56 shrink-0 border-r border-outline-variant py-4 pr-4", @class]}>
      <.dm_left_menu active={active_menu_id(@current_path, @items)} size="sm">
        <:title>Settings</:title>
        <:menu :for={item <- @items}>
          <.dm_link navigate={item.to} class="flex items-center gap-2 w-full">
            <.dm_mdi name={item.icon} class="w-4 h-4" />
            {item.label}
          </.dm_link>
        </:menu>
      </.dm_left_menu>
    </nav>
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
      <div class="flex items-center gap-3">
        <div class="flex items-center gap-1.5 text-xs text-on-surface-variant">
          <span class={[
            "inline-block w-2 h-2 rounded-full",
            status_dot_color(@session_status)
          ]}>
          </span>
          {@session_status}
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

  defp status_dot_color("idle"), do: "bg-primary"
  defp status_dot_color("streaming"), do: "bg-info animate-pulse"
  defp status_dot_color("tool_executing"), do: "bg-warning animate-pulse"
  defp status_dot_color("error"), do: "bg-error"
  defp status_dot_color(_), do: "bg-on-surface/30"

  @doc """
  Breadcrumb navigation with proper link support.

  Replaces `dm_breadcrumb` which uses unstyled DaisyUI `breadcrumbs` class
  and doesn't render the `to` attribute as links.
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

  Displays system status indicator and links to settings/assistant.
  """
  def global_status_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between bg-surface-container border-t border-outline-variant px-3 py-1 shrink-0">
      <div class="flex items-center gap-3">
        <.dm_link
          navigate={~p"/assistant"}
          class="flex items-center gap-1.5 text-xs text-on-surface-variant hover:text-on-surface transition-colors"
        >
          <.dm_mdi name="robot-outline" class="w-3.5 h-3.5" />
          <span class="hidden sm:inline">Assistant</span>
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

  defp active_menu_id(current_path, items) do
    Enum.find_value(items, fn item ->
      if String.starts_with?(current_path, item.to), do: item.to
    end)
  end

  @doc """
  Renders a message's parts, dispatching to the appropriate sub-component per part type.
  """
  attr :message, :map, required: true
  attr :class, :string, default: nil

  def message_parts(assigns) do
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
              <.chat_bubble role="system">
                <.dm_markdown content={content} theme="auto" />
              </.chat_bubble>
            <% true -> %>
              <.chat_bubble role={@message.role}>
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
    """
  end

  @doc """
  Collapsible reasoning/thinking trace block.
  """
  attr :content, :string, required: true
  attr :collapsed, :boolean, default: true
  attr :class, :string, default: nil

  def reasoning_block(assigns) do
    ~H"""
    <details class={["group", @class]} open={!@collapsed}>
      <summary class="flex items-center gap-2 cursor-pointer text-xs text-on-surface-variant hover:text-on-surface-variant py-1">
        <.dm_mdi name="thought-bubble-outline" class="w-4 h-4" />
        <span>Thinking</span>
        <.dm_mdi
          name="chevron-right"
          class="w-3.5 h-3.5 transition-transform group-open:rotate-90"
        />
      </summary>
      <div class="ml-6 mt-1 text-xs text-on-surface-variant whitespace-pre-wrap max-h-48 overflow-y-auto">
        {@content}
      </div>
    </details>
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
      <span class="flex gap-1">
        <span class="w-1.5 h-1.5 rounded-full bg-primary animate-bounce [animation-delay:0ms]" />
        <span class="w-1.5 h-1.5 rounded-full bg-primary animate-bounce [animation-delay:150ms]" />
        <span class="w-1.5 h-1.5 rounded-full bg-primary animate-bounce [animation-delay:300ms]" />
      </span>
      <span>Generating...</span>
    </div>
    """
  end

  @doc """
  Session list sidebar item with title, provider/model, status, and delete button.
  """
  attr :session, :map, required: true
  attr :active, :boolean, default: false
  attr :class, :string, default: nil

  def session_list_item(assigns) do
    ~H"""
    <div
      phx-click="switch_session"
      phx-value-id={@session.id}
      class={[
        "group flex items-center gap-2 px-3 py-2 cursor-pointer transition-colors text-sm",
        if(@active,
          do: "bg-primary/10 text-primary border-r-2 border-primary",
          else: "text-on-surface-variant hover:bg-surface-container-high"
        ),
        @class
      ]}
    >
      <span class={[
        "inline-block w-2 h-2 rounded-full shrink-0",
        status_dot_color(@session.status || "idle")
      ]}>
      </span>
      <div class="flex-1 min-w-0">
        <div class="truncate font-medium">
          {@session.title || "Session #{String.slice(@session.id, 0..7)}"}
        </div>
        <div class="text-xs text-on-surface-variant truncate">
          {@session.provider}/{@session.model}
        </div>
      </div>
      <.dm_btn
        variant="ghost"
        size="xs"
        phx-click="delete_session"
        phx-value-id={@session.id}
        data-confirm="Delete this session?"
        class="opacity-0 group-hover:opacity-100"
      >
        <.dm_mdi name="delete-outline" class="w-3.5 h-3.5" />
      </.dm_btn>
    </div>
    """
  end
end
