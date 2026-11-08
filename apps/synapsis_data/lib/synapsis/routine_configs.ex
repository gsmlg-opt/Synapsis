defmodule Synapsis.RoutineConfigs do
  @moduledoc """
  Read-only, bounded inventory of persisted Routine and legacy Heartbeat configs.

  Visibility follows the exact configured execution route (`agent_name`), with
  missing routes using `main`. This is route visibility, not creator ownership.
  Disabled entries remain visible. No scheduler or private config data is read.

  Each source observes its own current healthy snapshot; these reads do not form
  a transaction across stores. One absolute monotonic deadline (at most five
  seconds) covers requester checks, queued snapshots and result encoding.
  """

  alias Synapsis.{AgentConfigs, Config.Store}

  @doc "List visible public metadata with limit (1..100, default 20), cursor and deadline options."
  def directory(requester_name, opts \\ []) do
    with true <- route?(requester_name),
         {:ok, options} <- options(opts, [:limit, :cursor, :deadline]),
         {:ok, cursor} <- decode_cursor(options.cursor, requester_name),
         {:ok, snapshot} <- snapshot(requester_name, options.deadline),
         :ok <- cursor_requester(cursor, snapshot.requester),
         routines = Enum.sort_by(snapshot.routines, &{&1.name, &1.source, &1.id}),
         {:ok, remaining} <- after_cursor(routines, cursor),
         {page, rest} = Enum.split(remaining, options.limit) do
      encode_result(
        %{
          requester: snapshot.requester,
          routines: page,
          count: length(page),
          has_more: rest != [],
          next_cursor: next_cursor(page, rest, snapshot.requester)
        },
        options.deadline
      )
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  @doc "Get exact source-qualified visible UUID metadata with only a deadline option."
  def get_visible(requester_name, source, id, opts \\ []) do
    with true <- route?(requester_name) and source in ["routine", "heartbeat"] and uuid?(id),
         {:ok, options} <- options(opts, [:deadline]),
         {:ok, snapshot} <- snapshot(requester_name, options.deadline),
         routine when not is_nil(routine) <-
           Enum.find(snapshot.routines, &(&1.source == source and &1.id == id)) do
      encode_result(%{requester: snapshot.requester, routine: routine}, options.deadline)
    else
      false -> {:error, :invalid_input}
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp snapshot(requester_name, deadline) do
    with :ok <- active(deadline),
         {:ok, before} <- AgentConfigs.directory(requester_name, limit: 1, deadline: deadline),
         :ok <- active(deadline),
         {:ok, routines} <- Store.routine_directory_snapshot(:routine, deadline, 1_000),
         :ok <- active(deadline),
         {:ok, heartbeats} <-
           Store.routine_directory_snapshot(:heartbeat, deadline, 1_000 - routines.count),
         :ok <- active(deadline),
         {:ok, after_read} <-
           AgentConfigs.directory(requester_name, limit: 1, deadline: deadline),
         true <- before.requester == after_read.requester,
         :ok <- active(deadline) do
      {:ok,
       %{
         requester: before.requester,
         routines:
           Enum.filter(
             routines.routines ++ heartbeats.routines,
             &(&1.agent_name == requester_name)
           )
       }}
    else
      false -> {:error, :requester_unavailable}
      {:error, _} = error -> error
    end
  end

  defp options(opts, allowed) do
    valid =
      is_list(opts) and Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
        is_integer(Keyword.get(opts, :deadline, 0)) and
        is_integer(Keyword.get(opts, :limit, 20)) and Keyword.get(opts, :limit, 20) in 1..100

    if valid do
      ceiling = System.monotonic_time(:millisecond) + 5_000

      {:ok,
       %{
         limit: Keyword.get(opts, :limit, 20),
         cursor: Keyword.get(opts, :cursor),
         deadline: min(Keyword.get(opts, :deadline, ceiling), ceiling)
       }}
    else
      {:error, :invalid_input}
    end
  end

  defp decode_cursor(nil, _requester_name), do: {:ok, nil}

  defp decode_cursor(cursor, requester_name)
       when is_binary(cursor) and byte_size(cursor) in 1..4_096 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [1, requester_id, ^requester_name, name, source, id]} <- Jason.decode(json),
         true <- uuid?(requester_id) and uuid?(id),
         true <- is_binary(name) and byte_size(name) in 1..256 and String.valid?(name),
         true <- source in ["routine", "heartbeat"],
         anchor = {name, source, id},
         requester = %{id: requester_id, name: requester_name},
         true <- encode_cursor(requester, anchor) == cursor do
      {:ok, %{requester: requester, anchor: anchor}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode_cursor(_, _), do: {:error, :invalid_cursor}

  defp cursor_requester(nil, _), do: :ok
  defp cursor_requester(%{requester: requester}, requester), do: :ok
  defp cursor_requester(_, _), do: {:error, :invalid_cursor}

  defp after_cursor(routines, nil), do: {:ok, routines}

  defp after_cursor(routines, %{anchor: anchor}) do
    case Enum.drop_while(routines, &({&1.name, &1.source, &1.id} != anchor)) do
      [_ | remaining] -> {:ok, remaining}
      [] -> {:error, :stale_cursor}
    end
  end

  defp next_cursor(_, [], _), do: nil

  defp next_cursor(page, _rest, requester) do
    last = List.last(page)
    encode_cursor(requester, {last.name, last.source, last.id})
  end

  defp encode_cursor(requester, {name, source, id}),
    do:
      [1, requester.id, requester.name, name, source, id]
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

  defp encode_result(result, deadline) do
    with :ok <- active(deadline),
         {:ok, encoded} <- Jason.encode(result),
         :ok <- active(deadline) do
      if byte_size(encoded) <= 65_536,
        do: {:ok, result},
        else: {:error, :output_too_large}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_config}
      {:error, _} = error -> error
    end
  end

  defp route?(name),
    do:
      is_binary(name) and byte_size(name) in 1..256 and String.valid?(name) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)

  defp uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> true
      _ -> false
    end
  end

  defp uuid?(_), do: false

  defp active(deadline),
    do:
      if(System.monotonic_time(:millisecond) < deadline,
        do: :ok,
        else: {:error, :timeout}
      )
end
