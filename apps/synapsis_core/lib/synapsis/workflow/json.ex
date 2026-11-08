defmodule Synapsis.Workflow.JSON do
  @moduledoc """
  Public JSON conversion for trusted workflow values and their version 1 heap.

  Compact and two-space pretty output follow JavaScript JSON conversion within
  the trusted string, dense-array and own-object domain represented by
  `Workflow.Value`. Strings retain lone UTF-16 units as lowercase JSON escapes
  and valid surrogate pairs as Unicode. JSON import and object keys retain exact
  UTF-16 units. The schema/template compute helper and Machine runtime consumers
  support the `utf16le` string variant; the public Segment decoded envelope is a
  separate boundary.
  Public conversion omits undefined object fields, writes undefined array items
  as null and normalizes both zero signs. Stable output sorts ordinary keys by
  UTF-16 code units while preserving numeric index enumeration.

  `snapshot/2` is the stricter input-request boundary: require finite JSON values
  without undefined or cycles, then copy a new tree directly. Shared aliases
  become independent copies. Saving the original tagged roots and heap instead
  preserves aliases; that is a different operation.

  Finite numbers use exact binary64 rounding intervals and the shortest decimal
  coefficient, choosing the closest candidate and an even coefficient on ties.
  The latter is ECMAScript's stronger recommended selection guideline. Original
  numeric spelling is not retained. This module is not a general JavaScript VM,
  imported-heap validator, workflow executor or persistence adapter; prototypes,
  descriptors and sparse arrays are not represented.
  """

  import Bitwise

  alias Synapsis.Workflow.Value

  @max_finite 0x7FEF_FFFF_FFFF_FFFF
  @absolute_mask 0x7FFF_FFFF_FFFF_FFFF
  @fraction_mask 0x000F_FFFF_FFFF_FFFF

  @type encoded :: {:ok, binary() | :undefined} | {:error, term()}

  @doc "Encodes compact public JSON, or returns undefined for an undefined root."
  @spec stringify(map(), map()) :: encoded()
  def stringify(value, heap), do: render(value, heap, :compact)

  @doc "Encodes two-space pretty JSON without a final renderer newline."
  @spec pretty(map(), map()) :: encoded()
  def pretty(value, heap), do: render(value, heap, :pretty)

  @doc "Encodes recursively stable object keys using JavaScript UTF-16 ordering."
  @spec stable_stringify(map(), map()) :: encoded()
  def stable_stringify(value, heap), do: render(value, heap, :stable)

  @doc "Validates strict JSON values, then allocates a fresh tree in the same heap."
  @spec snapshot(map(), map()) :: {:ok, map(), map()} | {:error, term()}
  def snapshot(value, heap) do
    try do
      validate_snapshot(value, heap, MapSet.new())

      {copy, heap} = copy_snapshot(value, heap)
      {:ok, copy, heap}
    catch
      :throw, {:workflow_json, reason} -> {:error, reason}
    end
  end

  defp render(value, heap, mode) do
    try do
      case encode(value, heap, mode, 0, MapSet.new()) do
        :undefined -> {:ok, :undefined}
        text -> {:ok, IO.iodata_to_binary(text)}
      end
    catch
      :throw, {:workflow_json, reason} -> {:error, reason}
    end
  end

  defp encode(%{"type" => "undefined"}, _heap, _mode, _depth, _path), do: :undefined
  defp encode(%{"type" => "null"}, _heap, _mode, _depth, _path), do: "null"
  defp encode(%{"type" => "boolean", "value" => true}, _heap, _mode, _depth, _path), do: "true"
  defp encode(%{"type" => "boolean", "value" => false}, _heap, _mode, _depth, _path), do: "false"

  defp encode(%{"type" => "string", "value" => string}, _heap, _mode, _depth, _path)
       when is_binary(string),
       do: quote_string(string)

  defp encode(%{"type" => "string", "utf16le" => encoded} = value, _heap, _mode, _depth, _path)
       when is_binary(encoded),
       do: [?", quote_utf16(Value.to_utf16le(value)), ?"]

  defp encode(%{"type" => "number", "bits" => bits}, _heap, _mode, _depth, _path),
    do: encode_number(number_bits(bits))

  defp encode(%{"type" => "reference", "id" => id} = reference, heap, mode, depth, path)
       when is_binary(id) do
    path = enter_reference(id, path)

    case node(id, heap) do
      %{"type" => "array", "items" => items} when is_list(items) ->
        items =
          Enum.map(items, fn value ->
            case encode(value, heap, mode, depth + 1, path) do
              :undefined -> "null"
              encoded -> encoded
            end
          end)

        collection(items, "[", "]", mode, depth)

      %{"type" => "object", "fields" => fields} when is_map(fields) ->
        entries =
          reference
          |> object_keys(heap, mode)
          |> Enum.flat_map(fn key ->
            case encode(Value.object_fetch!(reference, key, heap), heap, mode, depth + 1, path) do
              :undefined -> []
              encoded -> [[quote_key(key), if(mode == :pretty, do: ": ", else: ":"), encoded]]
            end
          end)

        collection(entries, "{", "}", mode, depth)

      _ ->
        fail(:unsupported_node)
    end
  end

  defp encode(_value, _heap, _mode, _depth, _path), do: fail(:unsupported_value)

  defp collection([], open, close, _mode, _depth), do: [open, close]

  defp collection(items, open, close, :pretty, depth) do
    indent = String.duplicate("  ", depth + 1)

    [
      open,
      "\n",
      indent,
      Enum.intersperse(items, [",\n", indent]),
      "\n",
      String.duplicate("  ", depth),
      close
    ]
  end

  defp collection(items, open, close, _mode, _depth),
    do: [open, Enum.intersperse(items, ","), close]

  defp object_keys(reference, heap, :stable) do
    {indices, ordinary} =
      reference
      |> Value.object_keys(heap)
      |> Enum.split_with(&(not is_nil(Value.key_index(&1))))

    indices ++ Enum.sort_by(ordinary, &utf16_key/1)
  end

  defp object_keys(reference, heap, _mode), do: Value.object_keys(reference, heap)

  defp utf16_key(key) do
    raw = key |> Value.key_string() |> Value.to_utf16le()
    for <<unit::unsigned-little-16 <- raw>>, into: <<>>, do: <<unit::unsigned-big-16>>
  end

  defp quote_key(key) do
    case Value.key_string(key) do
      %{"value" => string} -> quote_string(string)
      value -> [?", quote_utf16(Value.to_utf16le(value)), ?"]
    end
  end

  defp quote_string(string) do
    valid_string(string)
    [?", for(<<codepoint::utf8 <- string>>, do: quote_codepoint(codepoint)), ?"]
  end

  defp quote_utf16(<<>>), do: []

  defp quote_utf16(<<high::unsigned-little-16, low::unsigned-little-16, rest::binary>>)
       when high in 0xD800..0xDBFF and low in 0xDC00..0xDFFF do
    codepoint = 0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00
    [quote_codepoint(codepoint) | quote_utf16(rest)]
  end

  defp quote_utf16(<<unit::unsigned-little-16, rest::binary>>),
    do: [quote_codepoint(unit) | quote_utf16(rest)]

  defp quote_codepoint(?"), do: "\\\""
  defp quote_codepoint(?\\), do: "\\\\"
  defp quote_codepoint(?\b), do: "\\b"
  defp quote_codepoint(?\t), do: "\\t"
  defp quote_codepoint(?\n), do: "\\n"
  defp quote_codepoint(?\f), do: "\\f"
  defp quote_codepoint(?\r), do: "\\r"

  defp quote_codepoint(codepoint) when codepoint < 0x20 or codepoint in 0xD800..0xDFFF do
    ["\\u", codepoint |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")]
  end

  defp quote_codepoint(codepoint), do: <<codepoint::utf8>>

  defp valid_string(string) do
    if String.valid?(string), do: :ok, else: fail(:invalid_utf8)
  end

  defp validate_snapshot(%{"type" => "undefined"}, _heap, _path),
    do: fail(:undefined_in_snapshot)

  defp validate_snapshot(%{"type" => "null"}, _heap, _path), do: :ok

  defp validate_snapshot(%{"type" => "boolean", "value" => value}, _heap, _path)
       when is_boolean(value),
       do: :ok

  defp validate_snapshot(%{"type" => "string", "value" => string}, _heap, _path)
       when is_binary(string),
       do: valid_string(string)

  defp validate_snapshot(%{"type" => "string", "utf16le" => encoded} = value, _heap, _path)
       when is_binary(encoded) do
    Value.to_utf16le(value)
    :ok
  end

  defp validate_snapshot(%{"type" => "number", "bits" => bits}, _heap, _path) do
    if (number_bits(bits) >>> 52 &&& 0x7FF) == 0x7FF,
      do: fail(:nonfinite_in_snapshot),
      else: :ok
  end

  defp validate_snapshot(%{"type" => "reference", "id" => id} = reference, heap, path)
       when is_binary(id) do
    path = enter_reference(id, path)

    case node(id, heap) do
      %{"type" => "array", "items" => items} when is_list(items) ->
        Enum.each(items, &validate_snapshot(&1, heap, path))

      %{"type" => "object", "keys" => keys, "fields" => fields}
      when is_list(keys) and is_map(fields) ->
        Enum.each(keys, fn key ->
          validate_snapshot(Value.key_string(key), heap, path)
          validate_snapshot(Value.object_fetch!(reference, key, heap), heap, path)
        end)

      _ ->
        fail(:unsupported_node)
    end
  end

  defp validate_snapshot(_value, _heap, _path), do: fail(:unsupported_value)

  defp copy_snapshot(%{"type" => "null"}, heap), do: {%{"type" => "null"}, heap}

  defp copy_snapshot(%{"type" => "boolean", "value" => value}, heap),
    do: {%{"type" => "boolean", "value" => value}, heap}

  defp copy_snapshot(%{"type" => "string", "value" => string}, heap),
    do: {%{"type" => "string", "value" => string}, heap}

  defp copy_snapshot(%{"type" => "string", "utf16le" => _encoded} = value, heap),
    do: {Value.from_utf16le(Value.to_utf16le(value)), heap}

  defp copy_snapshot(%{"type" => "number", "bits" => bits}, heap) do
    raw = number_bits(bits)
    raw = if (raw &&& @absolute_mask) == 0, do: 0, else: raw
    {%{"type" => "number", "bits" => Base.encode16(<<raw::unsigned-big-64>>, case: :lower)}, heap}
  end

  defp copy_snapshot(%{"type" => "reference", "id" => id} = reference, heap) do
    case node(id, heap) do
      %{"type" => "array", "items" => items} ->
        {items, heap} = Enum.map_reduce(items, heap, &copy_snapshot/2)
        Value.array(items, heap)

      %{"type" => "object", "fields" => _fields} ->
        {entries, heap} =
          reference
          |> Value.object_keys(heap)
          |> Enum.map_reduce(heap, fn key, heap ->
            {value, heap} = copy_snapshot(Value.object_fetch!(reference, key, heap), heap)
            {{key, value}, heap}
          end)

        Value.object(entries, heap)
    end
  end

  defp enter_reference(id, path) do
    if MapSet.member?(path, id), do: fail(:cyclic_value), else: MapSet.put(path, id)
  end

  defp node(id, %{"version" => 1, "nodes" => nodes}) when is_map(nodes) do
    case Map.fetch(nodes, id) do
      {:ok, node} -> node
      :error -> fail(:unknown_reference)
    end
  end

  defp node(_id, _heap), do: fail(:unsupported_heap)

  defp number_bits(bits) when is_binary(bits) do
    case Base.decode16(bits, case: :mixed) do
      {:ok, <<value::unsigned-big-64>>} -> value
      _ -> fail(:invalid_number_bits)
    end
  end

  defp number_bits(_bits), do: fail(:invalid_number_bits)

  defp encode_number(raw) do
    absolute = raw &&& @absolute_mask

    cond do
      absolute >>> 52 == 0x7FF ->
        "null"

      absolute == 0 ->
        "0"

      true ->
        {coefficient, exponent} = shortest_decimal(absolute)
        sign = if raw >>> 63 == 1, do: "-", else: ""
        [sign, place_decimal(coefficient, exponent)]
    end
  end

  # A decimal rounds to these bits exactly inside the adjacent-value midpoint
  # interval. Even binary significands include the endpoints; odd ones do not.
  # Search shortest coefficients first, then use exact closest/even selection.
  defp shortest_decimal(bits) do
    value = binary_rational(bits)
    previous = binary_rational(bits - 1)

    next =
      if bits == @max_finite,
        do: add(value, subtract(value, previous)),
        else: binary_rational(bits + 1)

    lower = midpoint(previous, value)
    upper = midpoint(value, next)
    inclusive? = (bits &&& 1) == 0
    find_decimal(value, lower, upper, inclusive?, decimal_order(value), 1)
  end

  defp binary_rational(0), do: {0, 1}

  defp binary_rational(bits) do
    exponent = bits >>> 52
    fraction = bits &&& @fraction_mask

    {significand, power} =
      if exponent == 0, do: {fraction, -1074}, else: {(1 <<< 52) + fraction, exponent - 1075}

    if power >= 0,
      do: {significand <<< power, 1},
      else: rational(significand, 1 <<< -power)
  end

  defp rational(numerator, denominator) do
    divisor = Integer.gcd(numerator, denominator)
    {div(numerator, divisor), div(denominator, divisor)}
  end

  defp add({a, b}, {c, d}), do: rational(a * d + c * b, b * d)
  defp subtract({a, b}, {c, d}), do: rational(a * d - c * b, b * d)

  defp midpoint(left, right) do
    {numerator, denominator} = add(left, right)
    rational(numerator, denominator * 2)
  end

  defp decimal_order({numerator, denominator} = value) do
    order = byte_size(Integer.to_string(numerator)) - byte_size(Integer.to_string(denominator))
    {scaled_numerator, scaled_denominator} = divide_power10(value, order)
    if scaled_numerator < scaled_denominator, do: order - 1, else: order
  end

  # Every binary64 value has a roundtripping decimal of at most 17 digits.
  # Adjacent scales also cover intervals crossing a decimal power boundary.
  defp find_decimal(value, lower, upper, inclusive?, order, digits) when digits <= 17 do
    minimum = Integer.pow(10, digits - 1)
    maximum = Integer.pow(10, digits) - 1

    candidates =
      Enum.flat_map((order - digits)..(order - digits + 2), fn exponent ->
        low = max(lower_integer(divide_power10(lower, exponent), inclusive?), minimum)
        high = min(upper_integer(divide_power10(upper, exponent), inclusive?), maximum)

        if low <= high do
          coefficient =
            value |> divide_power10(exponent) |> nearest_integer() |> max(low) |> min(high)

          {distance_numerator, distance_denominator} =
            decimal_distance(value, coefficient, exponent)

          [{coefficient, exponent, distance_numerator, distance_denominator}]
        else
          []
        end
      end)

    case Enum.reduce(candidates, nil, &closer_candidate/2) do
      nil -> find_decimal(value, lower, upper, inclusive?, order, digits + 1)
      {coefficient, exponent, _, _} -> {coefficient, exponent}
    end
  end

  defp find_decimal(_value, _lower, _upper, _inclusive?, _order, _digits),
    do: fail(:number_format_unrepresentable)

  defp divide_power10({numerator, denominator}, exponent) when exponent >= 0,
    do: {numerator, denominator * Integer.pow(10, exponent)}

  defp divide_power10({numerator, denominator}, exponent),
    do: {numerator * Integer.pow(10, -exponent), denominator}

  defp lower_integer({numerator, denominator}, inclusive?) do
    quotient = div(numerator, denominator)
    if inclusive? and rem(numerator, denominator) == 0, do: quotient, else: quotient + 1
  end

  defp upper_integer({numerator, denominator}, inclusive?) do
    quotient = div(numerator, denominator)
    if not inclusive? and rem(numerator, denominator) == 0, do: quotient - 1, else: quotient
  end

  defp nearest_integer({numerator, denominator}) do
    quotient = div(numerator, denominator)
    doubled_remainder = 2 * rem(numerator, denominator)

    cond do
      doubled_remainder < denominator -> quotient
      doubled_remainder > denominator -> quotient + 1
      rem(quotient, 2) == 0 -> quotient
      true -> quotient + 1
    end
  end

  defp decimal_distance({numerator, denominator}, coefficient, exponent) do
    {decimal_numerator, decimal_denominator} =
      if exponent >= 0,
        do: {coefficient * Integer.pow(10, exponent), 1},
        else: {coefficient, Integer.pow(10, -exponent)}

    {abs(decimal_numerator * denominator - numerator * decimal_denominator),
     decimal_denominator * denominator}
  end

  defp closer_candidate(candidate, nil), do: candidate

  defp closer_candidate(
         {coefficient, exponent, numerator, denominator} = candidate,
         {best_coefficient, best_exponent, best_numerator, best_denominator} = best
       ) do
    difference = numerator * best_denominator - best_numerator * denominator

    cond do
      difference < 0 -> candidate
      difference > 0 -> best
      rem(coefficient, 2) < rem(best_coefficient, 2) -> candidate
      rem(coefficient, 2) > rem(best_coefficient, 2) -> best
      {coefficient, exponent} < {best_coefficient, best_exponent} -> candidate
      true -> best
    end
  end

  defp place_decimal(coefficient, exponent) do
    digits = Integer.to_string(coefficient)
    length = byte_size(digits)
    position = length + exponent

    cond do
      position >= length and position <= 21 ->
        [digits, String.duplicate("0", position - length)]

      position > 0 and position <= 21 ->
        [binary_part(digits, 0, position), ".", binary_part(digits, position, length - position)]

      position >= -5 and position <= 0 ->
        ["0.", String.duplicate("0", -position), digits]

      true ->
        fraction = if length == 1, do: [], else: [".", binary_part(digits, 1, length - 1)]
        power = position - 1

        [
          binary_part(digits, 0, 1),
          fraction,
          "e",
          if(power < 0, do: "-", else: "+"),
          Integer.to_string(abs(power))
        ]
    end
  end

  defp fail(reason), do: throw({:workflow_json, reason})
end
