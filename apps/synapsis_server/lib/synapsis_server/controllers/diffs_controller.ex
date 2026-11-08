defmodule SynapsisServer.DiffsController do
  @moduledoc "Serves live Diffs receipts and the exact verified packaged viewer assets."
  use SynapsisServer, :controller

  alias Synapsis.Agent.DiffsDelivery
  alias Synapsis.Diffs.Config
  alias SynapsisServer.DiffsViewerLimiter

  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @csp "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; base-uri 'none'; frame-ancestors 'self'; object-src 'none'"
  @proxy_headers ~w(x-forwarded-for x-real-ip forwarded x-forwarded-host x-forwarded-proto)
  @file_mimes %{"png" => "image/png", "pdf" => "application/pdf"}

  def viewer(conn, %{"artifact_id" => id, "token" => token}) do
    with {:ok, config} <- Config.load(),
         {:ok, client} <- viewer_client(conn, config),
         :ok <- viewer_admission(client) do
      serve_viewer(conn, id, token, client)
    else
      {:error, :remote_disabled} ->
        text(conn, 404, "Diff not found")

      {:error, retry_ms} when is_integer(retry_ms) ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(max(1, ceil(retry_ms / 1000))))
        |> text(429, "Too Many Requests")

      {:error, _} ->
        text(conn, 503, "Diff delivery unavailable")
    end
  end

  def file(conn, %{"session_id" => session_id, "delivery_id" => delivery_id}) do
    case DiffsDelivery.read_file(session_id, delivery_id, []) do
      {:ok, %{bytes: bytes, descriptor: %{"format" => format}}}
      when is_map_key(@file_mimes, format) ->
        conn
        |> put_resp_header("content-disposition", "attachment; filename=\"preview.#{format}\"")
        |> respond(200, bytes, @file_mimes[format])

      {:error, reason} ->
        unavailable(conn, reason)
    end
  end

  def asset(conn, %{"asset" => asset}) when asset in ~w(viewer.js viewer-runtime.js) do
    with {:ok, config} <- Config.load(),
         {:ok, bytes} <- packaged_asset(config, asset) do
      cache =
        if asset == "viewer-runtime.js",
          do: "public, max-age=31536000, immutable",
          else: "no-store, max-age=0"

      respond(conn, 200, bytes, "text/javascript; charset=utf-8", cache)
    else
      {:error, _} -> text(conn, 503, "Viewer asset unavailable")
    end
  end

  def asset(conn, _params), do: text(conn, 404, "Asset not found")

  defp serve_viewer(conn, id, token, client) do
    if String.match?(id, ~r/\A[a-f0-9]{20}\z/) and String.match?(token, ~r/\A[a-f0-9]{48}\z/) do
      case DiffsDelivery.read_viewer(id, token, []) do
        {:ok, %{bytes: html}} ->
          case reset_client(client) do
            :ok ->
              conn
              |> put_resp_header("content-security-policy", @csp)
              |> respond(200, html, "text/html; charset=utf-8")

            {:error, _} ->
              text(conn, 503, "Diff delivery unavailable")
          end

        {:error, reason} ->
          viewer_unavailable(conn, client, reason)
      end
    else
      viewer_unavailable(conn, client, :not_found)
    end
  end

  defp viewer_unavailable(conn, client, reason) do
    case fail_client(client) do
      :ok -> unavailable(conn, reason)
      {:error, _} -> text(conn, 503, "Diff delivery unavailable")
    end
  end

  defp viewer_client(conn, config) do
    local? =
      loopback?(conn.remote_ip) and Enum.all?(@proxy_headers, &(get_req_header(conn, &1) == []))

    cond do
      local? ->
        {:ok, :local}

      config["security"]["allowRemoteViewer"] == true ->
        {:ok, {:remote, client_key(conn.remote_ip)}}

      true ->
        {:error, :remote_disabled}
    end
  end

  # There is no trusted-proxy configuration in this host boundary. Forwarding
  # hints never establish locality or replace the socket peer's limiter identity.
  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, prefix, _}) when prefix in 32_512..32_767, do: true
  defp loopback?(_), do: false
  defp client_key(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp client_key(_), do: "unknown"
  defp viewer_admission(:local), do: :ok
  defp viewer_admission({:remote, key}), do: DiffsViewerLimiter.check(key)
  defp reset_client(:local), do: :ok
  defp reset_client({:remote, key}), do: DiffsViewerLimiter.reset(key)
  defp fail_client(:local), do: :ok
  defp fail_client({:remote, key}), do: DiffsViewerLimiter.record_failure(key)

  defp packaged_asset(config, asset) do
    root =
      case config["host"]["helperPath"] do
        path when is_binary(path) -> Path.dirname(path)
        nil -> Application.app_dir(:synapsis_core, "priv/diffs_renderer")
      end

    with {:ok, provenance_bytes} <-
           read_bounded(Path.join(root, "provenance.json"), 16 * 1024 * 1024),
         {:ok, %{"version" => 1, "reference" => @reference, "artifacts" => artifacts}} <-
           Jason.decode(provenance_bytes),
         true <- is_list(artifacts),
         {:ok, capsule_bytes} <-
           verified_file(
             root,
             "capsule.json",
             Enum.find(artifacts, &(&1["path"] == "capsule.json"))
           ),
         {:ok,
          %{"version" => 1, "reference" => @reference, "languagePackAvailable" => false} = capsule} <-
           Jason.decode(capsule_bytes),
         {:ok, manifest_bytes} <- verified_asset(root, "manifest.json", capsule, artifacts),
         {:ok,
          %{
            "manifest_version" => 1,
            "entries" => %{
              "viewer-runtime.js" => %{"file" => "viewer-runtime.js", "isEntry" => true}
            }
          }} <- Jason.decode(manifest_bytes),
         {:ok, bytes} <- verified_asset(root, asset, capsule, artifacts) do
      {:ok, bytes}
    else
      _ -> {:error, :asset_unavailable}
    end
  end

  defp verified_asset(root, asset, %{"assets" => assets}, artifacts) when is_map(assets) do
    path = "assets/" <> asset
    expected = assets[asset]
    provenance = Enum.find(artifacts, &(&1["path"] == path))

    if is_map(expected) and is_map(provenance) and
         Map.take(expected, ~w(bytes sha256)) == Map.take(provenance, ~w(bytes sha256)) do
      verified_file(root, path, expected)
    else
      {:error, :asset_unavailable}
    end
  end

  defp verified_asset(_, _, _, _), do: {:error, :asset_unavailable}

  defp verified_file(root, path, %{"bytes" => size, "sha256" => sha})
       when is_integer(size) and size > 0 and size <= 32 * 1024 * 1024 and is_binary(sha) do
    with {:ok, bytes} <- read_bounded(Path.join(root, path), size),
         true <- byte_size(bytes) == size,
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha do
      {:ok, bytes}
    else
      _ -> {:error, :asset_unavailable}
    end
  end

  defp verified_file(_, _, _), do: {:error, :asset_unavailable}

  defp read_bounded(path, limit) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= limit <- File.lstat(path),
         {:ok, bytes} when byte_size(bytes) <= limit <- File.read(path) do
      {:ok, bytes}
    else
      _ -> {:error, :asset_unavailable}
    end
  end

  defp unavailable(conn, reason)
       when reason in [
              :not_found,
              :invalid_delivery,
              :delivery_not_found,
              :artifact_unavailable,
              :expired,
              :invalid_token,
              :artifact_not_found,
              :artifact_expired
            ],
       do: text(conn, 404, "Diff not found or expired")

  defp unavailable(conn, _reason), do: text(conn, 503, "Diff delivery unavailable")
  defp text(conn, status, bytes), do: respond(conn, status, bytes, "text/plain; charset=utf-8")

  defp respond(conn, status, bytes, mime, cache \\ "no-store, max-age=0") do
    conn
    |> put_resp_header("content-type", mime)
    |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
    |> put_resp_header("cache-control", cache)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> send_resp(status, if(conn.method == "HEAD", do: "", else: bytes))
  end
end
