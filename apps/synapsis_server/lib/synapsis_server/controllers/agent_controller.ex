defmodule SynapsisServer.AgentController do
  use SynapsisServer, :controller

  alias Synapsis.Agent.{Daemon, Runs}
  alias Synapsis.Config.Store

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
    case Daemon.cancel(id) do
      {:ok, run} ->
        json(conn, %{data: serialize_run(run)})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "run not found"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def trigger(conn, %{"kind" => kind} = params) when kind in ["heartbeat", "dream", "schedule"] do
    atom = String.to_existing_atom(kind)
    opts = trigger_opts(atom, params)

    case Daemon.trigger(atom, opts) do
      {:ok, run} ->
        conn |> put_status(:created) |> json(%{data: serialize_run(run)})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def trigger(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "unsupported trigger"})

  def routines(conn, %{"kind" => kind}) when kind in ["heartbeat", "dream", "schedule"] do
    json(conn, %{data: Enum.filter(routines(), &(&1["kind"] == kind))})
  end

  def routines(conn, %{"kind" => _kind}),
    do: conn |> put_status(:not_found) |> json(%{error: "unsupported routine kind"})

  def routines(conn, _params), do: json(conn, %{data: routines()})

  defp routines do
    Store.list(:routine) ++
      Enum.map(Store.list(:heartbeat), &Map.put_new(&1, "kind", "heartbeat"))
  end

  defp trigger_opts(:heartbeat, params),
    do:
      atom_opts(
        params,
        ~w(heartbeat_id routine_id prompt assistant_name tool_profile provider model no_overlap max_runtime_ms)
      )

  defp trigger_opts(_kind, params),
    do:
      atom_opts(
        params,
        ~w(routine_id prompt assistant_name tool_profile provider model no_overlap max_runtime_ms allow_todo_write)
      )

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
       when reason in [:not_ready, :queue_full, :overlap, :not_owned, :terminal] do
    conn |> put_status(:conflict) |> json(%{error: Atom.to_string(reason)})
  end

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
end
