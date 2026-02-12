defmodule Synapsis.Tool.Behaviour do
  @moduledoc "Behaviour for tool implementations."

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback call(input :: map(), context :: map()) :: {:ok, String.t()} | {:error, term()}
end
