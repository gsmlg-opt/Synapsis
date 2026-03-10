defmodule Synapsis.Tool.Sleep do
  @moduledoc "Pause execution for a specified duration."
  use Synapsis.Tool

  @max_sleep_ms 600_000

  @impl true
  def name, do: "sleep"

  @impl true
  def description, do: "Pause for a specified duration in milliseconds."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "duration_ms" => %{"type" => "integer", "description" => "Duration in milliseconds"},
        "reason" => %{"type" => "string", "description" => "Reason for sleeping"}
      },
      "required" => ["duration_ms"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :session

  @impl true
  def execute(input, _context) do
    duration = min(input["duration_ms"] || 0, @max_sleep_ms)
    reason = input["reason"] || "no reason given"

    receive do
      {:user_input, _msg} ->
        {:ok, "Sleep interrupted by user input after partial wait. Reason: #{reason}"}
    after
      duration ->
        {:ok, "Slept for #{duration}ms. Reason: #{reason}"}
    end
  end
end
