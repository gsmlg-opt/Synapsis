defmodule Synapsis.Workflow.Value do
  @moduledoc """
  Pure, JSON-serializable values for workflow interpreter state.

  Every value has an explicit string `type`: `undefined`, `null`, `boolean`,
  `string`, `number`, or `reference`. Numbers contain their binary64 `bits` as
  sixteen lowercase hexadecimal digits, preserving signed zero and avoiding
  arbitrary-precision integer semantics. JSON decimal import rounds to binary64,
  including signed Infinity on overflow and signed zero on underflow. Trusted
  tagged numbers can also retain every NaN sign and payload; JSON has no NaN literal.
  Trusted strings use UTF-8 `value` when well-formed, or canonical base64
  `utf16le` without `value` when their UTF-16 code units contain lone surrogates.
  Both forms retain their exact code units through tagged JSON storage and
  `Workflow.JSON` output, the schema/template compute helper and Machine runtime
  string consumers. JSON import and object keys preserve arbitrary UTF-16 units;
  the public Segment decoded envelope is a separate boundary.

  Version 1 heaps contain `next_id` and a `nodes` map. References use heap-local
  string IDs; nodes contain either dense array `items` or object `keys` and
  `fields`. Lone-bearing keys use canonical string tags in `keys` and an optional
  `fields_utf16le` map keyed by their canonical base64 bytes. Ordinary-only objects
  retain their original shape. Keys retain insertion order separately from fields.
  Save the heap together with every root reference to preserve shared aliases
  through an ordinary JSON snapshot. IDs are internal graph locators, not public
  persisted record identities.

  Constructors and accessors consume trusted tagged values belonging to the
  supplied heap. They do not validate imported snapshots or implement general
  JavaScript property access, prototypes, descriptors, sparse arrays, or public
  JSON stringification. This module performs no workflow execution, persistence,
  or process operations.
  """

  alias Synapsis.Workflow.Number

  @json_whitespace ~r/\A[ \t\r\n]*\z/

  @doc "Creates an empty version 1 heap."
  @spec new() :: map()
  def new, do: %{"version" => 1, "next_id" => 1, "nodes" => %{}}

  @doc "Returns complete new or changed nodes without replacing stable reference IDs."
  @spec heap_delta(map(), map()) :: %{upsert: map(), next_id: integer()}
  def heap_delta(before_heap, after_heap) do
    upsert =
      Map.reject(after_heap["nodes"], fn {id, node} ->
        Map.fetch(before_heap["nodes"], id) == {:ok, node}
      end)

    %{upsert: upsert, next_id: after_heap["next_id"]}
  end

  @doc "Returns the undefined value, distinct from JSON null."
  @spec undefined() :: map()
  def undefined, do: %{"type" => "undefined"}

  @doc "Constructs a canonical trusted string from an even-length UTF-16LE binary."
  @spec from_utf16le(binary()) :: map()
  def from_utf16le(raw) when is_binary(raw) and rem(byte_size(raw), 2) == 0 do
    case :unicode.characters_to_binary(raw, {:utf16, :little}, :utf8) do
      string when is_binary(string) -> %{"type" => "string", "value" => string}
      _ill_formed -> %{"type" => "string", "utf16le" => Base.encode64(raw)}
    end
  end

  @doc "Returns the exact UTF-16LE bytes of a trusted canonical string."
  @spec to_utf16le(map()) :: binary()
  def to_utf16le(%{"type" => "string", "value" => string}) when is_binary(string),
    do: :unicode.characters_to_binary(string, :utf8, {:utf16, :little})

  def to_utf16le(%{"type" => "string", "utf16le" => encoded}) when is_binary(encoded),
    do: Base.decode64!(encoded)

  @doc """
  Imports one complete UTF-8 JSON value into the supplied heap.

  A lexical adapter masks surrogate Unicode escapes inside quoted tokens and
  records their exact units and positions. The built-in decoder validates the
  complete sanitized JSON and retains ordered pairs and numeric tokens. String
  units are restored by token position before importing or replacing duplicates.
  The zero-token adapter retains the sign of `-0` and `-0e...`; the native decoder
  remains the JSON grammar and number authority.

  Duplicate fields replace their value without changing their first insertion
  position. JSON grammar errors and trailing data return tagged errors. Valid
  decimal numbers use binary64 rounding across the full numeric range.
  """
  @spec decode_json(binary(), map()) :: {:ok, map(), map()} | {:error, term()}
  def decode_json(binary, heap \\ new())

  def decode_json(binary, heap) when is_binary(binary) do
    {sanitized, patches} = mask_surrogates(binary)

    with {:ok, original} <- decode_complete(sanitized),
         {:ok, decoded} <- signed_zero_ast(sanitized, original) do
      {decoded, []} = restore_strings(decoded, patches)
      {value, heap} = import_value(decoded, heap)
      {:ok, value, heap}
    end
  end

  def decode_json(_binary, _heap), do: {:error, :invalid_json_input}

  @doc "Allocates a dense array while preserving the supplied value references."
  @spec array([map()], map()) :: {map(), map()}
  def array(items, heap) when is_list(items) do
    allocate(%{"type" => "array", "items" => items}, heap)
  end

  @doc "Returns a selector as a canonical trusted string."
  @spec key_string(binary() | map()) :: map()
  def key_string(key) when is_binary(key), do: %{"type" => "string", "value" => key}
  def key_string(%{"type" => "string"} = key), do: from_utf16le(to_utf16le(key))

  @doc "Returns a canonical array index, or nil for an ordinary property name."
  @spec key_index(binary() | map()) :: non_neg_integer() | nil
  def key_index(key) do
    case key_string(key) do
      %{"value" => key} when byte_size(key) <= 10 ->
        case Integer.parse(key) do
          {index, ""} when index >= 0 and index < 4_294_967_295 ->
            if Integer.to_string(index) == key, do: index

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc "Allocates an object from ordered fields; later duplicate values replace earlier ones."
  @spec object([{binary() | map(), map()}], map()) :: {map(), map()}
  def object(entries, heap) when is_list(entries) do
    object = %{"type" => "object", "keys" => [], "fields" => %{}}

    object =
      Enum.reduce(entries, object, fn {key, value}, object -> put_field(object, key, value) end)

    allocate(%{object | "keys" => Enum.reverse(object["keys"])}, heap)
  end

  @doc "Reads an object's own field, returning undefined when the key is absent."
  @spec object_get(map(), binary() | map(), map()) :: map()
  def object_get(reference, key, heap) do
    {namespace, name, _key} = key_location(key)
    %{"type" => "object"} = object = node(reference, heap)
    object |> Map.get(namespace, %{}) |> Map.get(name, undefined())
  end

  @doc "Reads a required own field using the same selector equality as object_get."
  @spec object_fetch!(map(), binary() | map(), map()) :: map()
  def object_fetch!(reference, key, heap) do
    {namespace, name, _key} = key_location(key)
    %{"type" => "object"} = object = node(reference, heap)
    object |> Map.get(namespace, %{}) |> Map.fetch!(name)
  end

  @doc "Updates an object's field in the heap without changing its reference identity."
  @spec object_put(map(), binary() | map(), map(), map()) :: map()
  def object_put(%{"type" => "reference", "id" => id} = reference, key, value, heap) do
    %{"type" => "object", "keys" => keys} = object = node(reference, heap)
    object = put_field(%{object | "keys" => []}, key, value)
    object = %{object | "keys" => keys ++ object["keys"]}
    %{heap | "nodes" => Map.put(heap["nodes"], id, object)}
  end

  @doc "Returns own keys in ordinary-object order: array indices, then insertion-ordered strings."
  @spec object_keys(map(), map()) :: [binary() | map()]
  def object_keys(reference, heap) do
    %{"type" => "object", "keys" => keys} = node(reference, heap)
    {indices, ordinary} = Enum.split_with(keys, &(not is_nil(key_index(&1))))
    Enum.sort_by(indices, &key_index/1) ++ ordinary
  end

  defp key_location(key) do
    case key_string(key) do
      %{"value" => name} -> {"fields", name, name}
      %{"utf16le" => encoded} = key -> {"fields_utf16le", encoded, key}
    end
  end

  # Constructors prepend keys; object_put supplies an empty list to collect only
  # a newly inserted key before appending it to the existing insertion order.
  defp put_field(object, key, value) do
    {namespace, name, key} = key_location(key)
    fields = Map.get(object, namespace, %{})
    keys = if Map.has_key?(fields, name), do: object["keys"], else: [key | object["keys"]]
    object |> Map.put("keys", keys) |> Map.put(namespace, Map.put(fields, name, value))
  end

  @doc "Returns the tagged items of a dense array."
  @spec array_items(map(), map()) :: [map()]
  def array_items(reference, heap) do
    %{"type" => "array", "items" => items} = node(reference, heap)
    items
  end

  defp decoders do
    [
      integer: &{:number, &1},
      float: &{:number, &1},
      array_finish: fn items, previous -> {{:array, Enum.reverse(items)}, previous} end,
      object_finish: fn entries, previous -> {{:object, Enum.reverse(entries)}, previous} end
    ]
  end

  defp decode_complete(binary) do
    case JSON.decode(binary, :ok, decoders()) do
      {decoded, :ok, rest} ->
        if Regex.match?(@json_whitespace, rest),
          do: {:ok, decoded},
          else: {:error, :trailing_json_data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signed_zero_ast(binary, original) do
    {normalized, changed?} = normalize_zero(binary, true, [], false)
    if changed?, do: decode_complete(normalized), else: {:ok, original}
  end

  # This adapter only sees already-valid JSON. Rewriting a zero scalar with a
  # fractional component avoids the decoder's sign-dropping integer/exp paths.
  defp normalize_zero(<<>>, _value_start?, parts, changed?) do
    {parts |> Enum.reverse() |> IO.iodata_to_binary(), changed?}
  end

  defp normalize_zero(<<?", rest::binary>>, _value_start?, parts, changed?) do
    {quoted, rest} = quoted_string(rest, [<<?">>])
    normalize_zero(rest, false, [quoted | parts], changed?)
  end

  defp normalize_zero(<<"-0", rest::binary>>, true, parts, changed?) do
    if zero_token_end?(rest) do
      normalize_zero(rest, false, ["-0.0" | parts], true)
    else
      normalize_zero(<<"0", rest::binary>>, false, ["-" | parts], changed?)
    end
  end

  defp normalize_zero(<<byte, rest::binary>>, _value_start?, parts, changed?) do
    value_start? = byte in [?[, ?:, ?,, ?\s, ?\t, ?\r, ?\n]
    normalize_zero(rest, value_start?, [<<byte>> | parts], changed?)
  end

  defp zero_token_end?(<<>>), do: true

  defp zero_token_end?(<<byte, _rest::binary>>),
    do: byte in [?], ?}, ?,, ?\s, ?\t, ?\r, ?\n, ?e, ?E]

  defp quoted_string(<<?\\, escaped, rest::binary>>, parts),
    do: quoted_string(rest, [<<?\\, escaped>> | parts])

  defp quoted_string(<<?", rest::binary>>, parts),
    do: {[<<?">> | parts] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp quoted_string(<<byte, rest::binary>>, parts),
    do: quoted_string(rest, [<<byte>> | parts])

  # This scanner identifies string tokens only; native JSON still validates all
  # syntax. Every masked escape occupies exactly one decoded UTF-16 unit, so
  # patches use positions rather than any sentinel value or decoded key name.
  defp mask_surrogates(binary), do: mask_tokens(binary, [], [])

  defp mask_tokens(<<>>, parts, patches),
    do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(patches)}

  defp mask_tokens(<<?", rest::binary>>, parts, patches) do
    {token, rest, token_patches} = mask_string(rest, [<<?">>], [], 0)
    mask_tokens(rest, [token | parts], [token_patches | patches])
  end

  defp mask_tokens(<<byte, rest::binary>>, parts, patches),
    do: mask_tokens(rest, [<<byte>> | parts], patches)

  defp mask_string(<<>>, parts, patches, _offset),
    do: {parts |> Enum.reverse() |> IO.iodata_to_binary(), <<>>, Enum.reverse(patches)}

  defp mask_string(<<?", rest::binary>>, parts, patches, _offset),
    do: {[<<?">> | parts] |> Enum.reverse() |> IO.iodata_to_binary(), rest, Enum.reverse(patches)}

  defp mask_string(<<?\\, ?u, digits::binary-size(4), rest::binary>>, parts, patches, offset) do
    case Integer.parse(digits, 16) do
      {unit, ""} when unit in 0xD800..0xDFFF ->
        mask_string(rest, ["\\u0000" | parts], [{offset, unit} | patches], offset + 1)

      _ ->
        mask_string(rest, [<<?\\, ?u, digits::binary>> | parts], patches, offset + 1)
    end
  end

  defp mask_string(<<?\\, escaped, rest::binary>>, parts, patches, offset),
    do: mask_string(rest, [<<?\\, escaped>> | parts], patches, offset + 1)

  defp mask_string(<<codepoint::utf8, rest::binary>>, parts, patches, offset) do
    width = if codepoint > 0xFFFF, do: 2, else: 1
    mask_string(rest, [<<codepoint::utf8>> | parts], patches, offset + width)
  end

  defp mask_string(<<byte, rest::binary>>, parts, patches, offset),
    do: mask_string(rest, [<<byte>> | parts], patches, offset + 1)

  defp restore_strings(value, [patch | patches]) when is_binary(value),
    do: {restore_string(value, patch), patches}

  defp restore_strings({:array, items}, patches) do
    {items, patches} = Enum.map_reduce(items, patches, &restore_strings/2)
    {{:array, items}, patches}
  end

  defp restore_strings({:object, entries}, patches) do
    {entries, patches} =
      Enum.map_reduce(entries, patches, fn {key, value}, patches ->
        {key, patches} = restore_strings(key, patches)
        {value, patches} = restore_strings(value, patches)
        {{key, value}, patches}
      end)

    {{:object, entries}, patches}
  end

  defp restore_strings(value, patches), do: {value, patches}

  defp restore_string(value, []), do: value

  defp restore_string(value, patches) do
    value
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> restore_units(patches, 0, [])
    |> from_utf16le()
  end

  defp restore_units(rest, [], _cursor, parts),
    do: [rest | parts] |> Enum.reverse() |> IO.iodata_to_binary()

  defp restore_units(raw, [{offset, unit} | patches], cursor, parts) do
    size = offset * 2 - cursor
    <<prefix::binary-size(size), _masked::little-16, rest::binary>> = raw
    restore_units(rest, patches, offset * 2 + 2, [<<unit::little-16>>, prefix | parts])
  end

  defp import_value(nil, heap), do: {%{"type" => "null"}, heap}

  defp import_value(value, heap) when is_boolean(value),
    do: {%{"type" => "boolean", "value" => value}, heap}

  defp import_value(value, heap) when is_binary(value),
    do: {%{"type" => "string", "value" => value}, heap}

  defp import_value(%{"type" => "string"} = value, heap), do: {value, heap}

  defp import_value({:number, lexeme}, heap) do
    {Number.from_decimal(lexeme), heap}
  end

  defp import_value({:array, items}, heap) do
    {values, heap} = Enum.map_reduce(items, heap, &import_value/2)
    array(values, heap)
  end

  defp import_value({:object, entries}, heap) do
    {fields, heap} =
      Enum.map_reduce(entries, heap, fn {key, value}, heap ->
        {value, heap} = import_value(value, heap)
        {{key, value}, heap}
      end)

    object(fields, heap)
  end

  defp allocate(value, %{"version" => 1, "next_id" => next, "nodes" => nodes} = heap) do
    id = Integer.to_string(next)
    reference = %{"type" => "reference", "id" => id}
    {reference, %{heap | "next_id" => next + 1, "nodes" => Map.put(nodes, id, value)}}
  end

  defp node(%{"type" => "reference", "id" => id}, %{"version" => 1, "nodes" => nodes}) do
    Map.fetch!(nodes, id)
  end
end
