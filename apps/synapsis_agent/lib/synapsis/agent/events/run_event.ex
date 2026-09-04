defmodule Synapsis.Agent.Events.RunEvent do
  @moduledoc """
  Typed internal run/session event envelope (Track B).

  PubSub projections such as `{"done", %{}}` remain UI-facing. Internal
  consumers (SessionBridge, heartbeat, future RunCoordinator) must correlate
  on these typed events instead of parsing UI strings or transcripts.
  """

  @schema_version 1

  @session_terminal_types ~w(
    session.completed
    session.failed
    session.cancelled
    session.timed_out
  )

  @turn_types ~w(session.turn_completed)

  @run_lifecycle_types ~w(
    run.created
    run.starting
    run.started
    run.waiting_approval
    run.resumed
    run.sleeping
    run.completed
    run.failed
    run.cancelled
    run.timed_out
    run.unknown_outcome
    run.reconciled
    run.side_effect_intent
  )

  @critical_run_types MapSet.new(~w(
    run.created
    run.starting
    run.started
    run.waiting_approval
    run.resumed
    run.sleeping
    run.completed
    run.failed
    run.cancelled
    run.timed_out
    run.unknown_outcome
    run.reconciled
    run.side_effect_intent
  ))

  @known_types @session_terminal_types ++ @turn_types ++ @run_lifecycle_types

  @enforce_keys [:event_id, :type, :schema_version, :occurred_at, :payload]
  defstruct [
    :event_id,
    :run_id,
    :session_id,
    :sequence,
    :type,
    :schema_version,
    :occurred_at,
    :payload,
    :causation_id,
    :correlation_id
  ]

  @type t :: %__MODULE__{
          event_id: String.t(),
          run_id: String.t() | nil,
          session_id: String.t() | nil,
          sequence: non_neg_integer() | nil,
          type: String.t(),
          schema_version: pos_integer(),
          occurred_at: DateTime.t(),
          payload: map(),
          causation_id: String.t() | nil,
          correlation_id: String.t() | nil
        }

  @doc "Build a validated event. Raises `ArgumentError` on invalid input."
  @spec new(String.t(), keyword() | map()) :: t()
  def new(type, attrs \\ []) when is_binary(type) do
    case build(type, attrs) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid RunEvent: #{inspect(reason)}"
    end
  end

  @doc "Build a validated event, returning `{:ok, event}` or `{:error, reason}`."
  @spec build(String.t(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def build(type, attrs \\ [])

  def build(type, attrs) when is_list(attrs), do: build(type, Map.new(attrs))

  def build(type, attrs) when is_binary(type) and is_map(attrs) do
    with :ok <- validate_type(type),
         {:ok, session_id} <- optional_binary(attrs, :session_id),
         {:ok, run_id} <- optional_binary(attrs, :run_id),
         :ok <- require_session_or_run(session_id, run_id),
         {:ok, payload} <- validate_payload(Map.get(attrs, :payload, %{})),
         {:ok, occurred_at} <- validate_datetime(Map.get(attrs, :occurred_at, DateTime.utc_now())) do
      {:ok,
       %__MODULE__{
         event_id: Map.get(attrs, :event_id) || Ecto.UUID.generate(),
         run_id: run_id,
         session_id: session_id,
         sequence: Map.get(attrs, :sequence) || System.unique_integer([:positive, :monotonic]),
         type: type,
         schema_version: Map.get(attrs, :schema_version, @schema_version),
         occurred_at: occurred_at,
         payload: payload,
         causation_id: Map.get(attrs, :causation_id),
         correlation_id: Map.get(attrs, :correlation_id) || session_id || run_id
       }}
    end
  end

  def build(_type, _attrs), do: {:error, :invalid_attrs}

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec known_types() :: [String.t()]
  def known_types, do: @known_types

  @spec session_terminal_types() :: [String.t()]
  def session_terminal_types, do: @session_terminal_types

  @spec run_lifecycle_types() :: [String.t()]
  def run_lifecycle_types, do: @run_lifecycle_types

  @spec session_terminal?(t() | String.t()) :: boolean()
  def session_terminal?(%__MODULE__{type: type}), do: session_terminal?(type)
  def session_terminal?(type) when is_binary(type), do: type in @session_terminal_types

  @spec run_lifecycle?(t() | String.t()) :: boolean()
  def run_lifecycle?(%__MODULE__{type: type}), do: run_lifecycle?(type)
  def run_lifecycle?(type) when is_binary(type), do: type in @run_lifecycle_types

  @spec critical_run?(t() | String.t()) :: boolean()
  def critical_run?(%__MODULE__{type: type}), do: critical_run?(type)
  def critical_run?(type) when is_binary(type), do: MapSet.member?(@critical_run_types, type)

  @spec turn_complete?(t() | String.t()) :: boolean()
  def turn_complete?(%__MODULE__{type: type}), do: turn_complete?(type)
  def turn_complete?(type) when is_binary(type), do: type in @turn_types

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "event_id" => event.event_id,
      "run_id" => event.run_id,
      "session_id" => event.session_id,
      "sequence" => event.sequence,
      "type" => event.type,
      "schema_version" => event.schema_version,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "payload" => event.payload,
      "causation_id" => event.causation_id,
      "correlation_id" => event.correlation_id
    }
  end

  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    type = Map.get(map, "type") || Map.get(map, :type)

    attrs = %{
      event_id: Map.get(map, "event_id") || Map.get(map, :event_id),
      run_id: Map.get(map, "run_id") || Map.get(map, :run_id),
      session_id: Map.get(map, "session_id") || Map.get(map, :session_id),
      sequence: Map.get(map, "sequence") || Map.get(map, :sequence),
      schema_version: Map.get(map, "schema_version") || Map.get(map, :schema_version),
      occurred_at: parse_datetime(Map.get(map, "occurred_at") || Map.get(map, :occurred_at)),
      payload: Map.get(map, "payload") || Map.get(map, :payload) || %{},
      causation_id: Map.get(map, "causation_id") || Map.get(map, :causation_id),
      correlation_id: Map.get(map, "correlation_id") || Map.get(map, :correlation_id)
    }

    if is_binary(type) do
      build(type, attrs)
    else
      {:error, :missing_type}
    end
  end

  def from_map(_), do: {:error, :invalid_map}

  defp validate_type(type) when type in @known_types, do: :ok
  defp validate_type(_type), do: {:error, :unknown_type}

  defp require_session_or_run(session_id, run_id)
       when is_binary(session_id) or is_binary(run_id),
       do: :ok

  defp require_session_or_run(_session_id, _run_id), do: {:error, :missing_session_or_run}

  defp optional_binary(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, key}}
    end
  end

  defp validate_payload(payload) when is_map(payload), do: {:ok, payload}
  defp validate_payload(_), do: {:error, :invalid_payload}

  defp validate_datetime(%DateTime{} = dt), do: {:ok, dt}
  defp validate_datetime(_), do: {:error, :invalid_occurred_at}

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
