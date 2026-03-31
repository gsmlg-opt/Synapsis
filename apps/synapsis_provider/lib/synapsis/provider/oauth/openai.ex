defmodule Synapsis.Provider.OAuth.OpenAI do
  @moduledoc """
  OpenAI device code OAuth flow for ChatGPT subscription accounts.

  Implements the hybrid device-code + PKCE flow used by OpenAI Codex CLI:
  1. Request user code via device auth endpoint
  2. User visits verification URL and enters code
  3. Poll for authorization (returns auth code + PKCE verifier)
  4. Exchange authorization code for tokens
  5. Refresh tokens when expired

  See: https://developers.openai.com/codex/auth
  """

  require Logger

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @auth_base_url "https://auth.openai.com"
  @verification_url "https://auth.openai.com/codex/device"
  @device_callback_uri "https://auth.openai.com/deviceauth/callback"

  # 15 minutes max polling
  @max_poll_duration_ms 15 * 60 * 1000
  # Default poll interval (seconds)
  @default_poll_interval 5

  @doc "Return the verification URL the user should visit."
  def verification_url, do: @verification_url

  @doc "Return the OAuth client ID."
  def client_id, do: @client_id

  @doc """
  Step 1: Request a device user code.

  Returns `{:ok, %{device_auth_id: id, user_code: code, interval: seconds}}`
  or `{:error, reason}`.
  """
  def request_user_code do
    url = "#{@auth_base_url}/api/accounts/deviceauth/usercode"

    case Req.post(url,
           json: %{client_id: @client_id},
           headers: [{"content-type", "application/json"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           device_auth_id: body["device_auth_id"],
           user_code: body["user_code"],
           interval: parse_interval(body["interval"])
         }}

      {:ok, %{status: 404}} ->
        {:error, :device_auth_not_enabled}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Step 2: Poll for device authorization.

  Returns `{:ok, %{authorization_code: code, code_verifier: verifier}}`
  when the user has authorized, `{:pending, :authorization_pending}` when
  still waiting, or `{:error, reason}` on failure.
  """
  def poll_device_token(device_auth_id, user_code) do
    url = "#{@auth_base_url}/api/accounts/deviceauth/token"

    case Req.post(url,
           json: %{device_auth_id: device_auth_id, user_code: user_code},
           headers: [{"content-type", "application/json"}]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok,
         %{
           authorization_code: body["authorization_code"],
           code_verifier: body["code_verifier"],
           code_challenge: body["code_challenge"]
         }}

      {:ok, %{status: status}} when status in [403, 404] ->
        {:pending, :authorization_pending}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Step 3: Exchange authorization code for tokens.

  Returns `{:ok, %{access_token: ..., refresh_token: ..., id_token: ..., expires_in: ...}}`
  or `{:error, reason}`.
  """
  def exchange_code(authorization_code, code_verifier) do
    url = "#{@auth_base_url}/oauth/token"

    body =
      URI.encode_query(%{
        "grant_type" => "authorization_code",
        "client_id" => @client_id,
        "code" => authorization_code,
        "code_verifier" => code_verifier,
        "redirect_uri" => @device_callback_uri
      })

    case Req.post(url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           id_token: body["id_token"],
           expires_in: body["expires_in"]
         }}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Refresh an access token using a refresh token.

  Returns `{:ok, %{access_token: ..., refresh_token: ..., id_token: ...}}`
  or `{:error, reason}`.
  """
  def refresh_token(refresh_token) do
    url = "#{@auth_base_url}/oauth/token"

    case Req.post(url,
           json: %{
             client_id: @client_id,
             grant_type: "refresh_token",
             refresh_token: refresh_token
           },
           headers: [{"content-type", "application/json"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           access_token: body["access_token"],
           refresh_token: body["refresh_token"],
           id_token: body["id_token"]
         }}

      {:ok, %{status: 401, body: %{"error" => error_code}}} ->
        {:error, {:token_expired, error_code}}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if stored OAuth tokens need refreshing.
  Tokens are refreshed if last_refresh is older than 7 days or access_token is nil.
  """
  def needs_refresh?(%{"last_refresh" => last_refresh}) when is_binary(last_refresh) do
    case DateTime.from_iso8601(last_refresh) do
      {:ok, dt, _} ->
        DateTime.diff(DateTime.utc_now(), dt, :day) >= 7

      _ ->
        true
    end
  end

  def needs_refresh?(_), do: true

  @doc "Build a token config map suitable for storage in provider config JSONB."
  def build_token_config(tokens) do
    %{
      "oauth_tokens" => %{
        "access_token" => tokens.access_token,
        "refresh_token" => tokens.refresh_token,
        "id_token" => tokens.id_token
      },
      "last_refresh" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "auth_mode" => "oauth_device"
    }
  end

  @doc "Extract the access token from a provider config map."
  def access_token_from_config(%{"oauth_tokens" => %{"access_token" => token}}), do: token
  def access_token_from_config(_), do: nil

  @doc "Extract the refresh token from a provider config map."
  def refresh_token_from_config(%{"oauth_tokens" => %{"refresh_token" => token}}), do: token
  def refresh_token_from_config(_), do: nil

  @doc "Return max poll duration in milliseconds."
  def max_poll_duration_ms, do: @max_poll_duration_ms

  defp parse_interval(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> @default_poll_interval
    end
  end

  defp parse_interval(val) when is_integer(val) and val > 0, do: val
  defp parse_interval(_), do: @default_poll_interval
end
