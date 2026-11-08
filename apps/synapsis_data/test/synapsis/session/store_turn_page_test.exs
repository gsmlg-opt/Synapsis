defmodule Synapsis.Session.StoreTurnPageTest do
  use ExUnit.Case, async: false

  alias Concord.Turso, as: KV
  alias Synapsis.Session.Store

  setup do
    assert :ok = Store.ensure_started()
    %{id: Ecto.UUID.generate(), other_id: Ecto.UUID.generate()}
  end

  test "sparse turns page in ascending order with an exclusive continuation", %{id: id} do
    persist(for n <- [91, 0, 7], do: {Store.turn_key(id, n), %{text: "turn #{n}"}})

    assert {:ok,
            %{
              turns: [%{index: 0, turn: %{text: "turn 0"}}, %{index: 7, turn: %{text: "turn 7"}}],
              next_cursor: 7,
              has_more: true,
              truncated: false
            }} = Store.list_turn_page(id, limit: 2)

    assert {:ok,
            %{
              turns: [%{index: 91, turn: %{text: "turn 91"}}],
              next_cursor: nil,
              has_more: false,
              truncated: false
            }} = Store.list_turn_page(id, cursor: 7, limit: 2)

    assert {:ok, %{turns: [], next_cursor: nil, has_more: false, truncated: false}} =
             Store.list_turn_page(id, cursor: 91)
  end

  test "default limit is twenty and the maximum limit is accepted", %{id: id} do
    persist(for n <- 0..21, do: {Store.turn_key(id, n), %{n: n}})

    assert {:ok, %{turns: turns, next_cursor: 19, has_more: true}} = Store.list_turn_page(id)
    assert Enum.map(turns, & &1.index) == Enum.to_list(0..19)

    assert {:ok, %{turns: all, next_cursor: nil, has_more: false}} =
             Store.list_turn_page(id, limit: 100)

    assert Enum.map(all, & &1.index) == Enum.to_list(0..21)
  end

  test "missing and metadata-only namespaces have a true end while orphan turns remain readable",
       %{
         id: id,
         other_id: other_id
       } do
    assert {:ok, %{turns: [], next_cursor: nil, has_more: false, truncated: false}} =
             Store.list_turn_page(id)

    persist([{Store.meta_key(id), %{private: "metadata"}}, {Store.turn_key(other_id, 4), %{}}])

    assert {:ok, %{turns: [], next_cursor: nil, has_more: false, truncated: false}} =
             Store.list_turn_page(id)

    assert {:ok, %{turns: [%{index: 4, turn: %{}}], has_more: false}} =
             Store.list_turn_page(other_id)
  end

  test "lookahead finds an oversized nonmap key without reading its payload", %{id: id} do
    persist([
      {Store.turn_key(id, 0), %{text: "small"}},
      {Store.turn_key(id, 1), String.duplicate("private", 300_000)}
    ])

    assert {:ok,
            %{
              turns: [%{index: 0, turn: %{text: "small"}}],
              next_cursor: 0,
              has_more: true,
              truncated: false
            }} = Store.list_turn_page(id, limit: 1, max_bytes: 100)

    assert {:error, :invalid_record} = Store.list_turn_page(id, cursor: 0, limit: 1)
  end

  test "malformed turn suffixes are skipped and the final twelve-digit index is included", %{
    id: id
  } do
    malformed = [
      "",
      "0",
      "00000000000",
      "0000000000000",
      "000000000000/child",
      "00000000000x",
      "1000000000000",
      "999999999999\n",
      "x"
    ]

    persist(
      Enum.map(malformed, &{Store.turns_prefix(id) <> &1, "malformed private value"}) ++
        [{Store.turn_key(id, 0), %{n: 0}}, {Store.turn_key(id, 999_999_999_999), %{n: :last}}]
    )

    assert {:ok, %{turns: [%{index: 0}, %{index: 999_999_999_999}], has_more: false}} =
             Store.list_turn_page(id)

    assert {:ok, %{turns: [%{index: 999_999_999_999}], next_cursor: nil, has_more: false}} =
             Store.list_turn_page(id, cursor: 0, limit: 1)

    assert {:ok, %{turns: [], next_cursor: nil, has_more: false}} =
             Store.list_turn_page(id, cursor: 999_999_999_999)
  end

  test "malformed-key seek exhaustion returns scan_limit instead of false empty success", %{
    id: id
  } do
    malformed =
      for n <- 0..512,
          do: {Store.turns_prefix(id) <> "000000000000/" <> Integer.to_string(n), %{}}

    persist(malformed ++ [{Store.turn_key(id, 1), %{text: "beyond budget"}}])

    assert {:error, :scan_limit} = Store.list_turn_page(id, limit: 1)
  end

  test "UUID and closed unique keyword options reject malformed input", %{id: id} do
    for invalid_id <- [
          nil,
          1,
          :session,
          "",
          "native/run",
          "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB",
          id <> "\n",
          String.replace(id, "-", "")
        ] do
      assert {:error, :invalid_input} = Store.list_turn_page(invalid_id)
    end

    for opts <- [
          nil,
          %{},
          [:cursor],
          [{"limit", 1}],
          [cursor: -1],
          [cursor: 1_000_000_000_000],
          [cursor: "0"],
          [cursor: 0.0],
          [limit: 0],
          [limit: 101],
          [limit: 1.0],
          [deadline: nil],
          [deadline: :infinity],
          [max_bytes: 0],
          [max_bytes: 1_048_577],
          [max_bytes: 1.0],
          [limit: 1, registry: AnotherRegistry],
          [limit: 1, limit: 2],
          [cursor: nil, cursor: 0],
          [deadline: 0, deadline: 1],
          [max_bytes: 1, max_bytes: 2]
        ] do
      assert {:error, :invalid_input} = Store.list_turn_page(id, opts)
    end
  end

  test "expired deadlines fail even for an empty namespace", %{id: id} do
    assert {:error, :timeout} =
             Store.list_turn_page(id, deadline: System.monotonic_time(:millisecond) - 1)

    assert {:ok, %{turns: [], has_more: false}} =
             Store.list_turn_page(id, deadline: System.monotonic_time(:millisecond) + 60_000)
  end

  test "aggregate external-term payload budget accepts the boundary and rejects whole pages", %{
    id: id
  } do
    first = %{text: "one"}
    second = %{text: "two"}
    bytes = :erlang.external_size(first) + :erlang.external_size(second)
    persist([{Store.turn_key(id, 0), first}, {Store.turn_key(id, 1), second}])

    assert {:ok, %{turns: [_, _], has_more: false}} = Store.list_turn_page(id, max_bytes: bytes)
    assert {:error, :payload_too_large} = Store.list_turn_page(id, max_bytes: bytes - 1)
    assert {:error, :payload_too_large} = Store.list_turn_page(id, max_bytes: 1)
  end

  test "default and maximum byte budgets reject oversized records without partial pages", %{
    id: id
  } do
    large = %{text: String.duplicate("x", 65_536)}
    persist([{Store.turn_key(id, 0), %{}}, {Store.turn_key(id, 1), large}])

    assert {:error, :payload_too_large} = Store.list_turn_page(id)
    assert {:ok, %{turns: [_, _]}} = Store.list_turn_page(id, max_bytes: 1_048_576)

    persist([{Store.turn_key(id, 2), %{text: String.duplicate("x", 1_048_576)}}])
    assert {:error, :payload_too_large} = Store.list_turn_page(id, max_bytes: 1_048_576)
  end

  test "selected records must be maps and retain opaque nested terms", %{id: id} do
    turn = %{messages: [%{at: ~U[2026-10-25 00:00:00Z], opaque: {:value, <<0, 255>>}}]}
    persist([{Store.turn_key(id, 0), turn}, {Store.turn_key(id, 1), [:invalid]}])

    assert {:ok, %{turns: [%{index: 0, turn: ^turn}], has_more: true}} =
             Store.list_turn_page(id, limit: 1)

    assert {:error, :invalid_record} = Store.list_turn_page(id, cursor: 0)
  end

  test "adjacent namespaces and another session are excluded, with current state read per call",
       %{
         id: id,
         other_id: other_id
       } do
    persist([
      {Store.meta_key(id), "private metadata"},
      {Store.value_key(id, "permission"), "private permission"},
      {Store.value_key(id, "pending_inputs/000000000000"), "private input"},
      {Store.value_key(id, "turns0/000000000000"), "adjacent namespace"},
      {Store.value_key(id, "turnr/000000000000"), "preceding namespace"},
      {Store.turn_key(other_id, 0), "other session invalid turn"},
      {Store.turn_key(id, 5), %{text: "old"}}
    ])

    assert {:ok, %{turns: [%{index: 5, turn: %{text: "old"}}], has_more: false}} =
             Store.list_turn_page(id)

    persist([{Store.turn_key(id, 5), %{text: "replacement"}}])

    assert {:ok, %{turns: [%{index: 5, turn: %{text: "replacement"}}], has_more: false}} =
             Store.list_turn_page(id)
  end

  defp persist(puts) do
    keys = Enum.map(puts, &elem(&1, 0))

    on_exit(fn ->
      for chunk <- Enum.chunk_every(keys, 100), do: KV.delete_many(chunk, timeout: 5_000)
    end)

    for chunk <- Enum.chunk_every(puts, 100) do
      assert {:ok, _} = KV.put_many(chunk, timeout: 5_000)
    end
  end
end
