defmodule Synapsis.Provider.StreamGuard do
  @moduledoc """
  Pure interception stage over streamed text bytes.

  The guard holds back `max_len - 1` bytes so bytes that could still
  complete a forbidden pattern are not emitted downstream.
  """

  defstruct [:pattern, :max_len, held: <<>>]

  @type t :: %__MODULE__{
          pattern: :binary.cp(),
          max_len: pos_integer(),
          held: binary()
        }

  @doc "Builds a stream guard from non-empty binary substring rules."
  @spec new([binary(), ...]) :: t()
  def new(rules) when is_list(rules) and rules != [] do
    %__MODULE__{
      pattern: :binary.compile_pattern(rules),
      max_len: rules |> Enum.map(&byte_size/1) |> Enum.max()
    }
  end

  @doc "Returns {:ok, emit_binary, guard} or {:violation, matched_rule}."
  @spec scan(t(), binary()) :: {:ok, binary(), t()} | {:violation, binary()}
  def scan(%__MODULE__{} = guard, chunk) when is_binary(chunk) do
    buffer = guard.held <> chunk

    case :binary.match(buffer, guard.pattern) do
      {pos, len} ->
        {:violation, binary_part(buffer, pos, len)}

      :nomatch ->
        keep = min(guard.max_len - 1, byte_size(buffer))
        emit_size = byte_size(buffer) - keep
        emit = binary_part(buffer, 0, emit_size)
        held = binary_part(buffer, emit_size, keep)

        {:ok, emit, %{guard | held: held}}
    end
  end

  @doc "Flushes held bytes at end of stream, or reports a tail violation."
  @spec finish(t()) :: {:ok, binary()} | {:violation, binary()}
  def finish(%__MODULE__{} = guard) do
    case :binary.match(guard.held, guard.pattern) do
      {pos, len} -> {:violation, binary_part(guard.held, pos, len)}
      :nomatch -> {:ok, guard.held}
    end
  end

  @doc """
  Redacts a matched rule for error payloads and logs. Rules often guard
  secrets, so only the byte length crosses the boundary.
  """
  @spec redact(binary()) :: String.t()
  def redact(rule) when is_binary(rule), do: "[redacted #{byte_size(rule)}-byte pattern]"
end
