defmodule Synapsis.AutomationDirectory do
  @moduledoc """
  Bounded public Routine and legacy Heartbeat configuration reads.

  Visibility follows the trusted configured requester's execution route. The data
  layer owns healthy projections, scoped cursors and exact source-qualified reads.
  One absolute deadline covers the linked reader, which dies on caller cancellation.
  """

  alias Synapsis.{RoutineConfigs, RoutineRuns}

  @timeout 5_000
  @errors ~w(invalid_input timeout requester_unavailable storage_unavailable
    invalid_config invalid_cursor stale_cursor scan_limit output_too_large not_found)a

  def read(input, context, opts \\ []) do
    with :ok <- validate(input),
         :ok <- context_valid(context),
         {:ok, deadline} <- deadline(opts),
         :ok <- remaining(deadline),
         result <- bounded_read(input, context.requester_name, deadline),
         :ok <- remaining(deadline) do
      result
    end
  end

  def validate(input) when is_map(input) and not is_struct(input) do
    valid =
      case input do
        %{"action" => "list"} ->
          Map.keys(input) -- ~w(action limit cursor) == [] and
            optional?(input, "limit", &(is_integer(&1) and &1 in 1..100)) and
            optional?(input, "cursor", &cursor?/1)

        %{"action" => "runs", "source" => source, "id" => id} ->
          Map.keys(input) -- ~w(action source id limit cursor run_id) == [] and
            source in ["routine", "heartbeat"] and uuid?(id) and
            optional?(input, "limit", &(is_integer(&1) and &1 in 1..100)) and
            optional?(input, "cursor", &cursor?/1) and optional?(input, "run_id", &uuid?/1) and
            not (Map.has_key?(input, "cursor") and Map.has_key?(input, "run_id"))

        %{"action" => "get", "source" => source, "id" => id} ->
          Map.keys(input) -- ~w(action source id) == [] and
            source in ["routine", "heartbeat"] and uuid?(id)

        _ ->
          false
      end

    if valid, do: :ok, else: {:error, :invalid_input}
  end

  def validate(_), do: {:error, :invalid_input}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == [:requester_name, :session_id] and
         uuid?(context[:session_id]) and name?(context[:requester_name]),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp deadline(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      ceiling = now() + @timeout
      deadline = Keyword.get(opts, :deadline, ceiling)

      if is_integer(deadline),
        do: {:ok, min(deadline, ceiling)},
        else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp deadline(_), do: {:error, :invalid_input}

  defp bounded_read(input, requester, deadline) do
    task =
      Task.async(fn ->
        try do
          case read_data(input, requester, deadline) do
            {:ok, result} when is_map(result) -> {:ok, result}
            {:error, reason} when reason in @errors -> {:error, reason}
            _ -> {:error, :storage_unavailable}
          end
        rescue
          _ -> {:error, :storage_unavailable}
        catch
          _, _ -> {:error, :storage_unavailable}
        end
      end)

    case Task.yield(task, max(deadline - now(), 0)) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, :storage_unavailable}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp read_data(%{"action" => "list"} = input, requester, deadline) do
    opts = [deadline: deadline, limit: Map.get(input, "limit", 20)]
    opts = if Map.has_key?(input, "cursor"), do: opts ++ [cursor: input["cursor"]], else: opts
    RoutineConfigs.directory(requester, opts)
  end

  defp read_data(%{"action" => "get", "source" => source, "id" => id}, requester, deadline),
    do: RoutineConfigs.get_visible(requester, source, id, deadline: deadline)

  defp read_data(
         %{"action" => "runs", "source" => source, "id" => id} = input,
         requester,
         deadline
       ) do
    opts = [deadline: deadline, limit: Map.get(input, "limit", 20)]

    opts =
      Enum.reduce(["cursor", "run_id"], opts, fn key, opts ->
        if Map.has_key?(input, key),
          do: Keyword.put(opts, String.to_existing_atom(key), input[key]),
          else: opts
      end)

    RoutineRuns.page(requester, source, id, opts)
  end

  defp optional?(input, key, check), do: not Map.has_key?(input, key) or check.(input[key])

  defp cursor?(cursor),
    do: is_binary(cursor) and byte_size(cursor) in 1..4_096 and String.valid?(cursor)

  defp name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..256 and String.valid?(name) and
        Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false
  defp remaining(deadline), do: if(now() < deadline, do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)
end
