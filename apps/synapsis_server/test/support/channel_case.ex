defmodule SynapsisServerWeb.ChannelCase do
  @moduledoc "Test case for channel tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import SynapsisServerWeb.ChannelCase

      @endpoint SynapsisServerWeb.Endpoint
    end
  end

  setup tags do
    Synapsis.DataCase.setup_sandbox(tags)
    :ok
  end
end
