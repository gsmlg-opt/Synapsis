defmodule Synapsis.Tool.NotebookRead do
  @moduledoc "Read a Jupyter notebook cell contents."
  use Synapsis.Tool

  @impl true
  def name, do: "notebook_read"

  @impl true
  def description, do: "Read a Jupyter notebook cell contents."

  @impl true
  def permission_level, do: :read

  @impl true
  def category, do: :notebook

  @impl true
  def enabled?, do: Application.get_env(:synapsis_core, :notebook_tools_enabled, false)

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to notebook file"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(_input, _context) do
    {:error, "Notebook tools are not enabled"}
  end
end
