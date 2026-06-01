defmodule SynapsisData.Application do
  @moduledoc """
  Boot for the data/storage layer (ADR-006 "synapsis_store").

  Owns the file-backed `Config.Store` (TOML configs), which lives here — not in
  `synapsis_core` — so that lower apps like `synapsis_provider` can read their
  configuration without depending upward on core. The embedded Concord session
  store starts via its own `:concord` application; the readiness gate runs in
  `SynapsisCore.Application` after the supervision tree is up.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Synapsis.Config.Store.Supervisor
    ]

    opts = [strategy: :one_for_one, name: SynapsisData.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
