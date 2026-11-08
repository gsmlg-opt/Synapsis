defmodule Synapsis.Provider.WebSearch.TextBudget do
  @moduledoc "UTF-16 units and complete-scalar prefixes for search text shared with JavaScript providers."

  def units(value), do: count(value, 0)

  def take(value, limit) do
    {bytes, used} = prefix(value, limit, 0, 0)

    retained =
      if bytes == byte_size(value), do: value, else: :binary.copy(binary_part(value, 0, bytes))

    {retained, used}
  end

  defp count(<<>>, units), do: units
  defp count(<<point::utf8, rest::binary>>, units), do: count(rest, units + width(point))

  defp prefix(<<>>, _left, bytes, units), do: {bytes, units}
  defp prefix(_rest, 0, bytes, units), do: {bytes, units}

  defp prefix(<<point::utf8, rest::binary>>, left, bytes, units) do
    width = width(point)

    if width <= left,
      do: prefix(rest, left - width, bytes + byte_size(<<point::utf8>>), units + width),
      else: {bytes, units}
  end

  defp width(point) when point > 0xFFFF, do: 2
  defp width(_), do: 1
end
