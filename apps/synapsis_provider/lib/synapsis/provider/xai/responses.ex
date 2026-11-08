defmodule Synapsis.Provider.XAI.Responses do
  @moduledoc "Shared xAI response text/citation parsing and model compatibility for remote tools."

  alias Synapsis.Provider.WebSearch.TextBudget

  @citation_limit 20
  @citation_scan 1_000
  @aliases %{
    "grok-4.3-latest" => "grok-4.3",
    "grok-4.5-latest" => "grok-4.5",
    "grok-4.7-latest" => "grok-4.7",
    "grok-build-latest" => "grok-4.5",
    "grok-code-fast-1" => "grok-build-0.1",
    "grok-code-fast" => "grok-build-0.1",
    "grok-code-fast-1-0825" => "grok-build-0.1",
    "grok-4-fast-reasoning" => "grok-4-fast",
    "grok-4-1-fast-reasoning" => "grok-4-1-fast"
  }

  def parse(payload, opts \\ []) do
    limit = Keyword.get(opts, :content_limit)
    inline? = Keyword.get(opts, :inline_citations, false)

    initial = %{
      parts: [],
      pending: [],
      left: limit,
      complete: true,
      cut: false,
      raw_offset: 0
    }

    retained =
      payload
      |> Map.get("output", [])
      |> List.wrap()
      |> Enum.flat_map(&blocks/1)
      |> Enum.reduce(initial, &retain/2)

    raw = retained.parts |> Enum.reverse() |> IO.iodata_to_binary()
    raw = if raw == "", do: text(payload["output_text"]), else: raw
    {content, units} = take(raw, limit)

    if content == "" do
      {:error, :malformed_response}
    else
      citations = citation_urls(payload["citations"])

      citations =
        if citations == [] do
          retained.pending
          |> Enum.reverse()
          |> Enum.reduce([], fn {offset, annotations}, citations ->
            if offset < units, do: annotation_urls(annotations, citations), else: citations
          end)
        else
          citations
        end

      answer = %{"content" => content, "citations" => citations}

      answer =
        if retained.cut or content != raw, do: Map.put(answer, "truncated", true), else: answer

      {:ok,
       if(inline? and is_list(payload["inline_citations"]),
         do:
           Map.put(
             answer,
             "inlineCitations",
             inline_citations(payload["inline_citations"], units)
           ),
         else: answer
       )}
    end
  end

  defp blocks(%{"type" => "message", "content" => blocks}) when is_list(blocks), do: blocks
  defp blocks(%{"type" => "output_text"} = block), do: [block]
  defp blocks(_), do: []

  defp retain(%{"type" => "output_text", "text" => raw} = block, state)
       when is_binary(raw) and raw != "" do
    {retained, used} = if state.complete, do: take(raw, state.left), else: {"", 0}
    cut = retained != raw

    pending =
      if retained != "" and is_list(block["annotations"]),
        do: [{state.raw_offset, block["annotations"]} | state.pending],
        else: state.pending

    %{
      state
      | parts: [retained | state.parts],
        pending: pending,
        left: if(is_nil(state.left), do: nil, else: state.left - used),
        complete: state.complete and not cut,
        cut: state.cut or cut,
        raw_offset: state.raw_offset + TextBudget.units(raw)
    }
  end

  defp retain(_, state), do: state

  defp citation_urls(values), do: collect_urls(values, [], fn value -> value end)

  defp annotation_urls(values, current) do
    collect_urls(values, current, fn
      %{"type" => "url_citation", "url" => value} -> value
      _ -> nil
    end)
  end

  defp collect_urls(values, current, value) when is_list(values) do
    values
    |> Enum.take(@citation_scan)
    |> Enum.reduce_while(current, fn entry, urls ->
      if length(urls) >= @citation_limit do
        {:halt, urls}
      else
        url = entry |> value.() |> canonical_url()
        {:cont, if(url && url not in urls, do: urls ++ [url], else: urls)}
      end
    end)
  end

  defp collect_urls(_, current, _), do: current

  defp inline_citations(values, units) do
    values
    |> Enum.take(@citation_limit)
    |> Enum.flat_map(fn
      %{"url" => value, "start_index" => first, "end_index" => last}
      when is_integer(first) and is_integer(last) and first >= 0 and last >= first and
             last <= units ->
        case canonical_url(value) do
          nil -> []
          url -> [%{"start_index" => first, "end_index" => last, "url" => url}]
        end

      _ ->
        []
    end)
  end

  # Portable ordinary HTTP(S) normalization. Full WHATWG URL and external-content
  # sanitizer/wrapper equivalence remain outside this host result contract.
  defp canonical_url(value) when is_binary(value) do
    if TextBudget.units(value) <= 2_048 do
      uri = value |> String.trim() |> URI.parse()
      scheme = if is_binary(uri.scheme), do: String.downcase(uri.scheme)

      if scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
        uri = %{uri | scheme: scheme, host: String.downcase(uri.host), path: uri.path || "/"}
        url = uri |> URI.to_string() |> URI.encode(&(&1 > 32 and &1 < 127))
        if TextBudget.units(url) <= 2_048, do: if(url == value <> "/", do: value, else: url)
      end
    end
  end

  defp canonical_url(_), do: nil

  def reasoning("grok-4.3", preferred), do: %{"effort" => preferred}

  def reasoning(model, _preferred) do
    normalized = model |> String.downcase() |> normalize_model()

    case Regex.run(~r/\Agrok-([0-9]+)(?:\.([0-9]+))?(?:-(?:latest|[0-9]{4}))?\z/u, normalized) do
      [_, major | minor] ->
        major = String.to_integer(major)
        minor = if minor in [[], [""]], do: 0, else: minor |> hd() |> String.to_integer()

        if major > 4 or (major == 4 and minor >= 6 and minor != 20),
          do: %{"effort" => "low"}

      _ ->
        nil
    end
  end

  def normalize_model(value), do: Map.get(@aliases, value, value)

  defp take(raw, nil), do: {raw, TextBudget.units(raw)}
  defp take(raw, limit), do: TextBudget.take(raw, limit)
  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
end
