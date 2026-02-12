defmodule SynapsisServerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :synapsis_server

  @session_options [
    store: :cookie,
    key: "_synapsis_server_key",
    signing_salt: "2/PNbksM",
    same_site: "Lax"
  ]

  socket "/socket", SynapsisServerWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :synapsis_server,
    gzip: not code_reloading?,
    only: SynapsisServerWeb.static_paths(),
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug CORSPlug, origin: ["http://localhost:3000", "http://localhost:4000"]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SynapsisServerWeb.Router
end
