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
    :attachments,
    :inserted_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          kind: String.t(),
          status: String.t(),
          content: String.t(),
          attachments: list(),
          inserted_at: String.t(),
          updated_at: String.t()
        }

  @doc "List all pending input records for a session in insertion order."
  def list(session_id) when is_binary(session_id) do
    session_id
    |> load()
    |> sort_inputs()
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
  def append_prompt(session_id, content, attachments)
      when is_binary(session_id) and is_binary(content) and is_list(attachments) do
    append(session_id, "prompt", content, attachments)
  end

  @doc "Append a text-only steering instruction for the current turn."
  def append_steer(session_id, content) when is_binary(session_id) and is_binary(content) do
    append(session_id, "steer", content, [])
  end

  @doc """
  Mark the first queued prompt inflight and return its original queued record.
  """
  def take_next_prompt(session_id) when is_binary(session_id) do
    inputs = list(session_id)

    case Enum.find(inputs, &match_input?(&1, "prompt", "queued")) do
      nil ->
        :none

      input ->
        with :ok <- update_statuses(session_id, inputs, &mark_id(&1, input.id, "inflight")) do
          {:ok, input}
        end
    end
  end

  @doc """
  Mark all queued steers inflight and return their original queued records.
  """
  def take_queued_steers(session_id) when is_binary(session_id) do
    inputs = list(session_id)
    steers = Enum.filter(inputs, &match_input?(&1, "steer", "queued"))

    with :ok <-
           update_statuses(session_id, inputs, fn input ->
             if match_input?(input, "steer", "queued"),
               do: touch(%{input | status: "inflight"}),
               else: input
           end) do
      steers
    end
  end

  @doc "Mark one pending input consumed."
  def mark_consumed(session_id, input_id) when is_binary(session_id) and is_binary(input_id) do
    update_statuses(session_id, list(session_id), &mark_id(&1, input_id, "consumed"))
  end

  @doc "Cancel queued or inflight steers without touching prompts."
  def cancel_steers(session_id) when is_binary(session_id) do
    update_statuses(session_id, list(session_id), fn input ->
      if input.kind == "steer" and input.status in @pending_statuses,
        do: touch(%{input | status: "cancelled"}),
        else: input
    end)
  end

  @doc "Recover all inflight inputs to queued status after a worker restart."
  def recover_inflight(session_id) when is_binary(session_id) do
    update_statuses(session_id, list(session_id), fn input ->
      if input.status == "inflight", do: touch(%{input | status: "queued"}), else: input
    end)
  end

  defp append(session_id, kind, content, attachments) do
    inputs = list(session_id)

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
        attachments: attachments,
        inserted_at: now,
        updated_at: now
      }

      with :ok <- persist(session_id, inputs ++ [input]) do
        {:ok, input}
      end
    end
  end

  defp load(session_id) do
    session_id
    |> Store.get_value(@suffix, [])
    |> normalize_inputs()
  end

  defp normalize_inputs(inputs) when is_list(inputs), do: Enum.map(inputs, &normalize_input/1)
  defp normalize_inputs(_inputs), do: []

  defp normalize_input(%__MODULE__{} = input) do
    %{input | attachments: input.attachments || []}
  end

  defp normalize_input(input) when is_map(input) do
    %__MODULE__{
      id: value(input, :id),
      session_id: value(input, :session_id),
      kind: value(input, :kind),
      status: value(input, :status),
      content: value(input, :content),
      attachments: value(input, :attachments) || [],
      inserted_at: value(input, :inserted_at),
      updated_at: value(input, :updated_at)
    }
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp persist(session_id, inputs) do
    Store.put_value(session_id, @suffix, Enum.map(inputs, &Map.from_struct/1))
  end

  defp update_statuses(session_id, inputs, fun) do
    persist(session_id, Enum.map(inputs, fun))
  end

  defp mark_id(input, id, status) do
    if input.id == id, do: touch(%{input | status: status}), else: input
  end

  defp touch(%__MODULE__{} = input) do
    %{input | updated_at: now_iso8601()}
  end

  defp pending_count(inputs) do
    Enum.count(inputs, &(&1.status in @pending_statuses))
  end

  defp match_input?(%__MODULE__{kind: kind, status: status}, kind, status), do: true
  defp match_input?(_input, _kind, _status), do: false

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
