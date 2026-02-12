defmodule Synapsis.Repo do
  use Ecto.Repo,
    otp_app: :synapsis_core,
    adapter: Ecto.Adapters.Postgres
end
