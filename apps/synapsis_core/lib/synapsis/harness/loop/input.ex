defmodule Synapsis.Harness.Loop.Input do
  @moduledoc "External inputs accepted by the harness loop reducer."

  defmodule UserPrompt do
    @moduledoc "A user submitted a prompt to an idle session."
    defstruct [:message_id, parts: []]
  end

  defmodule UserAbort do
    @moduledoc "A user requested cancellation."
    defstruct [:reason]
  end

  defmodule ProviderEvent do
    @moduledoc "A normalized provider stream event arrived."
    defstruct [:event]
  end

  defmodule ProviderError do
    @moduledoc "The provider stream failed before yielding a normalized event."
    defstruct [:reason]
  end

  defmodule ToolStarted do
    @moduledoc "A tool runner acknowledged start."
    defstruct [:part_id]
  end

  defmodule ToolCompleted do
    @moduledoc "A tool runner completed successfully."
    defstruct [:part_id, :result]
  end

  defmodule ToolFailed do
    @moduledoc "A tool runner failed."
    defstruct [:part_id, :error]
  end

  defmodule PermissionGranted do
    @moduledoc "A user granted a pending permission request."
    defstruct [:request_id, :scope]
  end

  defmodule PermissionDenied do
    @moduledoc "A user denied a pending permission request."
    defstruct [:request_id]
  end

  defmodule BudgetTick do
    @moduledoc "A periodic wall-clock or token budget check."
    defstruct [:wall_clock_now]
  end
end
