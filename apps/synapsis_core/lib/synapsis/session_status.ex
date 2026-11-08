defmodule Synapsis.SessionStatus do
  @moduledoc """
  Exact durable session metadata observation, without turns or live Worker calls.

  One linked reader shares an absolute deadline of at most five seconds with
  the exact Store.get_meta read. The 1 MiB external-size budget applies to the
  already read metadata, not pre-decode allocations. Public JSON is at most
  64 KiB. Durable status describes the saved record, not current activity.
  The public projection is also used for Worker-owned live metadata.
  """
  alias Synapsis.Session.Store
  @output_limit 65_536
  @metadata_limit 1_048_576
  @text_fields ~w(title agent provider model status)a
  @errors ~w(not_found timeout malformed_metadata payload_too_large storage_unavailable)a

  def read(input, context, opts \\ []) do
    with :ok <- validate(input),
         :ok <- context_valid(context),
         {:ok, deadline} <- deadline(opts),
         id = Map.get(input, "session_id", context.session_id),
         {:ok, meta} <- bounded_read(id, deadline),
         {:ok, session} <- project(meta, id),
         result = %{source: "durable", session: session},
         {:ok, json} <- Jason.encode(result),
         true <- byte_size(json) <= @output_limit,
         :ok <- remaining(deadline) do
      {:ok, result}
    else
      false -> {:error, :output_limit}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :malformed_metadata}
    end
  end

  def validate(input) when is_map(input) and not is_struct(input) do
    if Map.keys(input) -- ~w(session_id source) == [] and
         optional?(input, "session_id", &uuid?/1) and
         optional?(input, "source", &(&1 in ~w(auto live durable))),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate(_), do: {:error, :invalid_input}

  @doc "Validate and bound public metadata for one exact canonical session UUID."
  def project(meta, id) when is_map(meta) and not is_struct(meta) do
    cond do
      :erlang.external_size(meta) > @metadata_limit ->
        {:error, :payload_too_large}

      not uuid?(id) or field(meta, :id) !== id or
          not Enum.all?(
            @text_fields,
            &(is_nil(field(meta, &1)) or valid_string?(field(meta, &1)))
          ) ->
        {:error, :malformed_metadata}

      true ->
        with {:ok, inserted} <- timestamp(field(meta, :inserted_at)),
             {:ok, updated} <- timestamp(field(meta, :updated_at)),
             row = Map.new(@text_fields, &{&1, field(meta, &1)}),
             row = Map.merge(row, %{id: id, inserted_at: inserted, updated_at: updated}),
             {:ok, json} <- Jason.encode(row),
             true <- byte_size(json) <= @output_limit do
          {:ok, row}
        else
          false -> {:error, :output_limit}
          _ -> {:error, :malformed_metadata}
        end
    end
  end

  def project(_, _), do: {:error, :malformed_metadata}

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == [:agent_id, :session_id] and
         uuid?(context[:session_id]) and text?(context[:agent_id], 255),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context_valid(_), do: {:error, :invalid_context}

  defp deadline(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline] == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) do
      ceiling = now() + 5_000
      value = Keyword.get(opts, :deadline, ceiling)
      if is_integer(value), do: {:ok, min(value, ceiling)}, else: {:error, :invalid_input}
    else
      {:error, :invalid_input}
    end
  end

  defp deadline(_), do: {:error, :invalid_input}

  defp bounded_read(id, deadline) do
    with :ok <- remaining(deadline) do
      task =
        Task.async(fn ->
          try do
            with :ok <- remaining(deadline),
                 result <- Store.get_meta(id, timeout: max(deadline - now(), 1)),
                 :ok <- remaining(deadline) do
              result
            end
          rescue
            _ -> {:error, :storage_unavailable}
          catch
            :exit, {:timeout, _} -> {:error, :timeout}
            _, _ -> {:error, :storage_unavailable}
          end
        end)

      case Task.yield(task, max(deadline - now(), 0)) do
        {:ok, {:ok, meta}} ->
          with :ok <- remaining(deadline), do: {:ok, meta}

        {:ok, {:error, reason}} when reason in @errors ->
          {:error, reason}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}

        _ ->
          {:error, :storage_unavailable}
      end
    end
  end

  defp timestamp(nil), do: {:ok, nil}

  defp timestamp(%DateTime{} = time) do
    timestamp(DateTime.to_iso8601(time))
  rescue
    _ -> {:error, :malformed_metadata}
  end

  defp timestamp(time) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, value, _} -> {:ok, DateTime.to_iso8601(value)}
      _ -> {:error, :malformed_metadata}
    end
  end

  defp timestamp(_), do: {:error, :malformed_metadata}
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp optional?(input, key, check), do: not Map.has_key?(input, key) or check.(input[key])
  defp valid_string?(value), do: is_binary(value) and String.valid?(value)

  defp text?(value, limit),
    do: valid_string?(value) and byte_size(value) in 1..limit and String.trim(value) != ""

  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false
  defp remaining(deadline), do: if(deadline > now(), do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)
end
