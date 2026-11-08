defmodule SynapsisServer.MediaController do
  @moduledoc """
  Serves verified audio, image and video deliveries as complete responses.

  Range requests are ignored; partial responses and seeking are not implemented.
  """
  use SynapsisServer, :controller

  alias Synapsis.Agent.MediaDelivery

  def audio(conn, %{"session_id" => session_id, "delivery_id" => delivery_id}) do
    case MediaDelivery.read(session_id, delivery_id) do
      {:ok, %{audio: bytes, descriptor: descriptor}} ->
        disposition =
          if descriptor["mime_type"] == "application/octet-stream",
            do: "attachment",
            else: "inline"

        conn
        |> put_resp_header("content-type", descriptor["mime_type"])
        |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
        |> put_resp_header(
          "content-disposition",
          "#{disposition}; filename=\"audio.#{descriptor["format"]}\""
        )
        |> put_resp_header("accept-ranges", "none")
        |> send_resp(200, bytes)

      {:error, reason} when reason in [:invalid_delivery, :delivery_not_found] ->
        unavailable(conn, :not_found)

      _ ->
        unavailable(conn, :service_unavailable)
    end
  end

  def image(conn, %{"session_id" => session_id, "delivery_id" => delivery_id}) do
    case MediaDelivery.read_image(session_id, delivery_id) do
      {:ok, %{image: bytes, descriptor: descriptor}} ->
        conn
        |> put_resp_header("content-type", descriptor["mime_type"])
        |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
        |> put_resp_header(
          "content-disposition",
          "inline; filename=\"image.#{descriptor["format"]}\""
        )
        |> send_resp(200, bytes)

      {:error, reason} when reason in [:invalid_delivery, :delivery_not_found] ->
        image_unavailable(conn, :not_found)

      _ ->
        image_unavailable(conn, :service_unavailable)
    end
  end

  def video(conn, %{"session_id" => session_id, "delivery_id" => delivery_id}) do
    case MediaDelivery.read_video(session_id, delivery_id) do
      {:ok, %{video: bytes, descriptor: descriptor}} ->
        conn
        |> put_resp_header("content-type", descriptor["mime_type"])
        |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
        |> put_resp_header(
          "content-disposition",
          "inline; filename=\"video.#{descriptor["format"]}\""
        )
        |> put_resp_header("accept-ranges", "none")
        |> send_resp(200, bytes)

      {:error, reason} when reason in [:invalid_delivery, :delivery_not_found] ->
        video_unavailable(conn, :not_found)

      _ ->
        video_unavailable(conn, :service_unavailable)
    end
  end

  defp video_unavailable(conn, status) do
    conn
    |> put_status(status)
    |> json(%{error: "Video delivery unavailable"})
  end

  defp image_unavailable(conn, status) do
    conn
    |> put_status(status)
    |> json(%{error: "Image delivery unavailable"})
  end

  defp unavailable(conn, status) do
    conn
    |> put_status(status)
    |> json(%{error: "Audio delivery unavailable"})
  end
end
