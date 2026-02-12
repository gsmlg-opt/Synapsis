defmodule SynapsisWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :synapsis_web

  @session_options [
    store: :cookie,
    key: "_synapsis_web_key",
    signing_salt: "2/PNbksM",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  socket "/socket", SynapsisWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :synapsis_web,
    gzip: not code_reloading?,
    only: SynapsisWeb.static_paths(),
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
  plug SynapsisWeb.Router
end
