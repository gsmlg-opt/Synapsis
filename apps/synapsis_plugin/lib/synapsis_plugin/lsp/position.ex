defmodule SynapsisPlugin.LSP.Position do
  @moduledoc "Resolve symbol names to line:character positions in source files."

  @doc "Find the position of a symbol in a file."
  def find_symbol(file_path, symbol_name) do
    case File.read(file_path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        result =
          lines
          |> Enum.with_index()
          |> Enum.find_value(fn {line, idx} ->
            case :binary.match(line, symbol_name) do
              {col, _len} -> {idx, col}
              :nomatch -> nil
            end
          end)

        case result do
          {line, character} -> {:ok, %{line: line, character: character}}
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
