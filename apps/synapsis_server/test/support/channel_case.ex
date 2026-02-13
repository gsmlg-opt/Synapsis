defmodule SynapsisServer.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest

      @endpoint SynapsisServer.Endpoint
    end
  end

  setup tags do
    Synapsis.DataCase.setup_sandbox(tags)
    :ok
  end
end
