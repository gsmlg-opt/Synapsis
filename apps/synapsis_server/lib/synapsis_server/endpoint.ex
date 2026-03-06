defmodule SynapsisServer.Endpoint do
  use Phoenix.Endpoint, otp_app: :synapsis_server

  @session_options [
    store: :cookie,
    key: "_synapsis_key",
    signing_salt: "2/PNbksM",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  socket "/socket", SynapsisServer.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: {:synapsis_web, "priv/static"},
    gzip: not code_reloading?,
    only: SynapsisServer.static_paths(),
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
    json_decoder: Phoenix.json_library(),
    length: 8_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug :reject_live_longpoll
  plug SynapsisServer.Router

  defp reject_live_longpoll(%Plug.Conn{request_path: "/live/longpoll"} = conn, _opts) do
    conn
    |> Plug.Conn.send_resp(410, "LiveView longpoll is disabled. WebSocket transport is required.")
    |> Plug.Conn.halt()
  end

  defp reject_live_longpoll(conn, _opts), do: conn
end
