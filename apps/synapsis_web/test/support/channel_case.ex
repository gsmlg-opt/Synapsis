defmodule SynapsisWeb.ChannelCase do
  @moduledoc "Test case for channel tests."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import SynapsisWeb.ChannelCase

      @endpoint SynapsisWeb.Endpoint
    end
  end

  setup tags do
    Synapsis.DataCase.setup_sandbox(tags)
    :ok
  end
end
