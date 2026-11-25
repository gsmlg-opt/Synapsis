defmodule SynapsisServer.VoiceImageController do
  @moduledoc false
  use SynapsisServer, :controller

  alias Synapsis.{Part, Sessions, VoiceSession}
  alias SynapsisServer.Endpoint

  @token_salt "voice-chat-images"
  @max_age 86_400
  @media_types ~w(image/png image/jpeg image/gif image/webp)

  def token(session_id), do: Phoenix.Token.sign(Endpoint, @token_salt, session_id)

  def path(token, turn, part, message_id),
    do: ~p"/api/voice/images/#{turn}/#{part}/#{message_id}?#{[token: token]}"

  def show(conn, %{"token" => token, "turn" => turn, "part" => part, "message_id" => id}) do
    with {:ok, session_id} <-
           Phoenix.Token.verify(Endpoint, @token_salt, token, max_age: @max_age),
         {turn, ""} when turn >= 0 <- Integer.parse(turn),
         {part, ""} when part >= 0 <- Integer.parse(part),
         {:ok, session} <- Sessions.get(session_id),
         true <- Sessions.voice?(session),
         %Part.Image{media_type: media_type, data: data}
         when media_type in @media_types and is_binary(data) <-
           VoiceSession.chat_image(session_id, id, turn, part),
         {:ok, image} <- Base.decode64(data) do
      conn
      |> put_resp_content_type(media_type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")
      |> send_resp(200, image)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "")
end
