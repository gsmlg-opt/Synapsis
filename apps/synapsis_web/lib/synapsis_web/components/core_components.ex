defmodule SynapsisWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for the Synapsis web interface.
  """
  use Phoenix.Component

  @doc """
  Renders flash messages.
  """
  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, :info)}
      class="p-4 bg-blue-900/50 text-blue-200 rounded mb-4"
    >
      {msg}
    </div>
    <div
      :if={msg = Phoenix.Flash.get(@flash, :error)}
      class="p-4 bg-red-900/50 text-red-200 rounded mb-4"
    >
      {msg}
    </div>
    """
  end
end
