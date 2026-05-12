defmodule Synapsis.Harness.Loop.NextAction do
  @moduledoc "Command decisions returned by the harness loop reducer."

  def await_user, do: :await_user
  def await_provider, do: :await_provider
  def await_tools, do: :await_tools
  def await_permission, do: :await_permission
  def await_step_decision, do: :await_step_decision
  def halt(reason), do: {:halt, reason}
end
