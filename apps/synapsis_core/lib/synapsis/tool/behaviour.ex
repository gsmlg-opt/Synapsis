defmodule Synapsis.Tool.Behaviour do
  @moduledoc """
  Deprecated: Use `use Synapsis.Tool` instead.

  Kept for compile compatibility only.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback call(input :: map(), context :: map()) :: {:ok, String.t()} | {:error, term()}
end
