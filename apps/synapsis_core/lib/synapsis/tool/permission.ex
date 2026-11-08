defmodule Synapsis.Tool.Permission do
  @moduledoc """
  Shared session permission configuration and persistence.

  Native tool authorization belongs to the admitted runtime policy. Legacy
  Registry-based invocation checks and tool-level lookup APIs are retired.
  """

  alias Synapsis.Tool.Permission.SessionConfig

  @permission_modes ~w(yolo ask restrict)

  @doc """
  Load a `SessionConfig` for the given session ID.

  Returns default config when `session_id` is nil or no row exists.
  """
  @spec session_config(binary() | nil) :: SessionConfig.t()
  def session_config(nil), do: SessionConfig.default()

  def session_config(session_id) do
    case Synapsis.Session.Store.get_value(session_id, "permission", nil) do
      nil ->
        %SessionConfig{SessionConfig.default() | session_id: session_id}

      map when is_map(map) ->
        SessionConfig.from_db(struct(Synapsis.SessionPermission, map))
    end
  rescue
    _e -> %SessionConfig{SessionConfig.default() | session_id: session_id}
  catch
    :exit, _ ->
      %SessionConfig{SessionConfig.default() | session_id: session_id}
  end

  @doc """
  Update session permission configuration with one revision-fenced write.

  `attrs` is a canonical atom-key map matching `SessionPermission` fields
  (`:mode`, `:allow_read`, `:allow_write`, `:allow_execute`, `:allow_destructive`,
  `:tool_overrides`, `:tool_contract_version`). Existing raw fields are preserved;
  the returned struct is a projection, not an exact persisted-value receipt.

  One requested five-second budget covers snapshot, changeset and CAS. Read
  errors propagate; malformed persisted records return `:invalid_permission_record`.
  Exhaustion before dispatch returns `:timeout`. A dispatched CAS preserves
  acknowledged success or conflict; all other outcomes are `:unknown_outcome`
  and must not be automatically retried. This is not a hard interruption or
  no-late-write guarantee, and known late success remains success.
  """
  @spec update_config(binary(), map()) ::
          {:ok, Synapsis.SessionPermission.t()} | {:error, term()}
  def update_config(session_id, attrs) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    with :ok <- update_config_input(session_id, attrs),
         {:ok, timeout} <- update_config_remaining(deadline),
         {:ok, raw, current, revision} <- update_config_snapshot(session_id, timeout),
         {:ok, changeset, record} <-
           update_config_changeset(current, Map.put(attrs, :session_id, session_id)),
         replacement =
           if(is_nil(raw),
             do: Map.from_struct(record),
             else: Map.merge(raw, changeset.changes)
           ),
         {:ok, timeout} <- update_config_remaining(deadline) do
      update_config_put(session_id, replacement, revision, record, timeout)
    end
  end

  defp update_config_input(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    if not is_struct(attrs) and Enum.all?(Map.keys(attrs), &is_atom/1),
      do: :ok,
      else: {:error, :invalid_input}
  end

  defp update_config_input(_, _), do: {:error, :invalid_input}

  defp update_config_snapshot(session_id, timeout) do
    case Synapsis.Session.Store.value_snapshot(session_id, "permission", timeout: timeout) do
      :not_found ->
        {:ok, nil, %Synapsis.SessionPermission{}, 0}

      {:ok, %{value: raw, revision: revision}} when is_integer(revision) and revision > 0 ->
        fields = Synapsis.SessionPermission.__schema__(:fields)

        if is_map(raw) and not is_struct(raw) and
             Map.get(raw, :session_id) === session_id and
             not Enum.any?(fields, &Map.has_key?(raw, Atom.to_string(&1))) do
          {:ok, raw, struct(Synapsis.SessionPermission, raw), revision}
        else
          {:error, :invalid_permission_record}
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_permission_record}
    end
  end

  defp update_config_changeset(current, attrs) do
    changeset = Synapsis.SessionPermission.changeset(current, attrs)

    if changeset.valid?,
      do: {:ok, changeset, Ecto.Changeset.apply_changes(changeset)},
      else: {:error, changeset}
  rescue
    _ -> {:error, :invalid_input}
  end

  defp update_config_remaining(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining > 0, do: {:ok, remaining}, else: {:error, :timeout}
  end

  defp update_config_put(session_id, replacement, revision, record, timeout) do
    case Synapsis.Session.Store.put_value_if_revision(
           session_id,
           "permission",
           replacement,
           revision,
           timeout: timeout
         ) do
      :ok -> {:ok, record}
      {:error, :conflict} -> {:error, :conflict}
      _ -> {:error, :unknown_outcome}
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  @doc "Return the agent-level permission modes accepted by the UI and schema."
  @spec valid_permission_modes() :: [String.t()]
  def valid_permission_modes, do: @permission_modes

  @doc "Map an agent permission mode to a session permission config."
  @spec config_for_mode(String.t() | atom() | nil) :: map()
  def config_for_mode(mode) do
    case normalize_permission_mode(mode) do
      "yolo" ->
        %{
          mode: :autonomous,
          allow_read: :allow,
          allow_write: :allow,
          allow_execute: :allow,
          allow_destructive: :allow,
          tool_overrides: %{}
        }

      "restrict" ->
        %{
          mode: :interactive,
          allow_read: :ask,
          allow_write: :ask,
          allow_execute: :ask,
          allow_destructive: :ask,
          tool_overrides: %{}
        }

      _ask ->
        # C-006: read allow; write/execute require approval; destructive deny by default.
        %{
          mode: :interactive,
          allow_read: :allow,
          allow_write: :ask,
          allow_execute: :ask,
          allow_destructive: :deny,
          tool_overrides: %{}
        }
    end
  end

  @doc """
  Parse an override string like `"bash(git *)"` into a map.
  """
  @spec parse_override(String.t()) :: %{tool: String.t(), pattern: String.t()}
  def parse_override(str) when is_binary(str) do
    case Regex.run(~r/^(\w+)\((.+)\)$/, str) do
      [_, tool, pattern] -> %{tool: tool, pattern: pattern}
      nil -> %{tool: str, pattern: "*"}
    end
  end

  defp normalize_permission_mode(mode) when mode in [nil, ""], do: "yolo"

  defp normalize_permission_mode(mode) when is_atom(mode),
    do: mode |> Atom.to_string() |> normalize_permission_mode()

  defp normalize_permission_mode(mode) when mode in @permission_modes, do: mode
  defp normalize_permission_mode(_mode), do: "ask"
end
