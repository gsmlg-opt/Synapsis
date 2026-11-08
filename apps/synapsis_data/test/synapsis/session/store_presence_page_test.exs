defmodule Synapsis.Session.StorePresencePageTest do
  use ExUnit.Case, async: false

  alias Concord.Turso, as: KV
  alias Synapsis.Session.Store

  @cursor "ffffffff-ffff-ffff-ffff-ffffffffff00"
  @first "ffffffff-ffff-ffff-ffff-ffffffffff01"
  @second "ffffffff-ffff-ffff-ffff-ffffffffff02"
  @last "ffffffff-ffff-ffff-ffff-ffffffffffff"

  setup do
    assert :ok = Store.ensure_started()
    %{deadline: System.monotonic_time(:millisecond) + 5_000}
  end

  test "candidate pages skip entire large transcripts and return each UUID once", ctx do
    turns =
      for n <- 0..1_100,
          do:
            {Store.turn_key(@first, n),
             %{payload: if(n == 0, do: String.duplicate("x", 2_000_000), else: "turn")}}

    puts = [
      {Store.meta_key(@first), %{agent: "private owner"}},
      {Store.meta_key(@second), %{}} | turns
    ]

    persist(puts)

    assert {:ok, page} =
             Store.list_session_ids(cursor: @cursor, limit: 1, deadline: ctx.deadline)

    assert page.session_ids == [@first]
    assert page.has_more
    assert page.next_cursor == @first
    refute page.truncated
    refute Jason.encode!(page) =~ ~r/payload|private|turn/

    assert {:ok, next} =
             Store.list_session_ids(cursor: page.next_cursor, limit: 1, deadline: ctx.deadline)

    assert next.session_ids == [@second]
  end

  test "orphan session keys are candidates while malformed IDs and keys are skipped", ctx do
    persist([
      {Store.turn_key(@first, 0), %{payload: "orphan turn"}},
      {"sessions/" <> @first <> "not-a-separator/meta", %{secret: "malformed"}},
      {"sessions/" <> @first, %{secret: "missing suffix"}},
      {Store.meta_key(@second), %{agent: "owner"}}
    ])

    assert {:ok, page} =
             Store.list_session_ids(cursor: @cursor, limit: 2, deadline: ctx.deadline)

    assert page.session_ids == [@first, @second]
  end

  test "exact final candidate and the following empty page report a true end", ctx do
    persist([{Store.meta_key(@last), %{agent: "owner"}}])

    assert {:ok, %{session_ids: [@last], has_more: false, next_cursor: nil, truncated: false}} =
             Store.list_session_ids(cursor: @second, limit: 1, deadline: ctx.deadline)

    assert {:ok, %{session_ids: [], has_more: false, next_cursor: nil, truncated: false}} =
             Store.list_session_ids(cursor: @last, limit: 1, deadline: ctx.deadline)
  end

  test "malformed-key budget exhaustion is an explicit error without false empty success", ctx do
    puts =
      for n <- 1..2_001,
          do:
            {"sessions/" <> @first <> "malformed-" <> Integer.to_string(n), %{private: "payload"}}

    persist(puts)

    assert {:error, :scan_limit} =
             Store.list_session_ids(cursor: @cursor, limit: 1, deadline: ctx.deadline)
  end

  test "closed page inputs reject invalid UUID cursors, limits and expired deadlines", ctx do
    for opts <- [
          [cursor: "native/run", limit: 1],
          [cursor: String.duplicate("x", 4_097), limit: 1],
          [cursor: @cursor, limit: 0],
          [cursor: @cursor, limit: 101],
          [cursor: @cursor, limit: 1.0],
          [cursor: @cursor, limit: 1, registry: AnotherRegistry]
        ] do
      assert {:error, :invalid_input} =
               Store.list_session_ids(Keyword.put(opts, :deadline, ctx.deadline))
    end

    assert {:error, :timeout} =
             Store.list_session_ids(
               cursor: @cursor,
               limit: 1,
               deadline: System.monotonic_time(:millisecond) - 1
             )
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
