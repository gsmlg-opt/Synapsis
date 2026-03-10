defmodule Synapsis.Tool.NotebookEdit do
  @moduledoc "Edit a Jupyter notebook cell."
  use Synapsis.Tool

  @impl true
  def name, do: "notebook_edit"

  @impl true
  def description, do: "Edit a Jupyter notebook cell."

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :notebook

  @impl true
  def side_effects, do: [:file_changed]

  @impl true
  def enabled?, do: false

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to notebook file"},
        "cell_number" => %{"type" => "integer", "description" => "Cell number to edit"},
        "content" => %{"type" => "string", "description" => "New cell content"},
        "cell_type" => %{
          "type" => "string",
          "description" => "Cell type (code or markdown)",
          "default" => "code"
        },
        "edit_mode" => %{
          "type" => "string",
          "description" => "Edit mode (replace or append)",
          "default" => "replace"
        }
      },
      "required" => ["path", "cell_number", "content"]
    }
  end

  @impl true
  def execute(_input, _context) do
    {:error, "Notebook tools are not enabled"}
  end
end
