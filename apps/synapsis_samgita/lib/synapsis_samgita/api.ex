defmodule SynapsisSamgita.API do
  @moduledoc """
  Client for the Samgita agent management API (`/api/agent/*`).

  `conn` is `%{base_url, credential, connection_id}`; `connection_id` is nil only
  for `connect/1`. Every write carries a `command_id` (generated unless given via
  `opts[:command_id]`, so callers can retry an uncertain write verbatim).

  Returns `{:ok, data}` (the response's `"data"`) or
  `{:error, %{status: integer | nil, code: String.t(), detail: term}}`.
  """

  @receive_timeout 10_000

  @type conn :: %{base_url: String.t(), credential: String.t(), connection_id: String.t() | nil}
  @type error :: %{status: non_neg_integer() | nil, code: String.t(), detail: term()}
  @type result :: {:ok, term()} | {:error, error}

  @spec connect(conn, keyword) :: result
  def connect(conn, opts \\ []), do: write(conn, "/connect", %{}, opts)

  @spec list_projects(conn) :: result
  def list_projects(conn), do: read(conn, "/projects", limit: 100)

  @spec list_tasks(conn, String.t(), String.t()) :: result
  def list_tasks(conn, project_id, agent_id),
    do: read(conn, "/projects/#{project_id}/tasks", assignee_agent_id: agent_id, limit: 100)

  @spec create_session(conn, String.t(), String.t(), keyword) :: result
  def create_session(conn, project_id, external_id, opts \\ []),
    do: write(conn, "/projects/#{project_id}/sessions", %{"external_id" => external_id}, opts)

  @spec claim(conn, String.t(), String.t(), integer, String.t(), keyword) :: result
  def claim(conn, project_id, task_id, expected_version, session_id, opts \\ []) do
    write(
      conn,
      "/projects/#{project_id}/tasks/#{task_id}/claim",
      %{"expected_version" => expected_version, "session_id" => session_id},
      opts
    )
  end

  @spec proof(conn, String.t(), String.t()) :: {:ok, String.t()} | {:error, error}
  def proof(conn, project_id, attempt_id) do
    with {:ok, %{"proof" => proof}} <-
           read(conn, "/projects/#{project_id}/attempts/#{attempt_id}/proof", []) do
      {:ok, proof}
    end
  end

  def start(conn, project_id, attempt_id, version, proof, opts \\ []),
    do: attempt(conn, project_id, attempt_id, "start", version, proof, %{}, opts)

  def renew(conn, project_id, attempt_id, version, proof, opts \\ []),
    do: attempt(conn, project_id, attempt_id, "renew", version, proof, %{}, opts)

  def progress(conn, project_id, attempt_id, version, proof, summary, opts \\ []) do
    attempt(
      conn,
      project_id,
      attempt_id,
      "progress",
      version,
      proof,
      %{"payload" => %{"summary" => summary}},
      opts
    )
  end

  def report(
        conn,
        project_id,
        attempt_id,
        version,
        proof,
        outcome,
        effects_resolved,
        result,
        opts \\ []
      )
      when outcome in ["succeeded", "failed"] and is_boolean(effects_resolved) do
    body =
      %{"outcome" => outcome, "effects_resolved" => effects_resolved}
      |> then(&if(is_map(result), do: Map.put(&1, "result", result), else: &1))

    attempt(conn, project_id, attempt_id, "report", version, proof, body, opts)
  end

  defp attempt(conn, project_id, attempt_id, action, version, proof, body, opts) do
    body = Map.merge(body, %{"expected_version" => version, "proof" => proof})
    write(conn, "/projects/#{project_id}/attempts/#{attempt_id}/#{action}", body, opts)
  end

  defp read(conn, path, params), do: request(conn, :get, path, params: params)

  defp write(conn, path, body, opts) do
    command_id = Keyword.get_lazy(opts, :command_id, &Ecto.UUID.generate/0)
    request(conn, :post, path, json: Map.put(body, "command_id", command_id))
  end

  defp request(conn, method, path, req_opts) do
    headers =
      [{"authorization", "Bearer " <> conn.credential}] ++
        if(conn.connection_id, do: [{"x-agent-connection", conn.connection_id}], else: [])

    [
      method: method,
      url: conn.base_url <> "/api/agent" <> path,
      headers: headers,
      receive_timeout: Map.get(conn, :receive_timeout, @receive_timeout),
      connect_options: [timeout: 5_000],
      retry: false,
      redirect: false
    ]
    |> Keyword.merge(req_opts)
    |> Req.request()
    |> normalize()
  end

  defp normalize({:ok, %Req.Response{status: status, body: %{"data" => data}}})
       when status in 200..299,
       do: {:ok, data}

  defp normalize(
         {:ok, %Req.Response{status: status, body: %{"errors" => %{"code" => code} = errors}}}
       ),
       do:
         {:error,
          %{status: status, code: code, detail: errors["detail"], fields: errors["fields"]}}

  defp normalize({:ok, %Req.Response{status: status}}),
    do: {:error, %{status: status, code: "unexpected_response", detail: nil}}

  defp normalize({:error, exception}),
    do: {:error, %{status: nil, code: "transport_error", detail: Exception.message(exception)}}
end
