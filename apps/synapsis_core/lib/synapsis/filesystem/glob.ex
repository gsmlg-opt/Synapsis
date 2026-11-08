defmodule Synapsis.Filesystem.Glob do
  @moduledoc false

  # Match an already bounded, guarded path index. Unlike Path.wildcard/1 this
  # compiler performs no directory traversal or symlink following.
  def compile(pattern) do
    with true <- is_binary(pattern) and String.valid?(pattern) and byte_size(pattern) in 1..4_096,
         true <-
           Path.type(pattern) == :relative and not String.contains?(pattern, ["\0", "\\"]) and
             ".." not in Path.split(pattern),
         {:ok, alternatives} <- expand([pattern]),
         {:ok, expressions} <- expressions(alternatives, literal_prefix_depth(pattern)),
         {:ok, regex} <- Regex.compile("\\A(?:" <> Enum.join(expressions, "|") <> ")\\z", "u") do
      {:ok, regex}
    else
      false -> {:error, :unsafe_path}
      _ -> {:error, :invalid_pattern}
    end
  end

  defp expand(patterns) when length(patterns) > 64, do: {:error, :invalid_pattern}

  defp expand(patterns) do
    changed =
      Enum.flat_map(patterns, fn pattern ->
        case Regex.run(~r/\{([^{}]*,[^{}]*)\}/u, pattern, return: :index) do
          [{start, length}, {inner, count}] ->
            prefix = binary_part(pattern, 0, start)
            suffix = binary_part(pattern, start + length, byte_size(pattern) - start - length)

            pattern
            |> binary_part(inner, count)
            |> String.split(",")
            |> Enum.map(&(prefix <> &1 <> suffix))

          nil ->
            [pattern]
        end
      end)

    if changed == patterns, do: {:ok, patterns}, else: expand(changed)
  end

  defp literal_prefix_depth(pattern) do
    pattern
    |> String.split("/", trim: true)
    |> Enum.take_while(&(not String.contains?(&1, ["*", "?", "[", "{"])))
    |> length()
  end

  defp expressions(patterns, literal_depth) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, result} ->
      segments = pattern |> String.split("/", trim: true) |> Enum.reject(&(&1 == "."))

      case segments(segments, literal_depth) do
        {:ok, expression} -> {:cont, {:ok, result ++ [expression]}}
        error -> {:halt, error}
      end
    end)
  end

  defp segments([], _literal_depth), do: {:ok, ""}
  defp segments(["**"], _literal_depth), do: {:ok, "(?:(?!\\.)[^/]+(?:/(?!\\.)[^/]+)*)?"}

  defp segments(["**" | rest], _literal_depth) do
    with {:ok, tail} <- segments(rest, 0), do: {:ok, "(?:(?!\\.)[^/]+/)*" <> tail}
  end

  defp segments([segment | rest], literal_depth) do
    with {:ok, part} <- segment(segment, ""),
         {:ok, tail} <- segments(rest, max(0, literal_depth - 1)) do
      # Path.wildcard's default listing excludes dot entries even for an
      # explicit-dot wildcard. Only its literal path prefix bypasses listing.
      hidden = if literal_depth > 0, do: "", else: "(?!\\.)"
      {:ok, hidden <> part <> if(rest == [], do: "", else: "/" <> tail)}
    end
  end

  defp segment("", result), do: {:ok, result}
  defp segment("*" <> rest, result), do: segment(rest, result <> "[^/]*")
  defp segment("?" <> rest, result), do: segment(rest, result <> "[^/]")

  defp segment("[" <> rest, result) do
    case String.split(rest, "]", parts: 2) do
      [class, tail] when class != "" ->
        class =
          case class do
            # filelib treats ! as a literal set member, not shell negation.
            "^" <> chars -> "\\^" <> chars
            chars -> chars
          end

        if String.contains?(class, ["/", "["]),
          do: {:error, :invalid_pattern},
          else: segment(tail, result <> "[" <> class <> "]")

      _ ->
        {:error, :invalid_pattern}
    end
  end

  defp segment(input, result) do
    {character, rest} = String.next_codepoint(input)
    segment(rest, result <> Regex.escape(character))
  end
end
