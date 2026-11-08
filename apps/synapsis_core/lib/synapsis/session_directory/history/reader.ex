defmodule Synapsis.SessionDirectory.History.Reader do
  @moduledoc false

  alias Synapsis.Session.ReadSnapshot
  alias Synapsis.SessionDirectory.History.DTO

  @page_bytes 1_048_576

  def open(entry, limit, slot)
      when is_integer(limit) and limit in 1..20 and is_binary(slot) and byte_size(slot) > 0 do
    with {:ok, index} <-
           ReadSnapshot.tail_index(entry.handle,
             retain: 20 * limit + 20 + 8_000 + 1,
             max_bytes: @page_bytes
           ) do
      {:ok,
       %{
         entry: entry,
         slot: slot,
         view_id: Ecto.UUID.generate(),
         total_turns: index.total_turns,
         indices: index.entries
       }}
    end
  end

  # Standalone windows do not retain the inline directory suffix. Every range
  # and lookup is served from this original captured handle.
  def open_window(entry, options, slot) when is_map(options) and is_binary(slot) do
    with {:ok, index} <- ReadSnapshot.tail_index(entry.handle, retain: 1, max_bytes: @page_bytes),
         {:ok, pending} <- ReadSnapshot.read_pending(entry.handle, max_bytes: @page_bytes) do
      {:ok,
       %{
         entry: entry,
         slot: slot,
         view_id: Ecto.UUID.generate(),
         mode: :standalone,
         total_turns: index.total_turns,
         pending: pending.entries
       }}
    end
  end

  def read(%{mode: :standalone} = view, %{
        "type" => "history_read",
        "protocol" => 1,
        "historyProtocol" => 1,
        "id" => id,
        "readId" => read_id,
        "slot" => slot,
        "operation" => operation,
        "options" => options
      })
      when is_binary(id) and byte_size(id) > 0 and is_binary(read_id) and byte_size(read_id) > 0 and
             is_map(options) do
    with true <- slot == view.slot,
         :ok <- window_options(view, operation, options),
         {:ok, result} <- window_read(view, operation, options) do
      {:ok,
       Map.merge(
         %{
           "type" => "history_read_result",
           "protocol" => 1,
           "historyProtocol" => 1,
           "id" => id,
           "readId" => read_id,
           "slot" => slot,
           "viewId" => view.view_id,
           "totalTurns" => view.total_turns
         },
         result
       )}
    else
      false -> {:error, :invalid_projection}
      error -> error
    end
  end

  def read(view, %{
        "type" => "history_read",
        "protocol" => 1,
        "historyProtocol" => 1,
        "id" => id,
        "readId" => read_id,
        "slot" => slot,
        "operation" => operation,
        "options" => options
      })
      when is_binary(id) and byte_size(id) > 0 and is_binary(read_id) and byte_size(read_id) > 0 and
             operation in ["recent", "page"] and is_map(options) do
    with true <- slot == view.slot,
         :ok <- check_options(view, operation, options),
         {:ok, indices} <- select(view, operation, options),
         {:ok, rows} <- read_indices(view.entry.handle, indices) do
      {:ok,
       %{
         "type" => "history_read_result",
         "protocol" => 1,
         "historyProtocol" => 1,
         "id" => id,
         "readId" => read_id,
         "slot" => slot,
         "viewId" => view.view_id,
         "totalTurns" => view.total_turns,
         "rows" => rows
       }}
    else
      false -> {:error, :invalid_projection}
      error -> error
    end
  end

  def read(_, _), do: {:error, :invalid_projection}

  defp window_options(view, operation, options) do
    expected = %{"source" => view.view_id, "latestResetRawSeq" => nil}
    common = ~w(maxMessages maxLines maxBytes beforeSeq offset allowOversizedFirst
      allowResetArchiveFallback expectedReadWindow captureReadWindow readOnly recentAtHead)

    valid =
      case operation do
        operation when operation in ["recent", "page"] ->
          Map.keys(options) -- common == [] and is_integer(options["maxMessages"]) and
            options["maxMessages"] >= 1 and is_integer(options["maxBytes"]) and
            options["maxBytes"] in 1..8_388_608 and
            (not Map.has_key?(options, "offset") or
               (is_integer(options["offset"]) and options["offset"] >= 0)) and
            (not Map.has_key?(options, "beforeSeq") or
               (is_integer(options["beforeSeq"]) and options["beforeSeq"] >= 1))

        operation when operation in ["around-id", "by-id"] ->
          Map.keys(options) --
            ~w(messageId maxMessages maxBytes direction allowResetArchiveFallback
          readOnly expectedReadWindow includeHistoryContext historyVisibility currentOnly) == [] and
            match?({:ok, _}, Ecto.UUID.cast(options["messageId"]))

        "range" ->
          Map.keys(options) -- ~w(start endExclusive) == [] and
            is_integer(options["start"]) and options["start"] >= 0 and
            is_integer(options["endExclusive"]) and options["endExclusive"] >= options["start"] and
            options["endExclusive"] <= view.total_turns

        _ ->
          false
      end

    valid =
      valid and
        (not Map.has_key?(options, "expectedReadWindow") or
           options["expectedReadWindow"] == expected)

    if valid, do: :ok, else: {:error, :invalid_projection}
  end

  defp window_read(view, operation, options) when operation in ["recent", "page"] do
    ending = min(view.total_turns, Map.get(options, "beforeSeq", view.total_turns + 1) - 1)
    ending = max(0, ending - min(view.total_turns, Map.get(options, "offset", 0)))
    beginning = max(0, ending - options["maxMessages"])
    window_rows(view, beginning, ending)
  end

  defp window_read(view, "range", options),
    do: window_rows(view, options["start"], options["endExclusive"])

  defp window_read(view, operation, options) when operation in ["around-id", "by-id"] do
    with {:ok, rows} <- find_id(view.entry.handle, options["messageId"], nil, 0, nil) do
      {:ok, %{"rows" => rows, "found" => rows != []}}
    end
  end

  defp window_rows(_view, first, ending) when first == ending, do: {:ok, %{"rows" => []}}

  defp window_rows(view, first, ending) do
    with {:ok, index} <-
           ReadSnapshot.ordinal_window(view.entry.handle,
             start: first + 1,
             limit: ending - first,
             max_bytes: @page_bytes
           ),
         true <-
           index.total_turns == view.total_turns and length(index.entries) == ending - first,
         {:ok, rows} <- read_indices(view.entry.handle, index.entries),
         true <- :erlang.external_size(rows) <= 8_388_608 do
      {:ok, %{"rows" => rows}}
    else
      false -> {:error, :history_reader_admission}
      error -> error
    end
  end

  defp find_id(handle, id, cursor, ordinal, preceding) do
    options = [order: :asc, limit: 100, max_bytes: @page_bytes]
    options = if is_nil(cursor), do: options, else: Keyword.put(options, :cursor, cursor)

    with {:ok, page} <- ReadSnapshot.read_page(handle, options),
         true <- not page.truncated do
      rows =
        Enum.with_index(page.turns, ordinal + 1)
        |> Enum.map(fn {turn, rank} -> DTO.row(turn, rank) end)

      case Enum.find_index(rows, &(&1["message"]["__openclaw"]["id"] == id)) do
        nil ->
          if page.has_more,
            do:
              find_id(
                handle,
                id,
                page.next_cursor,
                ordinal + length(rows),
                List.last(rows) || preceding
              ),
            else: {:ok, []}

        position ->
          previous = if position > 0, do: Enum.at(rows, position - 1), else: preceding
          {:ok, Enum.reject([previous, Enum.at(rows, position)], &is_nil/1)}
      end
    else
      false -> {:error, :history_reader_admission}
      error -> error
    end
  end

  defp check_options(view, operation, options) do
    allowed =
      if operation == "recent",
        do:
          ~w(maxMessages maxLines maxBytes allowResetArchiveFallback captureReadWindow readOnly),
        else:
          ~w(beforeSeq offset maxMessages maxBytes allowOversizedFirst allowResetArchiveFallback expectedReadWindow captureReadWindow readOnly)

    expected = %{"source" => view.view_id, "latestResetRawSeq" => nil}

    valid =
      Map.keys(options) -- allowed == [] and
        is_integer(options["maxMessages"]) and options["maxMessages"] in 1..401 and
        is_integer(options["maxBytes"]) and options["maxBytes"] in 1..@page_bytes and
        (not Map.has_key?(options, "beforeSeq") or
           (is_integer(options["beforeSeq"]) and options["beforeSeq"] >= 1)) and
        (not Map.has_key?(options, "offset") or
           (is_integer(options["offset"]) and options["offset"] >= 0)) and
        (not Map.has_key?(options, "expectedReadWindow") or
           options["expectedReadWindow"] == expected)

    if valid, do: :ok, else: {:error, :invalid_projection}
  end

  defp select(view, operation, options) do
    ending =
      if operation == "page" and Map.has_key?(options, "beforeSeq"),
        do: min(view.total_turns, options["beforeSeq"] - 1),
        else: view.total_turns

    ending = max(0, ending - Map.get(options, "offset", 0))
    beginning = max(1, ending - options["maxMessages"] + 1)
    selected = Enum.filter(view.indices, &(&1.ordinal >= beginning and &1.ordinal <= ending))
    expected_count = max(0, ending - beginning + 1)

    if length(selected) == expected_count,
      do: {:ok, selected},
      else: {:error, :history_reader_admission}
  end

  defp read_indices(handle, indices) do
    indices
    |> Enum.chunk_every(100)
    |> Enum.reduce_while({:ok, []}, fn selected, {:ok, accumulated} ->
      first = hd(selected).index
      options = [order: :asc, limit: length(selected), max_bytes: @page_bytes]
      options = if first == 0, do: options, else: Keyword.put(options, :cursor, first - 1)

      with {:ok, page} <- ReadSnapshot.read_page(handle, options),
           true <-
             not page.truncated and
               Enum.map(page.turns, & &1.index) == Enum.map(selected, & &1.index) do
        rows =
          Enum.zip_with(page.turns, selected, fn turn, rank -> DTO.row(turn, rank.ordinal) end)

        {:cont, {:ok, [rows | accumulated]}}
      else
        false -> {:halt, {:error, :history_reader_admission}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end
end
