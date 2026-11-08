defmodule Synapsis.Part.DeliveredImage do
  @moduledoc """
  Delivered image artifact authored by the host in an assistant message.

  Carries only the portable descriptor, public delivery reference and optional
  display name. Stored bytes, host paths and generation ownership stay outside
  the message. Provider history uses the bounded textual `summary/1`.
  """

  defstruct [:descriptor, :delivery, :name]

  @type t :: %__MODULE__{
          descriptor: %{String.t() => String.t() | non_neg_integer()},
          delivery: %{String.t() => String.t() | pos_integer()},
          name: String.t() | nil
        }

  @summary_field_bytes 320

  @doc "Summarizes public image identity in valid UTF-8 text of at most 2048 bytes."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{descriptor: descriptor, delivery: delivery, name: name}) do
    "Delivered image: #{summary_field(name || "image")}\n" <>
      "URI: #{summary_field(descriptor["uri"])}\n" <>
      "MIME: #{summary_field(descriptor["mime_type"])}\n" <>
      "Delivery: v#{summary_field(delivery["version"])} " <>
      "#{summary_field(delivery["session_id"])}/#{summary_field(delivery["id"])}"
  end

  defp summary_field(value) do
    text = to_string(value)

    if byte_size(text) <= @summary_field_bytes do
      text
    else
      text
      |> binary_part(0, @summary_field_bytes - 3)
      |> complete_utf8()
      |> Kernel.<>("...")
    end
  end

  defp complete_utf8(text) do
    if String.valid?(text),
      do: text,
      else: text |> binary_part(0, byte_size(text) - 1) |> complete_utf8()
  end
end
