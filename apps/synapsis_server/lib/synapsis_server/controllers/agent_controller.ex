defmodule SynapsisServer.AgentController do
  use SynapsisServer, :controller

  alias Synapsis.Agent.{Daemon, Routines, Runs}

  def status(conn, _params), do: json(conn, %{data: Daemon.status()})

  def runs(conn, params) do
    limit = parse_limit(params["limit"])
    json(conn, %{data: Enum.map(Runs.list_recent(limit: limit), &serialize_run/1)})
  end

  def show_run(conn, %{"id" => id}) do
    case Runs.fetch(id) do
      {:ok, run} ->
        json(conn, %{data: serialize_run(run)})

      :not_found ->
        conn |> put_status(:not_found) |> json(%{error: "run not found"})

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "run unavailable"})
    end
  end

  def run(conn, %{"prompt" => prompt} = params) do
    opts = atom_opts(params, ~w(assistant_name provider model source tool_profile metadata))

    case Daemon.submit(prompt, opts) do
      {:ok, run} ->
        conn |> put_status(:created) |> json(%{data: serialize_run(run)})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def run(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "prompt is required"})

  def cancel(conn, %{"id" => id}) do
    case Daemon.cancel(Daemon, id) do
      {:ok, run} ->
        json(conn, %{data: serialize_run(run)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "run not found"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def create_routine(conn, params) do
    case Routines.create(params) do
      {:ok, routine} -> conn |> put_status(:created) |> json(%{data: routine})
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def update_routine(conn, %{"id" => id} = params) do
    case Routines.update(id, Map.delete(params, "id")) do
      {:ok, routine} -> json(conn, %{data: routine})
      {:error, reason} -> error_response(conn, reason)
    end
  end

  def trigger_routine(conn, %{"id" => id}) do
    case Routines.trigger(id) do
      {:ok, run} ->
        conn |> put_status(:created) |> json(%{data: serialize_run(run)})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def trigger_heartbeat(conn, params), do: trigger_kind(conn, "heartbeat", params["name"])
  def trigger_dream(conn, _params), do: trigger_kind(conn, "dream", nil)

  def routines(conn, %{"kind" => kind}) when kind in ["heartbeat", "dream", "schedule"] do
    json(conn, %{data: Routines.list(kind)})
  end

  def routines(conn, %{"kind" => _kind}),
    do: conn |> put_status(:not_found) |> json(%{error: "unsupported routine kind"})

  def routines(conn, _params), do: json(conn, %{data: Routines.list()})

  defp atom_opts(params, keys) do
    Enum.reduce(keys, %{}, fn key, opts ->
      case params[key] do
        nil -> opts
        value -> Map.put(opts, String.to_atom(key), value)
      end
    end)
  end

  defp parse_limit(nil), do: 50
  defp parse_limit(value) when is_binary(value), do: value |> Integer.parse() |> limit_value()
  defp parse_limit(value) when is_integer(value), do: max(min(value, 100), 0)
  defp parse_limit(_value), do: 50
  defp limit_value({value, _}) when value >= 0, do: min(value, 100)
  defp limit_value(_), do: 50

  defp error_response(conn, reason)
       when reason in [
              :not_ready,
              :queue_full,
              :overlap,
              :not_owned,
              :terminal,
              :disabled,
              :ambiguous
            ] do
    conn |> put_status(:conflict) |> json(%{error: Atom.to_string(reason)})
  end

  defp error_response(conn, :not_found),
    do: conn |> put_status(:not_found) |> json(%{error: "routine not found"})

  defp error_response(conn, reason) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
  end

  defp serialize_run(run) do
    run
    |> Map.from_struct()
    |> Map.update!(:inserted_at, &iso/1)
    |> Map.update!(:updated_at, &iso/1)
    |> Map.update!(:started_at, &iso/1)
    |> Map.update!(:finished_at, &iso/1)
  end

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(value), do: value

  defp trigger_kind(conn, kind, name) do
    case Routines.trigger_kind(kind, name) do
      {:ok, run} -> conn |> put_status(:created) |> json(%{data: serialize_run(run)})
      {:error, reason} -> error_response(conn, reason)
    end
  end
end
