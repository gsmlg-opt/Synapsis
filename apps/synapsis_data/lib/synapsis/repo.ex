defmodule Synapsis.Repo do
  use Ecto.Repo,
    otp_app: :synapsis_data,
    adapter: Ecto.Adapters.Postgres
end
