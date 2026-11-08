defmodule Synapsis.SkillSearch do
  @moduledoc "Pure lexical ranking of assigned Skill metadata and independently prepared bodies."

  # OpenClaw 488631c: installed-skill-catalog.ts and tool-search-ranking.ts.
  # Skill queries use document tokens, without tool-intent query expansions.
  @stopwords ~w(a an and are as at be but by can do for from had has have here how i if in
                into is it its me my no not of on or our so that the their them then there
                these they this to up us was we were what when where which who why will
                with you your)
  @non_plurals ~w(news status alias canvas focus bonus virus atlas lens axis basis analysis gas bus plus)
  @suffixes ~w(ies ing ed ly es er s e)
  @uppercase ~r/^\p{Lu}$/u
  @lowercase ~r/^\p{Ll}$/u
  @number ~r/^\p{N}$/u
  @separators ~r/[^\p{L}\p{N}_]{1,1024}/u
  # ECMAScript WhiteSpace + LineTerminator, including BOM but excluding NEL.
  @trim ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+|[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]+\z/u

  @doc "Prepare the independent body corpus using positions in the eligible metadata catalog."
  def prepare_bodies(bodies) when is_list(bodies) do
    bodies
    |> Enum.map(fn %{position: position, content: content} ->
      document(tokenize(content), position)
    end)
    |> corpus()
  end

  @doc "Rank metadata entries, preserving every returned input map or struct unchanged."
  def rank(entries, query), do: rank(entries, query, prepare_bodies([]))

  def rank(entries, query, bodies) do
    needle = Regex.replace(@trim, query, "")
    terms = needle |> tokenize() |> Enum.uniq()

    metadata =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {entry, position} ->
        document(tokenize(entry.name <> " " <> entry.description), position)
      end)
      |> corpus()

    body_scores = scores(bodies, terms)
    metadata_scores = scores(metadata, terms)

    exact =
      Enum.find_index(entries, &(&1.name == needle)) ||
        Enum.find_index(entries, &(lowercase(&1.name) == lowercase(needle)))

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, position} ->
      score = Map.get(metadata_scores, position, 0.0) * 2 + Map.get(body_scores, position, 0.0)
      {entry, position, score}
    end)
    |> Enum.filter(fn {_entry, position, score} -> score > 0 or position == exact end)
    |> Enum.sort_by(fn {entry, position, score} ->
      {if(position == exact, do: 0, else: 1), -score, utf16(entry.name), position}
    end)
    |> Enum.map(fn {entry, _position, _score} -> entry end)
  end

  defp document(tokens, position),
    do: %{position: position, length: length(tokens), frequencies: Enum.frequencies(tokens)}

  defp corpus(documents) do
    total = length(documents)
    average = if total > 0, do: Enum.sum(Enum.map(documents, & &1.length)) / total, else: 0

    frequencies =
      Enum.reduce(documents, %{}, fn document, counts ->
        Enum.reduce(Map.keys(document.frequencies), counts, fn term, acc ->
          Map.update(acc, term, 1, &(&1 + 1))
        end)
      end)

    %{documents: documents, total: total, average: average, frequencies: frequencies}
  end

  defp scores(index, terms) do
    Map.new(index.documents, fn document ->
      {document.position,
       metadata_score(document, terms, index.frequencies, index.total, index.average)}
    end)
  end

  defp metadata_score(document, terms, frequencies, total, average) do
    Enum.reduce(terms, 0.0, fn term, score ->
      case Map.get(document.frequencies, term, 0) do
        0 ->
          score

        frequency ->
          matching = Map.fetch!(frequencies, term)
          idf = :math.log(1 + (total - matching + 0.5) / (matching + 0.5))
          normalized = if average > 0, do: document.length / average, else: 1

          score +
            idf * (frequency * (1.2 + 1)) /
              (frequency + 1.2 * (1 - 0.75 + 0.75 * normalized))
      end
    end)
  end

  defp tokenize(input) do
    @separators
    |> Regex.split(input, trim: true)
    |> Enum.flat_map(fn raw ->
      parts = word_parts(String.codepoints(raw), [])
      words = if length(parts) >= 2, do: [raw | parts], else: [raw]
      Enum.map(words, &lowercase/1)
    end)
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.flat_map(&stem_variants/1)
  end

  defp word_parts([], parts), do: Enum.reverse(parts)

  defp word_parts([character | rest] = characters, parts) do
    cond do
      Regex.match?(@uppercase, character) ->
        {uppercase, following} = Enum.split_while(characters, &Regex.match?(@uppercase, &1))
        uppercase_part(uppercase, following, parts)

      Regex.match?(@lowercase, character) ->
        {part, following} = Enum.split_while(characters, &Regex.match?(@lowercase, &1))
        word_parts(following, [Enum.join(part) | parts])

      Regex.match?(@number, character) ->
        {part, following} = Enum.split_while(characters, &Regex.match?(@number, &1))
        word_parts(following, [Enum.join(part) | parts])

      true ->
        word_parts(rest, parts)
    end
  end

  defp uppercase_part(uppercase, ["s" | rest] = following, parts) do
    if not lowercase_head?(rest) do
      word_parts(rest, [Enum.join(uppercase) <> "s" | parts])
    else
      uppercase_word(uppercase, following, parts)
    end
  end

  defp uppercase_part(uppercase, following, parts),
    do: uppercase_word(uppercase, following, parts)

  defp uppercase_word(uppercase, following, parts) do
    cond do
      lowercase_head?(following) and length(uppercase) > 1 ->
        {part, last} = Enum.split(uppercase, -1)
        word_parts(last ++ following, [Enum.join(part) | parts])

      lowercase_head?(following) ->
        {lowercase, rest} = Enum.split_while(following, &Regex.match?(@lowercase, &1))
        word_parts(rest, [Enum.join(uppercase ++ lowercase) | parts])

      true ->
        word_parts(following, [Enum.join(uppercase) | parts])
    end
  end

  defp lowercase_head?([character | _]), do: Regex.match?(@lowercase, character)
  defp lowercase_head?([]), do: false

  defp stem_variants(word) do
    if utf16_length(word) > 4 and String.ends_with?(word, "ies") do
      base = drop_suffix(word, "ies")
      [base <> "y", stem(base <> "ie", 3)]
    else
      [stem(word, 3)]
    end
  end

  defp stem(word, 0), do: word

  defp stem(word, passes) do
    next = strip_suffix(word)
    if next == word, do: word, else: stem(next, passes - 1)
  end

  defp strip_suffix(word) do
    size = utf16_length(word)

    if size <= 3 or word in @non_plurals do
      word
    else
      suffix =
        Enum.find(@suffixes, fn suffix ->
          String.ends_with?(word, suffix) and size - byte_size(suffix) >= 3 and
            not (suffix == "s" and String.ends_with?(word, "ss"))
        end)

      case suffix do
        nil -> word
        "ies" -> drop_suffix(word, suffix) <> "y"
        suffix when suffix in ["ing", "ed", "er"] -> word |> drop_suffix(suffix) |> undouble()
        suffix -> drop_suffix(word, suffix)
      end
    end
  end

  defp undouble(word) do
    # JavaScript .at(-1/-2) observes UTF16 code units, not codepoints/graphemes.
    units = utf16(word)
    prefix_size = byte_size(units) - 4

    case units do
      <<prefix::binary-size(prefix_size), last::16, last::16>>
      when byte_size(units) > 6 and last not in [?l, ?s, ?f, ?z, ?a, ?e, ?i, ?o, ?u] ->
        :unicode.characters_to_binary(<<prefix::binary, last::16>>, {:utf16, :big}, :utf8)

      _ ->
        word
    end
  end

  defp drop_suffix(word, suffix), do: binary_part(word, 0, byte_size(word) - byte_size(suffix))

  # The Greek mode adds Unicode's contextual Final_Sigma mapping to the default
  # full lowercase mapping (including dotted I), as ECMAScript toLowerCase does.
  defp lowercase(word), do: String.downcase(word, :greek)
  defp utf16(word), do: :unicode.characters_to_binary(word, :utf8, {:utf16, :big})
  defp utf16_length(word), do: div(byte_size(utf16(word)), 2)
end
