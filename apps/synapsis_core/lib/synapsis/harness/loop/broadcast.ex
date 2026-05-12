defmodule Synapsis.Harness.Loop.Broadcast do
  @moduledoc "UI-facing broadcasts emitted by the pure harness loop reducer."

  defmodule TextDelta do
    @moduledoc "Broadcast a text content fragment."
    defstruct [:part_id, :fragment]
  end

  defmodule ReasoningDelta do
    @moduledoc "Broadcast a reasoning content fragment."
    defstruct [:part_id, :fragment]
  end

  defmodule ToolArgsDelta do
    @moduledoc "Broadcast a tool argument fragment."
    defstruct [:part_id, :fragment]
  end

  defmodule StatusChanged do
    @moduledoc "Broadcast a session status transition."
    defstruct [:status]
  end
end
