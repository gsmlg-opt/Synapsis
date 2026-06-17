defmodule Synapsis.Session.PendingInputStore do
  @moduledoc """
  Concord-backed queue for prompts and mid-turn steering input.

  Inputs are stored as a session-scoped value under
  `sessions/<id>/pending_inputs`. `kind` and `status` are persisted as strings
  so reloaded data never needs to create atoms from stored values.
  """

  alias Synapsis.Session.Store

  @suffix "pending_inputs"
  @pending_limit 25
  @pending_statuses ~w(queued inflight)

  defstruct [
    :id,
    :session_id,
    :kind,
    :status,
    :content,
    :image_parts,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          kind: String.t(),
          status: String.t(),
          content: String.t(),
          image_parts: list(),
          inserted_at: String.t(),
          updated_at: String.t()
        }

  @doc "List all pending input records for a session in insertion order."
  def list(session_id) when is_binary(session_id) do
    case load(session_id) do
      {:ok, inputs} -> sort_inputs(inputs)
      {:error, :invalid_pending_inputs} -> []
    end
  end

  @doc "List queued prompts for a session in FIFO order."
  def queued_prompts(session_id) when is_binary(session_id) do
    session_id
    |> list()
    |> Enum.filter(&match_input?(&1, "prompt", "queued"))
  end

  @doc "List queued steers for a session in FIFO order."
  def queued_steers(session_id) when is_binary(session_id) do
    session_id
    |> list()
    |> Enum.filter(&match_input?(&1, "steer", "queued"))
  end

  @doc "Append a prompt for the next turn."
  def append_prompt(session_id, content, image_parts)
      when is_binary(session_id) and is_binary(content) and is_list(image_parts) do
    append(session_id, "prompt", content, image_parts)
  end

  @doc "Append a text-only steering instruction for the current turn."
  def append_steer(session_id, content) when is_binary(session_id) and is_binary(content) do
    append(session_id, "steer", content, [])
  end

  @doc """
  Mark the first queued prompt inflight and return its original queued record.
  """
  def take_next_prompt(session_id) when is_binary(session_id) do
    with {:ok, entries} <- load_entries(session_id) do
      inputs = entries_to_inputs(entries)

      case Enum.find(inputs, &match_input?(&1, "prompt", "queued")) do
        nil ->
          :empty

        input ->
          with :ok <- update_matching(session_id, entries, &(&1.id == input.id), "inflight") do
            {:ok, input}
          end
      end
    end
  end

  @doc """
  Mark all queued steers inflight and return their original queued records.
  """
  def take_queued_steers(session_id) when is_binary(session_id) do
    with {:ok, entries} <- load_entries(session_id) do
      steers =
        entries
        |> entries_to_inputs()
        |> Enum.filter(&match_input?(&1, "steer", "queued"))

      case steers do
        [] ->
          []

        steers ->
          steer_ids = MapSet.new(steers, & &1.id)

          with :ok <-
                 update_matching(
                   session_id,
                   entries,
                   &MapSet.member?(steer_ids, &1.id),
                   "inflight"
                 ) do
            steers
          end
      end
    end
  end

  @doc "Mark one pending input consumed."
  def mark_consumed(session_id, input_id) when is_binary(session_id) and is_binary(input_id) do
    with {:ok, entries} <- load_entries(session_id) do
      update_matching(session_id, entries, &(&1.id == input_id), "consumed")
    end
  end

  @doc "Cancel queued or inflight steers without touching prompts."
  def cancel_steers(session_id) when is_binary(session_id) do
    with {:ok, entries} <- load_entries(session_id) do
      update_matching(
        session_id,
        entries,
        &(&1.kind == "steer" and &1.status in @pending_statuses),
        "cancelled"
      )
    end
  end

  @doc "Recover all inflight inputs to queued status after a worker restart."
  def recover_inflight(session_id) when is_binary(session_id) do
    with {:ok, entries} <- load_entries(session_id) do
      update_matching(session_id, entries, &(&1.status == "inflight"), "queued")
    end
  end

  defp append(session_id, kind, content, image_parts) do
    with {:ok, entries} <- load_entries(session_id) do
      inputs = entries_to_inputs(entries)

      if pending_count(inputs) >= @pending_limit do
        {:error, :queue_full}
      else
        now = next_inserted_at(inputs)

        input = %__MODULE__{
          id: Ecto.UUID.generate(),
          session_id: session_id,
          kind: kind,
          status: "queued",
          content: content,
          image_parts: image_parts,
          inserted_at: now,
          updated_at: now
        }

        with :ok <- persist(session_id, entries ++ [stored_input(input)]) do
          {:ok, input}
        end
      end
    end
  end

  defp load(session_id) do
    with {:ok, entries} <- load_entries(session_id) do
      {:ok, entries_to_inputs(entries)}
    end
  end

  defp load_entries(session_id) do
    case Store.get_value(session_id, @suffix, []) do
      inputs when is_list(inputs) -> validate_entries(inputs)
      _inputs -> {:error, :invalid_pending_inputs}
    end
  end

  defp validate_entries(inputs) do
    if Enum.all?(inputs, &is_map/1),
      do: {:ok, inputs},
      else: {:error, :invalid_pending_inputs}
  end

  defp entries_to_inputs(entries) do
    entries
    |> Enum.map(&normalize_input/1)
    |> sort_inputs()
  end

  defp normalize_input(%__MODULE__{} = input) do
    %{input | image_parts: input.image_parts || []}
  end

  defp normalize_input(input) when is_map(input) do
    %__MODULE__{
      id: value(input, :id),
      session_id: value(input, :session_id),
      kind: value(input, :kind),
      status: value(input, :status),
      content: value(input, :content),
      image_parts: value(input, :image_parts) || value(input, :attachments) || [],
      inserted_at: value(input, :inserted_at),
      updated_at: value(input, :updated_at)
    }
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp persist(session_id, entries) do
    Store.put_value(session_id, @suffix, Enum.map(entries, &stored_entry/1))
  end

  defp update_matching(session_id, entries, matcher, status) do
    {updated_entries, changed?} =
      Enum.map_reduce(entries, false, fn entry, changed? ->
        input = normalize_input(entry)

        if matcher.(input) do
          updated_input = touch(%{input | status: status})
          {merge_input(entry, updated_input), true}
        else
          {entry, changed?}
        end
      end)

    if changed?, do: persist(session_id, updated_entries), else: :ok
  end

  defp stored_input(%__MODULE__{} = input) do
    Map.from_struct(input)
  end

  defp stored_entry(%__MODULE__{} = input), do: stored_input(input)
  defp stored_entry(entry) when is_map(entry), do: entry

  defp merge_input(%__MODULE__{} = _entry, %__MODULE__{} = input), do: stored_input(input)

  defp merge_input(entry, %__MODULE__{} = input) when is_map(entry) do
    entry
    |> put_known_key(:id, input.id)
    |> put_known_key(:session_id, input.session_id)
    |> put_known_key(:kind, input.kind)
    |> put_known_key(:status, input.status)
    |> put_known_key(:content, input.content)
    |> put_known_key(:image_parts, input.image_parts)
    |> put_known_key(:inserted_at, input.inserted_at)
    |> put_known_key(:updated_at, input.updated_at)
    |> drop_known_key(:attachments)
  end

  defp put_known_key(map, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, key, value)
    end
  end

  defp drop_known_key(map, key) do
    map
    |> Map.delete(key)
    |> Map.delete(Atom.to_string(key))
  end

  defp pending_count(inputs) do
    Enum.count(inputs, &(&1.status in @pending_statuses))
  end

  defp match_input?(%__MODULE__{kind: kind, status: status}, kind, status), do: true
  defp match_input?(_input, _kind, _status), do: false

  defp touch(%__MODULE__{} = input) do
    %{input | updated_at: now_iso8601()}
  end

  defp sort_inputs(inputs) do
    Enum.sort_by(inputs, &sort_value(&1.inserted_at))
  end

  defp next_inserted_at(inputs) do
    next_microsecond =
      inputs
      |> Enum.map(&sort_value(&1.inserted_at))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)
      |> max(System.system_time(:microsecond))

    next_microsecond
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.to_iso8601()
  end

  defp sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp sort_value(value) when is_integer(value), do: value

  defp sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp sort_value(_value), do: 0
end
