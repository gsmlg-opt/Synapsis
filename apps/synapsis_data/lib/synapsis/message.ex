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

  defp decode_turn(turn, session_id) do
    %__MODULE__{
      role: fetch(turn, :role),
      token_count: fetch(turn, :token_count) || 0,
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
