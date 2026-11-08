defmodule Synapsis.SessionDirectory.Result do
  @moduledoc false

  @limit 65_536
  @enrichment [:derived_title, :last_message_preview]
  @page_fields [
    :count,
    :enrichment_omitted,
    :has_more,
    :limit_applied,
    :next_offset,
    :sessions,
    :source,
    :truncation_reason
  ]
  @row_keys Map.new(
              ~w(id title agent provider model status inserted_at updated_at derived_title last_message_preview messages)a,
              &{Atom.to_string(&1), &1}
            )

  def fit_rendered(entries, page) do
    if Enum.any?(entries, &Map.has_key?(&1, :history_candidate)) do
      fit_rich(entries, page)
    else
      with {:ok, result} <- fit(entries, page),
           {:ok, text} <- Jason.encode(result, pretty: true) do
        {:ok, %{text: text, page: result}}
      end
    end
  end

  defp fit_rich(entries, page) do
    {variant, omitted?} =
      if rich_fits?(entries, page, 1, :enriched, false),
        do: {:enriched, false},
        else: {:metadata, true}

    total = length(entries)

    count =
      if rich_fits?(entries, page, total, variant, omitted?),
        do: total,
        else: rich_prefix(entries, page, variant, omitted?, 0, total)

    if count == 0 do
      {:error, :output_limit}
    else
      with {:ok, text} <- render_rich(entries, page, count, variant, omitted?),
           true <- byte_size(text) <= @limit,
           {:ok, rows} <- public_rows(Enum.take(entries, count), variant) do
        result = result(entries, page, count, omitted?) |> Map.put(:sessions, rows)
        {:ok, %{text: text, page: result}}
      else
        false -> {:error, :output_limit}
        error -> error
      end
    end
  end

  defp rich_prefix(_entries, _page, _variant, _omitted?, lower, upper) when lower == upper,
    do: lower

  defp rich_prefix(entries, page, variant, omitted?, lower, upper) do
    middle = div(lower + upper + 1, 2)

    if rich_fits?(entries, page, middle, variant, omitted?),
      do: rich_prefix(entries, page, variant, omitted?, middle, upper),
      else: rich_prefix(entries, page, variant, omitted?, lower, middle - 1)
  end

  defp rich_fits?(entries, page, count, variant, omitted?) do
    case render_rich(entries, page, count, variant, omitted?) do
      {:ok, text} -> byte_size(text) <= @limit
      _ -> false
    end
  end

  # Only scalar envelope fields are host-encoded. Row fragments already include
  # their four-space indentation and JavaScript's exact number spelling/order.
  defp render_rich(entries, page, count, variant, omitted?) do
    selected = Enum.take(entries, count)
    fragments = Enum.map(selected, &Map.fetch!(&1.history_candidate, variant))

    if Enum.all?(fragments, &(&1.kind == "json")) do
      sessions =
        case fragments do
          [] -> "[]"
          _ -> "[\n" <> Enum.map_join(fragments, ",\n", & &1.json) <> "\n  ]"
        end

      envelope = result(entries, page, count, omitted?)

      fields =
        @page_fields
        |> Enum.filter(&Map.has_key?(envelope, &1))
        |> Enum.map_join(",\n", fn key ->
          value =
            if key == :sessions, do: sessions, else: Jason.encode!(Map.fetch!(envelope, key))

          "  " <> Jason.encode!(Atom.to_string(key)) <> ": " <> value
        end)

      {:ok, "{\n" <> fields <> "\n}"}
    else
      {:error, :output_limit}
    end
  end

  # Decode only the chosen original fragments after fitting. Normalize the
  # public host row keys while preserving every nested message key as a string.
  defp public_rows(entries, variant) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, rows} ->
      fragment = Map.fetch!(entry.history_candidate, variant)

      case Jason.decode(fragment.json) do
        {:ok, row} when is_map(row) ->
          row = Map.new(row, fn {key, value} -> {Map.get(@row_keys, key, key), value} end)
          {:cont, {:ok, [row | rows]}}

        _ ->
          {:halt, {:error, :invalid_projection}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  # Legacy directory values are only strings, booleans, nil and integers. On
  # that tree Jason's two-space pretty encoding has JSON.stringify byte size.
  # Fitting is synchronous: no storage or helper work follows final validation.
  def fit(entries, page) do
    {entries, omitted?} =
      if entries != [] and not fits?(entries, page, 1, false) do
        removed? =
          Enum.any?(entries, fn entry ->
            Enum.any?(@enrichment, &Map.has_key?(entry.row, &1))
          end)

        {Enum.map(entries, &%{&1 | row: Map.drop(&1.row, @enrichment)}), removed?}
      else
        {entries, false}
      end

    total = length(entries)

    count =
      if fits?(entries, page, total, omitted?),
        do: total,
        else: longest_prefix(entries, page, omitted?, 0, total)

    if total > 0 and count == 0 do
      {:error, :output_limit}
    else
      result = result(entries, page, count, omitted?)
      if fits?(entries, page, count, omitted?), do: {:ok, result}, else: {:error, :output_limit}
    end
  end

  defp longest_prefix(_entries, _page, _omitted?, lower, upper) when lower == upper,
    do: lower

  defp longest_prefix(entries, page, omitted?, lower, upper) do
    middle = div(lower + upper + 1, 2)

    if fits?(entries, page, middle, omitted?),
      do: longest_prefix(entries, page, omitted?, middle, upper),
      else: longest_prefix(entries, page, omitted?, lower, middle - 1)
  end

  defp fits?(entries, page, count, omitted?) do
    case Jason.encode(result(entries, page, count, omitted?), pretty: true) do
      {:ok, json} -> byte_size(json) <= @limit
      _ -> false
    end
  end

  defp result(entries, page, count, omitted?) do
    truncated? = count < length(entries)
    next = if truncated?, do: Enum.at(entries, count).offset, else: page.next_offset

    %{
      source: "durable",
      count: count,
      sessions: entries |> Enum.take(count) |> Enum.map(& &1.row),
      has_more: not is_nil(next),
      limit_applied: page.limit
    }
    |> optional(:next_offset, next)
    |> optional(:enrichment_omitted, if(omitted?, do: true))
    |> optional(:truncation_reason, if(truncated?, do: "byte-limit"))
  end

  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)
end
