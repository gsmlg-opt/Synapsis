defmodule Synapsis.SessionHistory.Window do
  @moduledoc false

  alias Synapsis.Session.ReadSnapshot
  alias Synapsis.SessionDirectory.History.{Pending, Reader, Services}
  alias Synapsis.SessionDirectory.Projection.PortSession

  def validate(input) when is_map(input) and not is_struct(input) do
    valid =
      Map.keys(input) -- ~w(session_id limit offset message_id pending_before include_tools) == [] and
        optional?(input, "session_id", &uuid?/1) and optional?(input, "message_id", &uuid?/1) and
        optional?(input, "limit", &(is_integer(&1) and &1 in 1..1000)) and
        optional?(input, "offset", &(is_integer(&1) and &1 >= 0)) and
        optional?(input, "pending_before", &(is_integer(&1) and &1 > 0)) and
        optional?(input, "include_tools", &is_boolean/1)

    if valid, do: :ok, else: {:error, :invalid_input}
  end

  def validate(_), do: {:error, :invalid_input}

  def read(input, context, opts) do
    with :ok <- validate(input),
         true <-
           is_map(context) and not is_struct(context) and
             Enum.sort(Map.keys(context)) == [:agent_id, :session_id] and
             uuid?(context[:session_id]) and
             is_binary(context[:agent_id]) and byte_size(context.agent_id) in 1..256 and
             String.valid?(context.agent_id) and String.trim(context.agent_id) != "",
         {:ok, deadline, node} <- options(opts),
         id = Map.get(input, "session_id", context.session_id),
         {:ok, handle} <- ReadSnapshot.capture(id, deadline: deadline, max_bytes: 1_048_576),
         true <- Map.get(handle.meta, :id, Map.get(handle.meta, "id")) == id,
         entry = %{handle: handle, row: %{id: id}},
         {:ok, candidate} <-
           PortSession.run(node, handle.deadline, fn broker ->
             with {:ok, reader} <- Reader.open_window(entry, input, "t1"),
                  pending = Pending.page(reader.pending, input),
                  start = %{
                    "type" => "history_start",
                    "mode" => "standalone",
                    "protocol" => 1,
                    "historyProtocol" => 1,
                    "id" => "h1",
                    "target" => %{
                      "slot" => "t1",
                      "sessionId" => id,
                      "agentId" => Map.get(handle.meta, :agent, Map.get(handle.meta, "agent"))
                    },
                    "snapshot" => %{
                      "viewId" => reader.view_id,
                      "totalTurns" => reader.total_turns
                    },
                    "input" => input,
                    "pendingInputs" => pending,
                    "servicePolicy" => Services.policy()
                  },
                  {:ok, candidate, _broker} <-
                    PortSession.history(broker, start, &Reader.read(reader, &1)),
                  true <-
                    candidate.page["session_id"] == id and
                      byte_size(candidate.text) <= 262_144 and
                      :erlang.external_size(%{
                        content: candidate.text,
                        structured: candidate.page
                      }) <= 1_048_576 do
               {:ok, candidate}
             else
               false -> {:error, :output_limit}
               error -> error
             end
           end),
         # run/3 returned only after the actual worker close and Node exit 0.
         # V uses the original owner and deadline. Publication below is pure.
         {:ok, %{targets: [%{session_id: ^id, same_lifecycle: true}]}} <-
           ReadSnapshot.validate_many([handle]) do
      {:ok, candidate}
    else
      false -> {:error, :invalid_context}
      {:error, _} = error -> error
      _ -> {:error, :stale_snapshot}
    end
  end

  defp options(opts) when is_list(opts) do
    ceiling = System.monotonic_time(:millisecond) + 5_000

    valid =
      Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :node_executable] == [] and
        length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
        is_integer(Keyword.get(opts, :deadline, ceiling)) and
        (not Keyword.has_key?(opts, :node_executable) or is_binary(opts[:node_executable]))

    if valid,
      do: {:ok, min(Keyword.get(opts, :deadline, ceiling), ceiling), opts[:node_executable]},
      else: {:error, :invalid_input}
  end

  defp options(_), do: {:error, :invalid_input}
  defp optional?(map, key, fun), do: not Map.has_key?(map, key) or fun.(map[key])
  defp uuid?(value) when is_binary(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value))
  defp uuid?(_), do: false
end
