defmodule Synapsis.Workflow.State do
  @moduledoc """
  Pure value operations for state command semantic requests.

  The Machine retains original outgoing roots while source text uses ordinary
  JSON conversion. Reads import fresh graphs into the same version-1 heap.
  This module performs no IO, publication, caching or provenance restoration;
  those remain the trusted driver's responsibility.
  """

  alias Synapsis.Workflow.{JSON, Value}

  @doc "Retains one input root, or allocates a dense array for zero or many items."
  def cardinality([value], heap), do: {value, heap}
  def cardinality(items, heap), do: Value.array(items, heap)

  @doc "Returns source pretty JSON plus LF, including the root undefined spelling."
  def text(value, heap) do
    case JSON.pretty(value, heap) do
      {:ok, :undefined} -> {:ok, "undefined\n"}
      {:ok, text} -> {:ok, text <> "\n"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Imports decoded source text, with nil representing the source missing-file null."
  def decode(nil, heap), do: {:ok, %{"type" => "null"}, heap}
  def decode(text, heap), do: Value.decode_json(text, heap)

  @doc "Freshly imports before and compares source stable JSON against the original after."
  def diff(text, after_value, heap) do
    {:ok, before, heap} =
      case decode(text, heap) do
        {:ok, before, heap} -> {:ok, before, heap}
        {:error, _syntax_error} -> decode(nil, heap)
      end

    with {:ok, before_text} <- JSON.stable_stringify(before, heap),
         {:ok, after_text} <- JSON.stable_stringify(after_value, heap) do
      {:ok, before, before_text != after_text, heap}
    end
  end
end
