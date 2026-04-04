defmodule Synapsis.DevLog do
  @moduledoc """
  Pure functions for parsing and appending to markdown dev log documents.

  Dev log format:
  ```
  # Dev Log

  ## YYYY-MM-DD

  ### HH:MM — category [author]
  Content.
  ```
  """

  @type entry :: %{
          timestamp: DateTime.t(),
          category: String.t(),
          author: String.t(),
          content: String.t()
        }

  @valid_categories ~w(decision progress blocker insight error completion user-note)
  @valid_author_prefixes ~w(assistant user system build-agent:)

  @doc """
  Append an entry to existing markdown content.

  Places the entry under the correct date heading (YYYY-MM-DD). If the date
  heading already exists, inserts after it. If not, creates a new date heading.

  Returns the updated content string.
  """
  @spec append(String.t(), entry()) :: String.t()
  def append(content, entry) do
    date_str = entry.timestamp |> DateTime.to_date() |> Date.to_string()
    time_str = entry.timestamp |> DateTime.to_time() |> format_time()
    date_heading = "## #{date_str}"

    entry_block = """
    ### #{time_str} — #{entry.category} [#{entry.author}]
    #{String.trim(entry.content)}
    """

    content = String.trim_trailing(content)

    if String.contains?(content, date_heading) do
      # Insert after the existing date heading line
      lines = String.split(content, "\n")
      heading_index = Enum.find_index(lines, &(&1 == date_heading))

      {before_heading, [heading | after_heading]} = Enum.split(lines, heading_index)

      # Find next section heading to insert before it, or append at end of section
      next_section_index = Enum.find_index(after_heading, &String.starts_with?(&1, "## "))

      new_lines =
        if next_section_index do
          {section_content, rest} = Enum.split(after_heading, next_section_index)

          before_heading ++
            [heading] ++
            section_content ++
            ["", String.trim_trailing(entry_block)] ++
            [""] ++
            rest
        else
          before_heading ++
            [heading] ++
            after_heading ++
            ["", String.trim_trailing(entry_block)]
        end

      Enum.join(new_lines, "\n")
    else
      # Append a new date heading and entry at the end
      new_section = "\n#{date_heading}\n\n#{String.trim_trailing(entry_block)}"

      if content == "" || content == "# Dev Log" do
        content <> new_section
      else
        content <> "\n" <> new_section
      end
    end
  end

  @doc """
  Parse markdown content into a list of entry structs.

  Returns a list of `entry()` maps.
  """
  @spec parse(String.t()) :: [entry()]
  def parse(content) when is_binary(content) do
    # Split into lines for processing
    lines = String.split(content, "\n")

    parse_lines(lines, nil, [], [])
  end

  @doc """
  Return the last N entries from the log content.
  """
  @spec recent(String.t(), pos_integer()) :: [entry()]
  def recent(content, count) do
    content
    |> parse()
    |> Enum.take(-count)
  end

  @doc """
  Filter entries by options.

  Supported opts:
  - `:category` — filter by category string
  - `:author` — filter by author string
  - `:since` — filter to entries after this DateTime
  - `:until` — filter to entries before this DateTime
  """
  @spec filter(String.t(), keyword()) :: [entry()]
  def filter(content, opts) do
    content
    |> parse()
    |> Enum.filter(&matches_filter?(&1, opts))
  end

  @doc """
  Return valid categories.
  """
  def valid_categories, do: @valid_categories

  @doc """
  Validate a category string.
  """
  def valid_category?(cat), do: cat in @valid_categories

  @doc """
  Validate an author string.
  """
  def valid_author?(author) do
    Enum.any?(@valid_author_prefixes, &String.starts_with?(author, &1))
  end

  # Private helpers

  defp format_time(time) do
    hour = time.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    minute = time.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{hour}:#{minute}"
  end

  # State machine parser: tracks current date and accumulates entries
  defp parse_lines([], _current_date, current_entry_lines, acc) do
    # Finalize last entry if any
    case finalize_entry(current_entry_lines) do
      nil -> Enum.reverse(acc)
      entry -> Enum.reverse([entry | acc])
    end
  end

  defp parse_lines([line | rest], current_date, current_entry_lines, acc) do
    cond do
      # Date heading: ## YYYY-MM-DD
      Regex.match?(~r/^## \d{4}-\d{2}-\d{2}$/, line) ->
        date_str = String.trim_leading(line, "## ")

        finalized = finalize_entry(current_entry_lines)
        new_acc = if finalized, do: [finalized | acc], else: acc

        parse_lines(rest, date_str, [], new_acc)

      # Entry heading: ### HH:MM — category [author]
      match = Regex.run(~r/^### (\d{2}:\d{2}) — ([\w-]+) \[([^\]]+)\]$/, line) ->
        [_, time_str, category, author] = match

        finalized = finalize_entry(current_entry_lines)
        new_acc = if finalized, do: [finalized | acc], else: acc

        # Start new entry context
        timestamp = parse_timestamp(current_date, time_str)
        entry_header = {timestamp, category, author}

        parse_lines(rest, current_date, [{:header, entry_header}], new_acc)

      # Content line (belongs to current entry)
      current_entry_lines != [] ->
        parse_lines(rest, current_date, current_entry_lines ++ [{:line, line}], acc)

      # Skip (preamble or blank lines before first entry)
      true ->
        parse_lines(rest, current_date, current_entry_lines, acc)
    end
  end

  defp finalize_entry([]), do: nil
  defp finalize_entry(nil), do: nil

  defp finalize_entry([{:header, {timestamp, category, author}} | content_lines]) do
    content =
      content_lines
      |> Enum.map(fn {:line, l} -> l end)
      |> Enum.join("\n")
      |> String.trim()

    %{
      timestamp: timestamp,
      category: category,
      author: author,
      content: content
    }
  end

  defp finalize_entry(_), do: nil

  defp parse_timestamp(date_str, time_str) when is_binary(date_str) and is_binary(time_str) do
    [hour, minute] = String.split(time_str, ":") |> Enum.map(&String.to_integer/1)

    case Date.from_iso8601(date_str) do
      {:ok, date} ->
        {:ok, time} = Time.new(hour, minute, 0)
        {:ok, naive} = NaiveDateTime.new(date, time)
        DateTime.from_naive!(naive, "Etc/UTC")

      _ ->
        DateTime.utc_now()
    end
  end

  defp parse_timestamp(nil, _time_str) do
    DateTime.utc_now()
  end

  defp matches_filter?(entry, opts) do
    Enum.all?(opts, fn
      {:category, cat} -> entry.category == cat
      {:author, author} -> entry.author == author
      {:since, dt} -> DateTime.compare(entry.timestamp, dt) != :lt
      {:until, dt} -> DateTime.compare(entry.timestamp, dt) != :gt
      _ -> true
    end)
  end
end
