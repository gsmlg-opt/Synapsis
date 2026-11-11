defmodule Synapsis.Session.PendingInputStore do
  @moduledoc """
  Concord-backed custody for prompts, mid-turn steering and owned system events.

  Inputs share `sessions/<id>/pending_inputs`. All mutations conditionally write
  the exact snapshot they read, with at most three acknowledged-conflict attempts
  sharing one five-second budget checked between operations. Underlying storage
  calls can exceed the requested timeout. Unknown outcomes are never retried.
  """

  alias Synapsis.Session.Store

  @pending_limit 25
  @event_limit 20
  @attempts 3
  @pending_statuses ~w(queued inflight)
  @terminal_phases ~w(completed failed owner_lost)
  @event_whitespace ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u

  defstruct [
    :id,
    :session_id,
    :kind,
    :status,
    :content,
    :image_parts,
    :inserted_at,
    :updated_at,
    :input_provenance,
    :event
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          kind: String.t(),
          status: String.t(),
          content: String.t(),
          image_parts: list(),
          inserted_at: String.t(),
          updated_at: String.t(),
          input_provenance: map() | nil,
          event: map() | nil
        }

  @doc "List all pending input records for a session in insertion order."
  def list(session_id) when is_binary(session_id) do
    case list_result(session_id) do
      {:ok, inputs} -> inputs
      {:error, _reason} -> []
    end
  end

  @doc "Read ordered pending inputs without hiding storage failures."
  def list_result(session_id, opts \\ []) when is_binary(session_id) do
    with {:ok, _snapshot, entries} <- load_entries(session_id, deadline(opts)) do
      {:ok, entries_to_inputs(entries)}
    end
  end

  @doc "List queued prompts for a session in FIFO order."
  def queued_prompts(session_id) when is_binary(session_id) do
    session_id |> list() |> Enum.filter(&match_input?(&1, "prompt", "queued"))
  end

  @doc "List queued steers for a session in FIFO order."
  def queued_steers(session_id) when is_binary(session_id) do
    session_id |> list() |> Enum.filter(&match_input?(&1, "steer", "queued"))
  end

  @doc "Append a prompt, retaining an optional caller-generated UUID and opaque JSON provenance."
  def append_prompt(session_id, content, image_parts, opts \\ [])
      when is_binary(session_id) and is_binary(content) and is_list(image_parts) do
    deadline = deadline(opts)

    with {:ok, id} <- prompt_id(opts),
         {:ok, provenance} <- prompt_provenance(opts) do
      input = %{
        new_input(session_id, "prompt", content, image_parts, id)
        | input_provenance: provenance
      }

      append(session_id, input, @attempts, deadline)
    end
  end

  defp prompt_id(opts) do
    id = Keyword.get_lazy(opts, :id, &Ecto.UUID.generate/0)

    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> {:ok, id}
      _ -> {:error, :invalid_input_id}
    end
  end

  defp prompt_provenance(opts) do
    case Keyword.get(opts, :input_provenance) do
      nil ->
        {:ok, nil}

      value when is_map(value) and not is_struct(value) ->
        case Jason.encode(value) do
          {:ok, _} -> {:ok, value}
          _ -> {:error, :invalid_input_provenance}
        end

      _ ->
        {:error, :invalid_input_provenance}
    end
  end

  @doc "Append a text-only steering instruction for the current turn."
  def append_steer(session_id, content, opts \\ [])
      when is_binary(session_id) and is_binary(content) do
    deadline = deadline(opts)
    append(session_id, new_input(session_id, "steer", content, []), @attempts, deadline)
  end

  @doc "Stage one independently identified event with captured owner and provenance."
  def append_event(session_id, attrs, opts \\ []) when is_binary(session_id) and is_map(attrs) do
    deadline = deadline(opts)

    input =
      new_input(
        session_id,
        "system_event",
        Regex.replace(@event_whitespace, attrs.content, ""),
        []
      )
      |> Map.put(:input_provenance, attrs.input_provenance)
      |> Map.put(:event, %{
        "owner_id" => attrs.owner_id,
        "target_agent_id" => attrs.target_agent_id,
        "mode" => attrs.mode,
        "phase" => "staged"
      })

    append(session_id, input, @attempts, deadline)
  end

  @doc "Mark the first queued prompt inflight and return its original queued record."
  def take_next_prompt(session_id, opts \\ []) when is_binary(session_id) do
    take_next_input(session_id, :prompt_only, @attempts, deadline(opts))
  end

  @doc "Reserve the oldest queued prompt or event belonging to this owner."
  def take_next_turn(session_id, owner_id, opts \\ [])
      when is_binary(session_id) and is_binary(owner_id) do
    take_next_input(session_id, owner_id, @attempts, deadline(opts))
  end

  @doc "Mark all queued steers inflight and return their original queued records."
  def take_queued_steers(session_id, opts \\ []) when is_binary(session_id) do
    take_steers(session_id, @attempts, deadline(opts))
  end

  @doc "Mark one pending input consumed."
  def mark_consumed(session_id, input_id, opts \\ [])
      when is_binary(session_id) and is_binary(input_id) do
    update_status(
      session_id,
      &(&1.id == input_id and &1.kind in ~w(prompt steer)),
      "consumed",
      @attempts,
      deadline(opts)
    )
  end

  @doc "Cancel queued or inflight steers without touching prompts."
  def cancel_steers(session_id, opts \\ []) when is_binary(session_id) do
    update_status(
      session_id,
      &(&1.kind == "steer" and &1.status in @pending_statuses),
      "cancelled",
      @attempts,
      deadline(opts)
    )
  end

  @doc """
  Cancel one still-queued prompt and return its queued record.

  `text_only: true` rejects prompts with images, which cannot become steers.
  """
  def withdraw_prompt(session_id, input_id, opts \\ [])
      when is_binary(session_id) and is_binary(input_id) do
    withdraw(
      session_id,
      input_id,
      Keyword.get(opts, :text_only, false),
      @attempts,
      deadline(opts)
    )
  end

  @doc "Recover inflight ordinary prompts and steers after a worker restart."
  def recover_inflight(session_id, opts \\ []) when is_binary(session_id) do
    update_status(
      session_id,
      &(&1.kind in ~w(prompt steer) and &1.status == "inflight"),
      "queued",
      @attempts,
      deadline(opts)
    )
  end

  @doc "Record exact event adoption after the runtime acknowledges execution start."
  def start_event(session_id, event_id, owner_id, run_id, opts \\ [])
      when is_binary(session_id) and is_binary(event_id) and is_binary(owner_id) and
             is_binary(run_id) do
    update_event(session_id, event_id, owner_id, {:start, run_id}, @attempts, deadline(opts))
  end

  @doc "Retain a correlated event's terminal observation in its existing history row."
  def finish_event(session_id, event_id, owner_id, outcome, opts \\ [])
      when is_binary(session_id) and is_binary(event_id) and is_binary(owner_id) and
             outcome in [:completed, :failed] do
    update_event(session_id, event_id, owner_id, {:finish, outcome}, @attempts, deadline(opts))
  end

  @doc "Recover ordinary input while retiring nonterminal events from a prior owner."
  def recover_for_owner(session_id, owner_id, opts \\ [])
      when is_binary(session_id) and is_binary(owner_id) do
    recover_owner(session_id, owner_id, @attempts, deadline(opts))
  end

  defp new_input(session_id, kind, content, image_parts, id \\ Ecto.UUID.generate()) do
    %__MODULE__{
      id: id,
      session_id: session_id,
      kind: kind,
      status: "queued",
      content: content,
      image_parts: image_parts
    }
  end

  defp append(session_id, input, attempts, deadline) do
    with {:ok, snapshot, entries} <- load_entries(session_id, deadline) do
      inputs = entries_to_inputs(entries)

      cond do
        Enum.any?(inputs, &(&1.id == input.id)) ->
          {:error, :input_conflict}

        pending_count(inputs, input.kind) >= pending_limit(input.kind) ->
          {:error, :queue_full}

        true ->
          now = next_inserted_at(inputs)
          input = %{input | inserted_at: now, updated_at: now}

          case persist(session_id, snapshot, entries ++ [stored_input(input)], deadline) do
            :ok ->
              {:ok, input}

            {:error, :conflict} when attempts > 1 ->
              append(session_id, input, attempts - 1, deadline)

            error ->
              error
          end
      end
    end
  end

  defp take_next_input(session_id, owner_id, attempts, deadline) do
    with {:ok, snapshot, entries} <- load_entries(session_id, deadline) do
      input = entries |> entries_to_inputs() |> Enum.find(&eligible_turn?(&1, owner_id))

      if input do
        updated = status_entries(entries, &(&1.id == input.id), "inflight")

        case persist(session_id, snapshot, updated, deadline) do
          :ok ->
            {:ok, input}

          {:error, :conflict} when attempts > 1 ->
            take_next_input(session_id, owner_id, attempts - 1, deadline)

          error ->
            error
        end
      else
        :empty
      end
    end
  end

  defp eligible_turn?(%__MODULE__{kind: "prompt", status: "queued"}, _owner_id), do: true

  defp eligible_turn?(%__MODULE__{kind: "system_event", status: "queued", event: event}, owner_id)
       when is_binary(owner_id) and is_map(event) do
    value(event, :owner_id) == owner_id and value(event, :phase) == "staged"
  end

  defp eligible_turn?(_input, _owner_id), do: false

  defp take_steers(session_id, attempts, deadline) do
    with {:ok, snapshot, entries} <- load_entries(session_id, deadline) do
      steers = entries |> entries_to_inputs() |> Enum.filter(&match_input?(&1, "steer", "queued"))

      if steers == [] do
        []
      else
        ids = MapSet.new(steers, & &1.id)
        updated = status_entries(entries, &MapSet.member?(ids, &1.id), "inflight")

        case persist(session_id, snapshot, updated, deadline) do
          :ok -> steers
          {:error, :conflict} when attempts > 1 -> take_steers(session_id, attempts - 1, deadline)
          error -> error
        end
      end
    end
  end

  defp withdraw(session_id, input_id, text_only?, attempts, deadline) do
    with {:ok, snapshot, entries} <- load_entries(session_id, deadline) do
      input = entries |> entries_to_inputs() |> Enum.find(&(&1.id == input_id))

      cond do
        not match?(%__MODULE__{kind: "prompt", status: "queued"}, input) ->
          {:error, :input_not_queued}

        text_only? and input.image_parts != [] ->
          {:error, :not_steerable}

        true ->
          updated = status_entries(entries, &(&1.id == input_id), "cancelled")

          case persist(session_id, snapshot, updated, deadline) do
            :ok ->
              {:ok, input}

            {:error, :conflict} when attempts > 1 ->
              withdraw(session_id, input_id, text_only?, attempts - 1, deadline)

            error ->
              error
          end
      end
    end
  end

  defp update_status(session_id, matcher, status, attempts, deadline) do
    with {:ok, snapshot, entries} <- load_entries(session_id, deadline) do
      updated = status_entries(entries, matcher, status)

      case persist(session_id, snapshot, updated, deadline) do
        {:error, :conflict} when attempts > 1 ->
          update_status(session_id, matcher, status, attempts - 1, deadline)

        result ->
          result
      end
    end
  end

  defp status_entries(entries, matcher, status) do
    Enum.map(entries, fn entry ->
      input = normalize_input(entry)

      if matcher.(input) and input.status != status,
        do: merge_input(entry, touch(%{input | status: status})),
        else: entry
    end)
  end

  defp update_event(session_id, event_id, owner_id, transition, attempts, deadline) do
    with {:ok, snapshot, entries} <- load_entries(session_id, deadline),
         input when not is_nil(input) <-
           entries
           |> entries_to_inputs()
           |> Enum.find(&owned_event?(&1, event_id, owner_id)),
         {:ok, updated_input} <- event_transition(input, transition) do
      updated =
        Enum.map(entries, fn entry ->
          if owned_event?(normalize_input(entry), event_id, owner_id) and updated_input != input,
            do: merge_input(entry, touch(updated_input)),
            else: entry
        end)

      case persist(session_id, snapshot, updated, deadline) do
        {:error, :conflict} when attempts > 1 ->
          update_event(session_id, event_id, owner_id, transition, attempts - 1, deadline)

        result ->
          result
      end
    else
      nil -> {:error, :event_not_found}
      error -> error
    end
  end

  defp owned_event?(input, event_id, owner_id) do
    input.id == event_id and input.kind == "system_event" and is_map(input.event) and
      value(input.event, :owner_id) == owner_id
  end

  defp event_transition(input, {:start, run_id}) do
    phase = value(input.event, :phase)

    cond do
      input.status == "consumed" and phase == "started" and value(input.event, :run_id) == run_id ->
        {:ok, input}

      input.status == "inflight" and phase == "staged" ->
        {:ok,
         %{
           input
           | status: "consumed",
             event:
               input.event |> put_event_key(:phase, "started") |> put_event_key(:run_id, run_id)
         }}

      true ->
        {:error, :invalid_event_state}
    end
  end

  defp event_transition(input, {:finish, outcome}) do
    phase = Atom.to_string(outcome)
    status = if outcome == :completed, do: "consumed", else: "failed"

    cond do
      value(input.event, :phase) == phase and input.status == status ->
        {:ok, input}

      value(input.event, :phase) == "started" and input.status == "consumed" ->
        {:ok, %{input | status: status, event: put_event_key(input.event, :phase, phase)}}

      true ->
        {:error, :invalid_event_state}
    end
  end

  defp recover_owner(session_id, owner_id, attempts, deadline) do
    with {:ok, snapshot, entries} <- load_entries(session_id, deadline) do
      updated =
        Enum.map(entries, fn entry ->
          input = normalize_input(entry)

          cond do
            input.kind in ~w(prompt steer) and input.status == "inflight" ->
              merge_input(entry, touch(%{input | status: "queued"}))

            input.kind == "system_event" and is_map(input.event) and
              value(input.event, :owner_id) != owner_id and
                value(input.event, :phase) not in @terminal_phases ->
              merge_input(
                entry,
                touch(%{
                  input
                  | status: "owner_lost",
                    event: put_event_key(input.event, :phase, "owner_lost")
                })
              )

            true ->
              entry
          end
        end)

      case persist(session_id, snapshot, updated, deadline) do
        {:error, :conflict} when attempts > 1 ->
          recover_owner(session_id, owner_id, attempts - 1, deadline)

        result ->
          result
      end
    end
  end

  defp load_entries(session_id, deadline) do
    with {:ok, timeout} <- remaining(deadline),
         {:ok, snapshot} <- Store.read_pending_inputs(session_id, timeout: timeout),
         {:ok, _remaining} <- remaining(deadline) do
      case snapshot do
        :absent ->
          {:ok, snapshot, []}

        {:present, entries, _revision} when is_list(entries) ->
          if Enum.all?(entries, &is_map/1),
            do: {:ok, snapshot, entries},
            else: {:error, :invalid_pending_inputs}

        _ ->
          {:error, :invalid_pending_inputs}
      end
    end
  end

  defp persist(_session_id, {:present, entries, _revision}, entries, deadline) do
    with {:ok, _timeout} <- remaining(deadline), do: :ok
  end

  defp persist(_session_id, :absent, [], deadline) do
    with {:ok, _timeout} <- remaining(deadline), do: :ok
  end

  defp persist(session_id, snapshot, entries, deadline) do
    with {:ok, timeout} <- remaining(deadline) do
      Store.compare_put_pending_inputs(session_id, snapshot, entries, timeout: timeout)
    end
  end

  defp deadline(opts) do
    now = System.monotonic_time(:millisecond)
    min(Keyword.get(opts, :deadline, now + 5_000), now + 5_000)
  end

  defp remaining(deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)
    if timeout > 0, do: {:ok, timeout}, else: {:error, :timeout}
  end

  defp entries_to_inputs(entries) do
    entries |> Enum.map(&normalize_input/1) |> sort_inputs()
  end

  defp normalize_input(%__MODULE__{} = input), do: %{input | image_parts: input.image_parts || []}

  defp normalize_input(input) when is_map(input) do
    %__MODULE__{
      id: value(input, :id),
      session_id: value(input, :session_id),
      kind: value(input, :kind),
      status: value(input, :status),
      content: value(input, :content),
      image_parts: value(input, :image_parts) || value(input, :attachments) || [],
      inserted_at: value(input, :inserted_at),
      updated_at: value(input, :updated_at),
      input_provenance: value(input, :input_provenance),
      event: value(input, :event)
    }
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp stored_input(%__MODULE__{} = input) do
    input
    |> Map.from_struct()
    |> put_or_drop_optional(:input_provenance, input.input_provenance)
    |> put_or_drop_optional(:event, input.event)
  end

  defp put_or_drop_optional(map, key, nil), do: Map.delete(map, key)
  defp put_or_drop_optional(map, key, value), do: Map.put(map, key, value)

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
    |> merge_optional(:input_provenance, input.input_provenance)
    |> merge_optional(:event, input.event)
    |> Map.delete(:attachments)
    |> Map.delete("attachments")
  end

  defp merge_optional(map, _key, nil), do: map
  defp merge_optional(map, key, value), do: put_known_key(map, key, value)

  defp put_event_key(map, key, value) do
    if Map.has_key?(map, key),
      do: Map.put(map, key, value),
      else: Map.put(map, Atom.to_string(key), value)
  end

  defp put_known_key(map, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, key, value)
    end
  end

  defp pending_count(inputs, "system_event") do
    Enum.count(inputs, &(&1.kind == "system_event" and &1.status in @pending_statuses))
  end

  defp pending_count(inputs, _kind) do
    Enum.count(inputs, &(&1.kind in ~w(prompt steer) and &1.status in @pending_statuses))
  end

  defp pending_limit("system_event"), do: @event_limit
  defp pending_limit(_kind), do: @pending_limit

  defp match_input?(%__MODULE__{kind: kind, status: status}, kind, status), do: true
  defp match_input?(_input, _kind, _status), do: false

  defp touch(%__MODULE__{} = input),
    do: %{input | updated_at: DateTime.to_iso8601(DateTime.utc_now())}

  defp sort_inputs(inputs), do: Enum.sort_by(inputs, &sort_value(&1.inserted_at))

  defp next_inserted_at(inputs) do
    next_microsecond =
      inputs
      |> Enum.map(&sort_value(&1.inserted_at))
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)
      |> max(System.system_time(:microsecond))

    next_microsecond |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
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
