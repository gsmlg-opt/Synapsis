defmodule Synapsis.Workflow.Pipeline do
  @moduledoc """
  Parses inline Lobster pipelines without resolving or executing commands.
  """

  @edge_whitespace ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u

  @spec parse(binary()) :: {:ok, [map()]} | {:error, atom()}
  def parse(input) when is_binary(input) do
    if String.valid?(input) do
      with {:ok, stages} <- split_pipes(input, nil, [], []) do
        parse_stages(stages, [])
      end
    else
      {:error, :invalid_input}
    end
  end

  def parse(_input), do: {:error, :invalid_input}

  defp split_pipes(<<>>, nil, current, stages) do
    stages =
      case raw_stage(current) do
        "" -> stages
        stage -> [stage | stages]
      end

    case stages do
      [] -> {:error, :empty_pipeline}
      _ -> {:ok, Enum.reverse(stages)}
    end
  end

  defp split_pipes(<<>>, _quote, _current, _stages), do: {:error, :unclosed_quote}

  defp split_pipes(<<?\\, next::utf8, rest::binary>>, quote, current, stages)
       when not is_nil(quote) do
    split_pipes(rest, quote, [<<next::utf8>>, "\\" | current], stages)
  end

  defp split_pipes(<<char::utf8, rest::binary>>, nil, current, stages)
       when char in [?\", ?'] do
    split_pipes(rest, char, [<<char::utf8>> | current], stages)
  end

  defp split_pipes(<<?|, rest::binary>>, nil, current, stages) do
    split_pipes(rest, nil, [], [raw_stage(current) | stages])
  end

  defp split_pipes(<<char::utf8, rest::binary>>, quote, current, stages) do
    next_quote = if char == quote, do: nil, else: quote
    split_pipes(rest, next_quote, [<<char::utf8>> | current], stages)
  end

  defp raw_stage(current) do
    current
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> then(&Regex.replace(@edge_whitespace, &1, ""))
  end

  defp parse_stages([], parsed), do: {:ok, Enum.reverse(parsed)}

  defp parse_stages([raw | stages], parsed) do
    with {:ok, tokens} <- tokenize(raw, nil, [], false, []),
         {:ok, name, args} <- parse_command(tokens) do
      parse_stages(stages, [%{"name" => name, "args" => args, "raw" => raw} | parsed])
    end
  end

  defp tokenize(<<>>, nil, current, started?, tokens) do
    {:ok, Enum.reverse(push_token(current, started?, tokens))}
  end

  defp tokenize(<<>>, _quote, _current, _started?, _tokens),
    do: {:error, :unclosed_quote}

  defp tokenize(<<?\\, ?', rest::binary>>, ?', current, started?, tokens) do
    tokenize(rest, ?', ["'" | current], started?, tokens)
  end

  defp tokenize(<<?\\, next, rest::binary>>, ?\", current, started?, tokens)
       when next in [?\", ?\\, ?$, ?`] do
    tokenize(rest, ?\", [<<next>> | current], started?, tokens)
  end

  defp tokenize(<<?\\, ?\n, rest::binary>>, ?\", current, started?, tokens) do
    tokenize(rest, ?\", current, started?, tokens)
  end

  defp tokenize(<<quote::utf8, rest::binary>>, quote, current, started?, tokens)
       when quote in [?\", ?'] do
    tokenize(rest, nil, current, started?, tokens)
  end

  defp tokenize(<<quote::utf8, rest::binary>>, nil, current, _started?, tokens)
       when quote in [?\", ?'] do
    tokenize(rest, quote, current, true, tokens)
  end

  defp tokenize(<<char::utf8, rest::binary>>, nil, current, started?, tokens)
       when char in [?\s, ?\t, ?\n, ?\r] do
    tokenize(rest, nil, [], false, push_token(current, started?, tokens))
  end

  defp tokenize(<<char::utf8, rest::binary>>, quote, current, _started?, tokens) do
    tokenize(rest, quote, [<<char::utf8>> | current], true, tokens)
  end

  defp push_token(current, true, tokens) do
    [current |> Enum.reverse() |> IO.iodata_to_binary() | tokens]
  end

  defp push_token(_current, false, tokens), do: tokens

  defp parse_command([]), do: {:error, :empty_stage}

  defp parse_command([name | tokens]) do
    with {:ok, args} <- parse_args(tokens, name, %{"_" => []}) do
      {:ok, name, args}
    end
  end

  defp parse_args([], _name, args) do
    args =
      Map.update!(args, "_", fn value ->
        if is_list(value), do: Enum.reverse(value), else: value
      end)

    {:ok, args}
  end

  defp parse_args(["--" <> flag | tokens], name, args) do
    case String.split(flag, "=", parts: 2) do
      [key, value] ->
        parse_args(tokens, name, Map.put(args, key, value))

      [key] ->
        case tokens do
          [next | rest] when not (name == "exec" and key == "json") ->
            if String.starts_with?(next, "--") do
              parse_args(tokens, name, Map.put(args, key, true))
            else
              parse_args(rest, name, Map.put(args, key, next))
            end

          _ ->
            parse_args(tokens, name, Map.put(args, key, true))
        end
    end
  end

  defp parse_args([token | tokens], name, %{"_" => positional} = args)
       when is_list(positional) do
    parse_args(tokens, name, Map.put(args, "_", [token | positional]))
  end

  defp parse_args(_tokens, _name, _args), do: {:error, :invalid_arguments}
end
