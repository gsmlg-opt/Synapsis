defmodule Synapsis.MusicGeneration.RequestKey do
  @moduledoc """
  Pure canonical keys for prepared music requests from OpenClaw 488631c.

  `build/1` accepts an atom-key map after the caller has normalized references,
  selected a provider and resolved a model. It preserves supplied UTF-8 strings,
  whitespace, reference order and duplicates. It performs no configuration,
  provider resolution, storage, task submission or native tool activation.

  The ten source music fields always appear in lexical order. Missing or nil
  optional values represent source `undefined`, including its unquoted spelling;
  they are not omitted or serialized as JSON null. Missing/nil `image_inputs`
  represents the prepared empty array. False and explicit empty strings survive.
  This closed prepared API does not represent generic source null, arbitrary
  objects, cycles, special types or lone UTF-16 surrogates.

  Positive integral durations round once to binary64 and use JavaScript number
  spelling. Existing workflow helpers supply only scalar JSON string escaping
  and numeric formatting, without executing a workflow or using its different
  container serialization rules.

  The canonical text is the source semantic key used by `TaskStatus`; the
  additional lowercase SHA256 digest is suitable for the host Store's separate
  request-key field. A digest does not replace canonical-text comparisons.
  """

  alias Synapsis.Workflow.{JSON, Number}

  @strings [:provider, :model, :lyrics, :format, :filename]

  @type key :: %{canonical: String.t(), digest: String.t()}

  @spec build(map()) :: {:ok, key()} | {:error, :invalid_request}
  def build(request) when is_map(request) do
    images = if is_nil(request[:image_inputs]), do: [], else: request[:image_inputs]

    with true <- utf8?(request[:prompt]),
         true <- Enum.all?(@strings, &(is_nil(request[&1]) or utf8?(request[&1]))),
         true <- is_nil(request[:instrumental]) or is_boolean(request[:instrumental]),
         true <- is_list(images) and Enum.all?(images, &utf8?/1),
         {:ok, duration} <- duration(request[:duration_seconds]) do
      fields = [
        {"durationSeconds", duration},
        {"filename", optional_string(request[:filename])},
        {"format", optional_string(request[:format])},
        {"imageInputs", ["[", Enum.intersperse(Enum.map(images, &quote_string/1), ","), "]"]},
        {"instrumental", boolean(request[:instrumental])},
        {"lyrics", optional_string(request[:lyrics])},
        {"model", optional_string(request[:model])},
        {"prompt", quote_string(request[:prompt])},
        {"provider", optional_string(request[:provider])},
        {"tool", "\"music_generate\""}
      ]

      canonical =
        [
          "{",
          Enum.intersperse(
            Enum.map(fields, fn {key, value} -> ["\"", key, "\":", value] end),
            ","
          ),
          "}"
        ]
        |> IO.iodata_to_binary()

      digest = :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
      {:ok, %{canonical: canonical, digest: digest}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def build(_), do: {:error, :invalid_request}

  defp utf8?(value), do: is_binary(value) and String.valid?(value)

  defp optional_string(nil), do: "undefined"
  defp optional_string(value), do: quote_string(value)

  defp quote_string(value) do
    {:ok, text} = JSON.stringify(%{"type" => "string", "value" => value}, %{})
    text
  end

  defp boolean(nil), do: "undefined"
  defp boolean(true), do: "true"
  defp boolean(false), do: "false"

  defp duration(nil), do: {:ok, "undefined"}

  defp duration(value) when is_number(value) do
    tagged = Number.from_native(value)

    case Number.finite(tagged) do
      {:ok, number} when number > 0 ->
        if trunc(number) == number,
          do: {:ok, Number.string(tagged)},
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp duration(_), do: {:error, :invalid_request}
end
