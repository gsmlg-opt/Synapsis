defmodule Synapsis.Harness.Loop.Effect do
  @moduledoc "Side-effect commands emitted by the pure harness loop reducer."

  defmodule StartProviderStream do
    @moduledoc "Start or resume a provider stream."
    defstruct [:request]
  end

  defmodule CancelProviderStream do
    @moduledoc "Cancel the active provider stream."
    defstruct []
  end

  defmodule StartTool do
    @moduledoc "Start a tool invocation."
    defstruct [:part_id, :tool_name, args: %{}]
  end

  defmodule CancelTool do
    @moduledoc "Cancel an in-flight tool invocation."
    defstruct [:part_id]
  end

  defmodule RequestPermission do
    @moduledoc "Ask presentation/runtime code for permission to run a tool."
    defstruct [:request_id, :tool_call, :effect_class]
  end
end
