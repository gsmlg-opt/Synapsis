defmodule Synapsis.Tool.Computer do
  @moduledoc "Interact with the computer desktop via screenshots and mouse/keyboard input."
  use Synapsis.Tool

  @impl true
  def name, do: "computer"

  @impl true
  def description,
    do: "Interact with the computer desktop via screenshots and mouse/keyboard input."

  @impl true
  def permission_level, do: :execute

  @impl true
  def category, do: :computer

  @impl true
  def enabled?, do: false

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "description" => "Action to perform"},
        "coordinate" => %{
          "type" => "array",
          "items" => %{"type" => "integer"},
          "description" => "Screen coordinates [x, y]"
        },
        "text" => %{"type" => "string", "description" => "Text to type"},
        "key" => %{"type" => "string", "description" => "Key to press"},
        "url" => %{"type" => "string", "description" => "URL to navigate to"}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def execute(_input, _context) do
    {:error, "Computer use is not enabled"}
  end
end
