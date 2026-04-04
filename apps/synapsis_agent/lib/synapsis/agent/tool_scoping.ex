defmodule Synapsis.Agent.ToolScoping do
  @moduledoc "Role-based tool category filtering."

  @assistant_categories [:workflow, :planning, :interaction, :web, :orchestration, :memory, :workspace, :session]
  @build_categories [:filesystem, :search, :execution, :web, :planning]

  @spec categories_for_role(:assistant | :build) :: [atom()]
  def categories_for_role(:assistant), do: @assistant_categories
  def categories_for_role(:build), do: @build_categories
end
