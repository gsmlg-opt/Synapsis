defmodule Synapsis.Message do
  @moduledoc """
  Message entity — a single turn in a conversation.

  ADR-006 C4: an `embedded_schema` (no DB table). The durable copy of a session's
  messages lives in the node-local Concord store as ordered `turns/<n>` entries
  (see `Synapsis.Session.Store`). This struct is the in-memory shape; the live
  authority during a turn is the session process.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Synapsis.Session.Store

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  embedded_schema do
    field(:role, :string)
    field(:parts, {:array, Synapsis.Part}, default: [])
    field(:token_count, :integer, default: 0)
    field(:session_id, :binary_id)
    field(:inserted_at, :utc_datetime_usec)
  end

  @valid_roles ~w(user assistant system)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:id, :role, :parts, :token_count, :session_id])
    |> validate_required([:role, :session_id])
    |> validate_inclusion(:role, @valid_roles)
  end

  @doc """
  List all messages for a session, ordered, from the durable Concord turns.

  Decodes each `turns/<n>` entry (written by `Snapshot.encode_message/1`) back
  into a `%Message{}`. Returns `[]` when the session has no durable snapshot.
  """
  @spec list_by_session(String.t()) :: [%__MODULE__{}]
  def list_by_session(session_id) when is_binary(session_id) do
    case Store.list_turns(session_id) do
      {:ok, turns} -> Enum.map(turns, &decode_turn(&1, session_id))
      _ -> []
    end
  end

  @doc """
  Append a message to a session's durable turns. Accepts a `%Message{}` or an
  attrs map; assigns an id/timestamp when missing. Returns `{:ok, message}`.
  """
  @spec append(String.t(), %__MODULE__{} | map()) :: {:ok, %__MODULE__{}}
  def append(session_id, %__MODULE__{} = message) do
    message = ensure_identity(%{message | session_id: session_id})
    :ok = Store.replace_turns(session_id, encode_all(list_by_session(session_id) ++ [message]))
    {:ok, message}
  end

  def append(session_id, attrs) when is_map(attrs) do
    append(session_id, struct(__MODULE__, atomize(attrs)))
  end

  @doc "Replace a session's entire message list (used by compact/fork/share)."
  @spec persist_list(String.t(), [%__MODULE__{}]) :: :ok
  def persist_list(session_id, messages) when is_list(messages) do
    Store.replace_turns(session_id, encode_all(messages))
  end

  @doc "Update a single message (matched by id) within its session's turns."
  @spec update_message(%__MODULE__{}) :: {:ok, %__MODULE__{}}
  def update_message(%__MODULE__{id: id, session_id: session_id} = message)
      when is_binary(id) and is_binary(session_id) do
    updated =
      session_id
      |> list_by_session()
      |> Enum.map(fn m -> if m.id == id, do: message, else: m end)

    :ok = persist_list(session_id, updated)
    {:ok, message}
  end

  @doc "Encode a `%Message{}` into a durable turn map (id-stamped)."
  def encode(%__MODULE__{} = message) do
    %{
      id: message.id,
      role: message.role,
      token_count: message.token_count || 0,
      inserted_at: message.inserted_at,
      parts: Enum.map(message.parts || [], &encode_part/1)
    }
  end

  defp encode_all(messages), do: Enum.map(messages, &encode/1)

  defp ensure_identity(%__MODULE__{} = m) do
    %{
      m
      | id: m.id || Ecto.UUID.generate(),
        inserted_at: m.inserted_at || DateTime.utc_now()
    }
  end

  defp atomize(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} -> {String.to_existing_atom(to_string(k)), v}
    end)
  rescue
    _ -> attrs
  end

  defp encode_part(%Synapsis.Part.Text{content: content}),
    do: %{type: "text", text: content || ""}

  defp encode_part(%Synapsis.Part.ToolUse{tool: name, tool_use_id: id, input: input}),
    do: %{type: "tool_use", id: id, name: name, input: input || %{}}

  defp encode_part(%Synapsis.Part.ToolResult{tool_use_id: id, content: content, is_error: err}),
    do: %{type: "tool_result", tool_use_id: id, content: content || "", is_error: err || false}

  defp encode_part(%Synapsis.Part.Image{media_type: mt}),
    do: %{type: "image", media_type: mt}

  defp encode_part(other), do: %{type: "unknown", raw: inspect(other)}

  defp decode_turn(turn, session_id) do
    %__MODULE__{
      id: fetch(turn, :id),
      role: fetch(turn, :role),
      token_count: fetch(turn, :token_count) || 0,
      inserted_at: fetch(turn, :inserted_at),
      session_id: session_id,
      parts: turn |> fetch(:parts) |> List.wrap() |> Enum.map(&decode_part/1)
    }
  end

  defp decode_part(%{type: "text"} = p), do: %Synapsis.Part.Text{content: fetch(p, :text) || ""}

  defp decode_part(%{type: "tool_use"} = p),
    do: %Synapsis.Part.ToolUse{
      tool: fetch(p, :name),
      tool_use_id: fetch(p, :id),
      input: fetch(p, :input) || %{}
    }

  defp decode_part(%{type: "tool_result"} = p),
    do: %Synapsis.Part.ToolResult{
      tool_use_id: fetch(p, :tool_use_id),
      content: fetch(p, :content) || "",
      is_error: fetch(p, :is_error) || false
    }

  defp decode_part(%{type: "image"} = p),
    do: %Synapsis.Part.Image{media_type: fetch(p, :media_type)}

  defp decode_part(_other), do: %Synapsis.Part.Text{content: ""}

  # Concord round-trips atom-keyed maps, but tolerate string keys defensively.
  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
