defmodule Synapsis.SessionDirectoryRichResultFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.SessionDirectory.Result

  test "rich fitting retains exact JavaScript fractions, large numbers and source row order" do
    row = row("numeric-report")

    messages = [
      %{
        "role" => "user",
        "__openclaw" => %{"id" => Ecto.UUID.generate(), "seq" => 1},
        "content" => [%{"type" => "text", "text" => ""}]
      },
      %{
        "role" => "assistant",
        "__openclaw" => %{"id" => Ecto.UUID.generate(), "seq" => 2},
        "content" => [%{"type" => "text", "text" => ""}]
      },
      %{
        "role" => "assistant",
        "__openclaw" => %{"id" => Ecto.UUID.generate(), "seq" => 3},
        "content" => [
          %{"type" => "text", "text" => ""},
          %{
            "type" => "toolCall",
            "id" => "numeric-call",
            "name" => "read_file",
            "arguments" => %{
              "fraction" => 1.0e-7,
              "large" => 1.0e20,
              "path" => "report 雪 😀 \"path\\file\".\u2028.md",
              "values" => List.duplicate(1.0e-7, 2_000)
            }
          }
        ]
      }
    ]

    base_page = public_page([Map.put(row, :messages, messages)], 1, 100)
    base = javascript(%{rows: [%{row: row, messages: messages}], page: base_page})
    padding = 65_536 - base["utf8Bytes"]
    assert padding > 0
    assert div(padding + 2, 3) <= 7_900

    messages =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        size = div(padding, 3) + if(index < rem(padding, 3), do: 1, else: 0)
        put_in(message, ["content", Access.at(0), "text"], String.duplicate("a", size))
      end)

    expected_page = public_page([Map.put(row, :messages, messages)], 1, 100)
    oracle = javascript(%{rows: [%{row: row, messages: messages}], page: expected_page})
    [entry] = candidates([row], [7], oracle)

    assert {:ok, %{text: text, page: page}} =
             Result.fit_rendered([entry], %{limit: 100, next_offset: nil})

    assert page == expected_page
    assert text == oracle["text"]
    fragment = get_in(hd(oracle["candidates"]), ["enriched", "json"])
    assert text =~ fragment
    assert text =~ ~s("fraction": 1e-7)
    assert text =~ ~s("large": 100000000000000000000)
    refute text =~ ~s("fraction": 1.0e-7)
    assert Jason.decode!(text) == Jason.decode!(Jason.encode!(page))
    assert byte_size(text) == oracle["utf8Bytes"]
    assert byte_size(text) == 65_536
    assert is_atom(hd(Map.keys(page)))
    assert Map.has_key?(hd(page.sessions), :messages)
    assert Map.has_key?(hd(hd(page.sessions).messages), "role")
  end

  test "ordinary rich pages retain the longest fitting prefix and first omitted original offset" do
    rows = for index <- 1..3, do: row("prefix-report-#{index}")

    histories =
      for index <- 1..3 do
        for turn <- 1..3 do
          %{
            "role" => if(rem(turn, 2) == 1, do: "user", else: "assistant"),
            "content" => [
              %{
                "type" => "text",
                "text" => "Report #{index}/#{turn}: " <> String.duplicate("a", 7_500)
              }
            ],
            "__openclaw" => %{"id" => Ecto.UUID.generate(), "seq" => turn}
          }
        end
      end

    enriched_rows = Enum.zip_with(rows, histories, &Map.put(&1, :messages, &2))

    expected_page =
      public_page(Enum.take(enriched_rows, 2), 2, 3, %{
        next_offset: 29,
        has_more: true,
        truncation_reason: "byte-limit"
      })

    input = Enum.zip_with(rows, histories, &%{row: &1, messages: &2})
    oracle = javascript(%{rows: input, page: expected_page})

    complete =
      javascript(%{
        rows: input,
        page: public_page(enriched_rows, 3, 3, %{next_offset: 42, has_more: true})
      })

    entries = candidates(rows, [11, 17, 29], oracle)
    assert oracle["utf8Bytes"] <= 65_536
    assert complete["utf8Bytes"] > 65_536
    assert Enum.all?(oracle["candidates"], &(&1["enriched"]["kind"] == "json"))

    assert {:ok, %{text: text, page: page}} =
             Result.fit_rendered(entries, %{limit: 3, next_offset: 42})

    assert page == expected_page
    assert text == oracle["text"]
    assert page.count == 2
    assert page.next_offset == 29
    assert page.truncation_reason == "byte-limit"
    refute Map.has_key?(page, :enrichment_omitted)
    assert byte_size(text) == oracle["utf8Bytes"]
    assert Jason.decode!(text) == Jason.decode!(Jason.encode!(page))
  end

  test "first rich row exceeding final page bytes downgrades every row to real metadata" do
    rows =
      for index <- 1..2 do
        row("metadata-report-#{index}")
        |> Map.merge(%{
          derived_title: "Derived report #{index}.",
          last_message_preview: "Report ready."
        })
      end

    histories =
      for index <- 1..2 do
        for turn <- 1..8 do
          %{
            "role" => "assistant",
            "content" => [
              %{
                "type" => "text",
                "text" => "Report #{index}/#{turn}: " <> String.duplicate("a", 7_980)
              }
            ],
            "__openclaw" => %{"id" => Ecto.UUID.generate(), "seq" => turn}
          }
        end
      end

    metadata = Enum.map(rows, &Map.drop(&1, [:derived_title, :last_message_preview]))
    expected_page = public_page(metadata, 2, 2, %{enrichment_omitted: true})
    input = Enum.zip_with(rows, histories, &%{row: &1, messages: &2})
    oracle = javascript(%{rows: input, page: expected_page})
    entries = candidates(rows, [4, 8], oracle)

    first_full =
      javascript(%{
        rows: input,
        page:
          public_page([Map.put(hd(rows), :messages, hd(histories))], 1, 2, %{
            next_offset: 8,
            has_more: true,
            truncation_reason: "byte-limit"
          })
      })

    assert first_full["utf8Bytes"] > 65_536
    assert oracle["utf8Bytes"] < 65_536

    assert {:ok, %{text: text, page: page}} =
             Result.fit_rendered(entries, %{limit: 2, next_offset: nil})

    assert page == expected_page
    assert text == oracle["text"]
    assert page.enrichment_omitted == true
    assert page.count == 2
    assert page.has_more == false
    refute Map.has_key?(page, :truncation_reason)

    for row <- page.sessions,
        key <- [:messages, :derived_title, :last_message_preview],
        do: refute(Map.has_key?(row, key))

    assert Jason.decode!(text) == Jason.decode!(Jason.encode!(page))
  end

  defp row(title),
    do: %{
      id: Ecto.UUID.generate(),
      title: title,
      agent: "archive",
      provider: nil,
      model: nil,
      status: nil,
      inserted_at: nil,
      updated_at: nil
    }

  defp public_page(rows, count, limit, extra \\ %{}),
    do:
      Map.merge(
        %{source: "durable", count: count, sessions: rows, has_more: false, limit_applied: limit},
        extra
      )

  defp candidates(rows, offsets, oracle) do
    Enum.zip([rows, offsets, oracle["candidates"]])
    |> Enum.map(fn {row, offset, candidate} ->
      history = %{
        enriched: fragment(candidate["enriched"]),
        metadata: fragment(candidate["metadata"])
      }

      history =
        if Map.has_key?(candidate, "messages"),
          do: Map.put(history, :messages, candidate["messages"]),
          else: history

      %{row: row, offset: offset, enrich?: true, history_candidate: history}
    end)
  end

  defp fragment(%{"kind" => "json", "json" => json, "utf8Bytes" => bytes}),
    do: %{kind: "json", json: json, utf8_bytes: bytes}

  defp fragment(%{"kind" => "oversize", "utf8Bytes" => bytes}),
    do: %{kind: "oversize", utf8_bytes: bytes}

  # Independent serialization of public row trees. This oracle neither imports
  # nor recreates the production fitter; each test supplies its expected page.
  defp javascript(input) do
    script = ~S"""
    let input = '';
    const newline = String.fromCharCode(10);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      input += chunk;
      if (!input.includes(newline)) return;
      const request = JSON.parse(input.slice(0, input.indexOf(newline)));
      const fragment = value => {
        const json = JSON.stringify(value, null, 2).split(newline).map(line => '    ' + line).join(newline);
        const utf8Bytes = Buffer.byteLength(json, 'utf8');
        return utf8Bytes <= 65536 ? { kind: 'json', json, utf8Bytes } : { kind: 'oversize', utf8Bytes };
      };
      const enrichedRows = request.rows.map(({row, messages}) => ({...row, messages}));
      const candidates = request.rows.map(({row, messages}, index) => {
        const metadata = {...row};
        for (const key of ['messages', 'derived_title', 'last_message_preview']) delete metadata[key];
        const enriched = fragment(enrichedRows[index]);
        return {...(enriched.kind === 'json' ? {messages} : {}), enriched, metadata: fragment(metadata)};
      });
      const page = request.page;
      page.sessions = page.sessions.map(row => {
        const source = request.rows.find(item => item.row.id === row.id);
        if (Object.hasOwn(row, 'messages')) return {...source.row, messages: source.messages};
        const metadata = {...source.row};
        for (const key of ['messages', 'derived_title', 'last_message_preview']) delete metadata[key];
        return metadata;
      });
      const orderedPage = {};
      for (const key of ['count', 'enrichment_omitted', 'has_more', 'limit_applied', 'next_offset', 'sessions', 'source', 'truncation_reason']) {
        if (Object.hasOwn(page, key)) orderedPage[key] = page[key];
      }
      const text = JSON.stringify(orderedPage, null, 2);
      process.stdout.write(JSON.stringify({candidates, text, utf8Bytes: Buffer.byteLength(text, 'utf8')}));
      process.stdin.destroy();
    });
    """

    port =
      Port.open({:spawn_executable, node_executable()}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["-e", script]
      ])

    try do
      assert Port.command(port, Jason.encode!(input) <> "\n")
      collect_javascript(port, "")
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect_javascript(port, output) do
    receive do
      {^port, {:data, chunk}} -> collect_javascript(port, output <> chunk)
      {^port, {:exit_status, 0}} -> Jason.decode!(output)
    after
      5_000 -> flunk("ordinary JSON.stringify oracle did not finish")
    end
  end

  defp node_executable,
    do:
      System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node") ||
        System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
end
