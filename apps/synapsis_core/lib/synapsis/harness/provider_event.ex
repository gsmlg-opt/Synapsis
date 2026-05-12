defmodule Synapsis.Harness.ProviderEvent do
  @moduledoc "Provider stream event ADTs consumed by the pure harness loop reducer."

  defmodule StepStart do
    @moduledoc "Provider started a generation step."
    defstruct [:step_id, :model_id]
  end

  defmodule TextDelta do
    @moduledoc "Provider emitted assistant text content."
    defstruct [:part_id, :fragment]
  end

  defmodule ReasoningDelta do
    @moduledoc "Provider emitted assistant reasoning content."
    defstruct [:part_id, :fragment]
  end

  defmodule ToolCallStart do
    @moduledoc "Provider started a tool call part."
    defstruct [:part_id, :tool_name]
  end

  defmodule ToolCallArgsDelta do
    @moduledoc "Provider emitted a tool call argument fragment."
    defstruct [:part_id, :fragment]
  end

  defmodule ToolCallComplete do
    @moduledoc "Provider completed a tool call argument payload."
    defstruct [:part_id, args: %{}]
  end

  defmodule StepFinish do
    @moduledoc "Provider finished a generation step."
    defstruct [:step_id, :stop_reason, usage: %{}]
  end

  defmodule Done do
    @moduledoc "Provider stream completed."
    defstruct []
  end

  defmodule Error do
    @moduledoc "Provider stream returned an error."
    defstruct [:reason, retriable?: false]
  end
end
