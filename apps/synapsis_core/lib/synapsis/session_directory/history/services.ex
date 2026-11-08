defmodule Synapsis.SessionDirectory.History.Services do
  @moduledoc false

  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @policy %{
    "version" => 1,
    "referenceCommit" => @reference,
    "logging" => %{"kind" => "pinned-default", "mappedOverride" => "absent"}
  }

  # The helper captures its actual environment once. Core supplies only this
  # explicit service binding; no caller environment or configuration override.
  def policy, do: @policy
  def valid?(view), do: view == @policy
end
