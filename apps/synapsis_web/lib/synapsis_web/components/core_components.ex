defmodule SynapsisWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the Synapsis web interface.

  Most components come from `phoenix_duskmoon` via `use PhoenixDuskmoon.Component`.
  This module holds app-specific components only.
  """
  use Phoenix.Component
  use PhoenixDuskmoon.Component

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
          <div class="text-sm text-base-content/60">{@label}</div>
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
      <.dm_mdi name={@icon} class="w-12 h-12 text-base-content/30 mx-auto mb-3" />
      <h3 class="text-lg font-medium text-base-content/60">{@title}</h3>
      <p :if={@description} class="text-sm text-base-content/40 mt-1">{@description}</p>
      <div :if={@action != []} class="mt-4">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  Chat message bubble — right-aligned for user, left-aligned for assistant.
  """
  attr :role, :string, required: true, values: ~w(user assistant)
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
          do: "bg-primary/20 text-base-content",
          else: "bg-base-300 text-base-content whitespace-pre-wrap"
        )
      ]}>
        {render_slot(@inner_block)}
      </div>
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
    <div class={["border border-base-300 rounded-lg p-3 text-sm", @class]}>
      <div class="flex items-center gap-2 mb-1">
        <.dm_mdi name="wrench" class="w-4 h-4 text-base-content/60" />
        <span class="font-medium">{@name}</span>
        <.dm_badge color={tool_status_color(@status)} size="sm">
          {@status}
        </.dm_badge>
      </div>
      <div :if={@params != []} class="text-xs text-base-content/50 mt-1">
        {render_slot(@params)}
      </div>
      <div :if={@result != []} class="text-xs mt-2 border-t border-base-300 pt-2">
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
        "bg-base-300 text-base-content/60 rounded px-3 py-2 border border-base-300",
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
    <div class={["flex gap-0 bg-base-300 rounded-lg p-0.5", @class]}>
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
    <nav class={["hidden md:block w-56 shrink-0 border-r border-base-300 py-4 pr-4", @class]}>
      <.dm_left_menu active={active_menu_id(@current_path, @items)} size="sm">
        <:title>Settings</:title>
        <:menu :for={item <- @items} id={item.to}>
          <.dm_link navigate={item.to} class="flex items-center gap-2 w-full">
            <.dm_mdi name={item.icon} class="w-4 h-4" />
            {item.label}
          </.dm_link>
        </:menu>
      </.dm_left_menu>
    </nav>
    """
  end

  defp active_menu_id(current_path, items) do
    Enum.find_value(items, fn item ->
      if String.starts_with?(current_path, item.to), do: item.to
    end)
  end
end
