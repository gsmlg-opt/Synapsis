defmodule Synapsis.Tool.Task do
  @moduledoc "Launch a sub-agent to handle a task autonomously."
  use Synapsis.Tool

  @impl true
  def name, do: "task"

  @impl true
  def description,
    do:
      "Launch a sub-agent to handle a complex task. Runs in foreground (blocking) or background."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{"type" => "string", "description" => "Task description for the sub-agent"},
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tool names available to sub-agent (default: read-only tools)"
        },
        "mode" => %{
          "type" => "string",
          "enum" => ["foreground", "background"],
          "description" => "foreground blocks until complete, background returns immediately"
        },
        "model" => %{"type" => "string", "description" => "Optional model override for sub-agent"}
      },
      "required" => ["prompt"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :orchestration

  @impl true
  def enabled?, do: false

  @impl true
  def execute(input, context) do
    prompt = input["prompt"]
    mode = input["mode"] || "foreground"
    _tools = input["tools"] || default_tools()
    _model = input["model"]

    session_id = context[:session_id]

    if is_nil(session_id) do
      {:error, "No session context available for sub-agent"}
    else
      # TODO: Wire up actual sub-agent session creation and execution.
      # Currently a stub — returns placeholder responses.
      task_id = Ecto.UUID.generate()

      case mode do
        "foreground" ->
          {:ok, "Sub-agent task #{task_id} completed for: #{String.slice(prompt, 0..100)}"}

        "background" ->
          {:ok,
           Jason.encode!(%{
             "task_id" => task_id,
             "status" => "running",
             "prompt" => String.slice(prompt, 0..100)
           })}

        _ ->
          {:error, "Invalid mode: #{mode}. Use 'foreground' or 'background'."}
      end
    end
  end

  defp default_tools do
    ~w(file_read list_dir grep glob diagnostics)
  end
end
