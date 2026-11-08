defmodule Synapsis.SessionDirectory.History do
  @moduledoc false

  alias Synapsis.Session.ReadSnapshot
  alias Synapsis.SessionDirectory.History.{Reader, Services}
  alias Synapsis.SessionDirectory.Projection.PortSession

  def read(entries, limit, opts \\ [])
  def read([], _limit, _opts), do: {:ok, %{entries: [], validation_revision: nil}}

  def read(entries, limit, opts)
      when is_list(entries) and length(entries) <= 200 and is_integer(limit) and limit in 1..20 do
    deadline = Enum.min(Enum.map(entries, & &1.handle.deadline))

    with :ok <- read_options(opts, deadline),
         true <- Enum.all?(entries, &(&1.handle.deadline == deadline)),
         node = Keyword.get(opts, :node_executable),
         {:ok, candidates} <-
           PortSession.run(node, deadline, fn broker ->
             with {:ok, candidates, _broker} <-
                    project(entries, limit, broker, Services.policy()),
                  do: {:ok, candidates}
           end),
         {:ok, validation} <- ReadSnapshot.validate_many(Enum.map(entries, & &1.handle)) do
      current = Map.new(validation.targets, &{&1.session_id, &1.same_lifecycle})
      retained = Enum.filter(candidates, &Map.fetch!(current, &1.row.id))
      {:ok, %{entries: retained, validation_revision: validation.revision}}
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def read(_, _, _), do: {:error, :invalid_input}

  def project(entries, limit, broker, view)
      when is_list(entries) and length(entries) <= 200 and is_integer(limit) and limit in 1..20 do
    if Services.valid?(view) do
      Enum.reduce_while(entries, {:ok, [], broker}, fn entry, {:ok, candidates, broker} ->
        sequence = broker.history_sequence + 1
        slot = "t#{sequence}"

        with {:ok, reader} <- Reader.open(entry, limit, slot),
             start = %{
               "type" => "history_start",
               "protocol" => 1,
               "historyProtocol" => 1,
               "id" => "h#{sequence}",
               "target" => target(entry.row, slot),
               "snapshot" => %{"viewId" => reader.view_id, "totalTurns" => reader.total_turns},
               "row" => entry.row,
               "limit" => limit,
               "servicePolicy" => view
             },
             {:ok, candidate, broker} <-
               PortSession.history(broker, start, &Reader.read(reader, &1)) do
          {:cont, {:ok, [Map.put(entry, :history_candidate, candidate) | candidates], broker}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries, broker} -> {:ok, Enum.reverse(entries), broker}
        error -> error
      end
    else
      {:error, :invalid_projection}
    end
  end

  defp target(row, slot) do
    target = %{"slot" => slot, "sessionId" => row.id}
    if is_nil(Map.get(row, :agent)), do: target, else: Map.put(target, "agentId", row.agent)
  end

  defp read_options(opts, deadline) when is_list(opts) do
    valid =
      Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :node_executable] == [] and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
        Keyword.get(opts, :deadline, deadline) == deadline and
        (not Keyword.has_key?(opts, :node_executable) or is_binary(opts[:node_executable]))

    if valid, do: :ok, else: {:error, :invalid_input}
  end

  defp read_options(_, _), do: {:error, :invalid_input}
end
