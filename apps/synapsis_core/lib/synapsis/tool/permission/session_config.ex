defmodule Synapsis.Tool.Permission.SessionConfig do
  @moduledoc """
  Per-session permission configuration struct.

  Fields:
  - `session_id` — the session this config belongs to (nil for defaults)
  - `mode` — `:interactive` or `:autonomous`
  - `allow_read` — whether read-level tools are allowed (always true)
  - `allow_write` — whether write-level tools are allowed
  - `allow_execute` — whether execute-level tools are allowed
  - `allow_destructive` — `:allow`, `:deny`, or `:ask` for destructive tools
  - `overrides` — list of per-tool glob overrides
  """

  @type t :: %__MODULE__{
          session_id: binary() | nil,
          mode: :interactive | :autonomous,
          allow_read: boolean(),
          allow_write: boolean() | :ask,
          allow_execute: boolean() | :ask,
          allow_destructive: :allow | :deny | :ask,
          overrides: list()
        }

  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    mode: :interactive,
    allow_read: true,
    allow_write: true,
    allow_execute: false,
    allow_destructive: :ask,
    overrides: []
  ]

  @doc "Returns a default config with nil session_id."
  @spec default :: t()
  def default do
    %__MODULE__{session_id: nil}
  end

  @doc "Build a SessionConfig from a `Synapsis.SessionPermission` DB row."
  @spec from_db(Synapsis.SessionPermission.t()) :: t()
  def from_db(%Synapsis.SessionPermission{} = row) do
    overrides = parse_overrides(row.tool_overrides)

    %__MODULE__{
      session_id: row.session_id,
      mode: row.mode,
      allow_read: true,
      allow_write: row.allow_write,
      allow_execute: row.allow_execute,
      allow_destructive: row.allow_destructive,
      overrides: overrides
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp parse_overrides(nil), do: []
  defp parse_overrides(overrides) when is_map(overrides), do: map_to_override_list(overrides)
  defp parse_overrides(overrides) when is_list(overrides), do: overrides
  defp parse_overrides(_), do: []

  defp map_to_override_list(map) do
    Enum.flat_map(map, fn
      {tool_spec, decision} when is_binary(tool_spec) ->
        parsed = Synapsis.Tool.Permission.parse_override(tool_spec)
        [Map.put(parsed, :decision, normalize_decision(decision))]

      _ ->
        []
    end)
  end

  defp normalize_decision("allowed"), do: :allowed
  defp normalize_decision("denied"), do: :denied
  defp normalize_decision("requires_approval"), do: :requires_approval
  defp normalize_decision(atom) when is_atom(atom), do: atom
  defp normalize_decision(_), do: :requires_approval
end
