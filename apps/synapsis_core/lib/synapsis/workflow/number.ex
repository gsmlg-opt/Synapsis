defmodule Synapsis.Workflow.Number do
  @moduledoc """
  Pure binary64 conversion and comparison for trusted workflow number tags.

  Decimal tokens have already passed their caller's grammar validation. Exact
  integer ratios round once, to nearest with ties to even, including overflow,
  subnormals and signed zero. Classification and comparison inspect bits rather
  than constructing BEAM floats for Infinity or NaN. Existing tagged values
  retain their original NaN payload and sign.
  """

  import Bitwise

  alias Synapsis.Workflow.{JSON, Value}

  @sign 0x8000_0000_0000_0000
  @absolute 0x7FFF_FFFF_FFFF_FFFF
  @infinity 0x7FF0_0000_0000_0000
  @nan 0x7FF8_0000_0000_0000
  @fraction 0x000F_FFFF_FFFF_FFFF
  @decimal ~r/\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
  @edge_whitespace ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u

  @doc "Converts an already validated decimal token to its correctly rounded bits."
  def from_decimal(token) do
    negative? = String.starts_with?(token, "-")
    unsigned = token |> String.trim_leading("-") |> String.trim_leading("+")
    [mantissa | exponent] = String.split(unsigned, ["e", "E"], parts: 2)
    [integer | fraction] = String.split(mantissa, ".", parts: 2)
    fraction = List.first(fraction) || ""
    digits = String.trim_leading(integer <> fraction, "0")

    if digits == "" do
      signed(0, negative?)
    else
      significant = String.trim_trailing(digits, "0")
      exponent = if exponent == [], do: 0, else: String.to_integer(hd(exponent))
      power = exponent - byte_size(fraction) + byte_size(digits) - byte_size(significant)
      order = power + byte_size(significant) - 1

      cond do
        order > 308 ->
          signed(@infinity, negative?)

        order < -324 ->
          signed(0, negative?)

        true ->
          coefficient = String.to_integer(significant)

          if power >= 0,
            do: from_ratio(coefficient * Integer.pow(10, power), 1, negative?),
            else: from_ratio(coefficient, Integer.pow(10, -power), negative?)
      end
    end
  end

  @doc "Applies Number conversion to ordinary native JSON argument values."
  def from_native(nil), do: tagged(0)
  def from_native(true), do: tagged(0x3FF0_0000_0000_0000)
  def from_native(false), do: tagged(0)

  def from_native(value) when is_integer(value),
    do: from_ratio(abs(value), 1, value < 0)

  def from_native(value) when is_float(value),
    do: %{"type" => "number", "bits" => Base.encode16(<<value::float-big-64>>, case: :lower)}

  def from_native(value) when is_binary(value), do: from_string(value)
  def from_native(value) when is_list(value), do: value |> native_join() |> from_string()
  def from_native(_value), do: tagged(@nan)

  @doc "Applies Number conversion to a trusted primitive tagged value."
  def coerce(%{"type" => "number"} = value), do: value
  def coerce(%{"type" => "null"}), do: tagged(0)
  def coerce(%{"type" => "undefined"}), do: tagged(@nan)
  def coerce(%{"type" => "boolean", "value" => value}), do: from_native(value)
  def coerce(%{"type" => "string", "value" => value}), do: from_string(value)
  def coerce(%{"type" => "string", "utf16le" => _encoded}), do: tagged(@nan)

  @doc "Classifies all binary64 bit patterns without decoding a nonfinite float."
  def classify(value) do
    raw = bits(value)

    cond do
      (raw &&& @absolute) < @infinity -> :finite
      (raw &&& @fraction) != 0 -> :nan
      (raw &&& @sign) == 0 -> :positive_infinity
      true -> :negative_infinity
    end
  end

  @doc "Returns numeric order, with NaN unordered and both zero signs equal."
  def compare(left, right) do
    left_bits = bits(left)
    right_bits = bits(right)

    cond do
      classify(left) == :nan or classify(right) == :nan ->
        :unordered

      (left_bits &&& @absolute) == 0 and (right_bits &&& @absolute) == 0 ->
        0

      left_bits == right_bits ->
        0

      (left_bits &&& @sign) != (right_bits &&& @sign) ->
        if (left_bits &&& @sign) != 0, do: -1, else: 1

      (left_bits &&& @sign) == 0 ->
        if left_bits < right_bits, do: -1, else: 1

      true ->
        if left_bits > right_bits, do: -1, else: 1
    end
  end

  @doc "Extracts only finite BEAM floats for consumers with a finite contract."
  def finite(value) do
    if classify(value) == :finite do
      <<number::float-big-64>> = Base.decode16!(value["bits"], case: :lower)
      {:ok, number}
    else
      :nonfinite
    end
  end

  @doc "Returns JavaScript numeric truthiness, including false for NaN and zero."
  def truthy?(value), do: classify(value) != :nan and (bits(value) &&& @absolute) != 0

  @doc "Returns String(number), independently of JSON's nonfinite null rendering."
  def string(value) do
    case classify(value) do
      :nan ->
        "NaN"

      :positive_infinity ->
        "Infinity"

      :negative_infinity ->
        "-Infinity"

      :finite ->
        {:ok, text} = JSON.stringify(value, Value.new())
        text
    end
  end

  defp from_string(raw) do
    value = Regex.replace(@edge_whitespace, raw, "")

    cond do
      value == "" -> tagged(0)
      value in ["Infinity", "+Infinity"] -> tagged(@infinity)
      value == "-Infinity" -> tagged(@sign ||| @infinity)
      Regex.match?(~r/\A0[xX][0-9a-fA-F]+\z/, value) -> from_radix(value, 16)
      Regex.match?(~r/\A0[bB][01]+\z/, value) -> from_radix(value, 2)
      Regex.match?(~r/\A0[oO][0-7]+\z/, value) -> from_radix(value, 8)
      Regex.match?(@decimal, value) -> from_decimal(value)
      true -> tagged(@nan)
    end
  end

  defp from_radix(<<_prefix::binary-size(2), digits::binary>>, radix),
    do: from_ratio(String.to_integer(digits, radix), 1, false)

  defp native_join(values), do: values |> Enum.map(&native_string/1) |> Enum.join(",")
  defp native_string(nil), do: ""
  defp native_string(value) when is_binary(value), do: value
  defp native_string(value) when is_boolean(value), do: Atom.to_string(value)
  defp native_string(value) when is_number(value), do: value |> from_native() |> string()
  defp native_string(value) when is_list(value), do: native_join(value)
  defp native_string(_value), do: "[object Object]"

  defp from_ratio(0, _denominator, negative?), do: signed(0, negative?)

  defp from_ratio(numerator, denominator, negative?) do
    exponent = binary_exponent(numerator, denominator)

    raw =
      cond do
        exponent > 1023 ->
          @infinity

        exponent < -1022 ->
          round_ratio(numerator <<< 1074, denominator)

        true ->
          shift = 52 - exponent

          significand =
            if shift >= 0,
              do: round_ratio(numerator <<< shift, denominator),
              else: round_ratio(numerator, denominator <<< -shift)

          {significand, exponent} =
            if significand == 1 <<< 53,
              do: {significand >>> 1, exponent + 1},
              else: {significand, exponent}

          if exponent > 1023,
            do: @infinity,
            else: ((exponent + 1023) <<< 52) + significand - (1 <<< 52)
      end

    signed(raw, negative?)
  end

  defp binary_exponent(numerator, denominator) do
    exponent = bit_length(numerator) - bit_length(denominator)

    below? =
      if exponent >= 0,
        do: numerator < denominator <<< exponent,
        else: numerator <<< -exponent < denominator

    if below?, do: exponent - 1, else: exponent
  end

  defp bit_length(integer) do
    <<first, rest::binary>> = :binary.encode_unsigned(integer)
    byte_size(rest) * 8 + byte_bits(first)
  end

  defp byte_bits(0), do: 0
  defp byte_bits(value), do: 1 + byte_bits(value >>> 1)

  defp round_ratio(numerator, denominator) do
    quotient = div(numerator, denominator)
    twice_remainder = rem(numerator, denominator) * 2

    if twice_remainder > denominator or
         (twice_remainder == denominator and rem(quotient, 2) == 1),
       do: quotient + 1,
       else: quotient
  end

  defp signed(raw, true), do: tagged(raw ||| @sign)
  defp signed(raw, false), do: tagged(raw)
  defp tagged(raw), do: %{"type" => "number", "bits" => Base.encode16(<<raw::64>>, case: :lower)}

  defp bits(%{"type" => "number", "bits" => bits}) do
    <<raw::unsigned-big-64>> = Base.decode16!(bits, case: :lower)
    raw
  end
end
