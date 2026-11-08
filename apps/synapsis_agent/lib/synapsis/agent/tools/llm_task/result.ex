defmodule Synapsis.Agent.Tools.LLMTask.Result do
  @moduledoc """
  Decodes the JSON value returned by one isolated LLM task.

  Matches the pinned callback's ECMAScript boundary whitespace and optional
  whole-output JSON fence. Objects, arrays, scalars and null are returned intact;
  parsing never repairs output or requests another completion.

  An optional object schema is compiled per call by JSONSchex with the canonical
  Draft 2020-12 dialect and local-reference resolution. An omitted root `$schema`
  is supplied in a private copy; other declared root dialects are unsupported.
  No external loader, validator cache or default insertion is installed, and no
  format/content assertion option is supplied. Canonical format handling is
  annotation-only unless the schema explicitly selects a supported assertion
  vocabulary. Successful local-reference/applicator cases do not establish
  complete equivalence with the reference TypeBox validator: in particular, the
  reference specially asserts `uri`, unlike canonical format annotation behavior.

  This component performs no model selection, provider execution, provenance
  inference or tool registration. The caller retains those responsibilities.

  Presentation returns native pretty JSON text and the unchanged decoded value.
  Native object ordering, integer precision and number spelling follow Jason,
  not JavaScript JSON.stringify. Provider/model details are included only when
  explicitly supplied as caller-observed metadata; absent observation remains
  absent. Raw completion text, internal usage and locators are not presented.
  """

  alias Backplane.AgentRuntime.Error

  @dialect "https://json-schema.org/draft/2020-12/schema"

  # ECMAScript WhiteSpace and LineTerminator, also used by its non-Unicode /\s/.
  # Unicode-aware PCRE \s and String.trim/1 have different character sets.
  @whitespace ~S(\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF})
  @trim Regex.compile!("\\A[#{@whitespace}]+|[#{@whitespace}]+\\z", "u")
  @fence Regex.compile!(
           "\\A```(?:[jJ][sS][oO][nN])?[#{@whitespace}]*(.*?)[#{@whitespace}]*```\\z",
           "su"
         )

  @spec decode(String.t(), map() | nil) :: {:ok, term()} | {:error, Error.t()}
  def decode(text, schema \\ nil)

  def decode(text, schema) when is_binary(text) do
    with true <- String.valid?(text),
         {:ok, value} <- parse(text),
         :ok <- validate(schema, value) do
      {:ok, value}
    else
      false -> malformed_json()
      {:error, %Error{}} = error -> error
    end
  end

  def decode(_text, _schema), do: malformed_json()

  @spec present(term(), map()) :: {:ok, map()} | {:error, Error.t()}
  def present(value, observed_metadata \\ %{})

  def present(value, observed_metadata) when is_map(observed_metadata) do
    identity = Map.take(observed_metadata, [:provider, :model])

    with true <-
           Enum.all?(identity, fn {_key, id} ->
             is_binary(id) and id != "" and String.valid?(id)
           end),
         {:ok, content} <- Jason.encode(value, pretty: true),
         {:ok, ^value} <- Jason.decode(content) do
      {:ok, %{content: content, details: Map.put(identity, :json, value)}}
    else
      _ ->
        failure(:validation, "LLM task presentation requires JSON and observed identity metadata")
    end
  end

  def present(_value, _observed_metadata),
    do: failure(:validation, "LLM task presentation requires JSON and observed identity metadata")

  defp parse(text) do
    trimmed = trim(text)

    raw =
      case Regex.run(@fence, trimmed, capture: :all_but_first) do
        [json] -> trim(json)
        nil -> trimmed
      end

    case Jason.decode(raw) do
      {:ok, value} -> {:ok, value}
      {:error, _error} -> malformed_json()
    end
  end

  defp validate(nil, _value), do: :ok

  defp validate(%{"$schema" => dialect}, _value) when dialect != @dialect,
    do: failure(:unsupported_capability, "LLM task result schema dialect is unsupported")

  defp validate(schema, value) when is_map(schema) do
    case JSONSchex.compile(Map.put_new(schema, "$schema", @dialect)) do
      {:ok, compiled} ->
        case JSONSchex.validate(compiled, value) do
          :ok -> :ok
          {:error, _errors} -> failure(:malformed_result, "LLM JSON did not match schema")
        end

      {:error, _error} ->
        failure(:validation, "LLM task result schema is invalid")
    end
  end

  defp validate(_schema, _value),
    do: failure(:validation, "LLM task result schema must be an object")

  defp trim(text), do: Regex.replace(@trim, text, "")
  defp malformed_json, do: failure(:malformed_result, "LLM returned invalid JSON")
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
