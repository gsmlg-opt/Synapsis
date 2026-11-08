defmodule Synapsis.MusicGeneration.StoreFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV
  alias Synapsis.MusicGeneration.Store

  @epoch_ms 1_800_000_000_000
  @first_id "00000000-0000-4000-8000-000000000001"
  @second_id "00000000-0000-4000-8000-000000000002"
  @third_id "00000000-0000-4000-8000-000000000003"
  @fourth_id "00000000-0000-4000-8000-000000000004"

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{session_id: Ecto.UUID.generate(), agent_id: Ecto.UUID.generate()}
  end

  test "creation preserves the complete Unicode request and origin with exact submission lookup",
       context do
    record = record(context, Ecto.UUID.generate())

    assert {:ok, row} = Store.create(record, deadline())
    assert row.record === record
    assert is_integer(row.storage_revision) and row.storage_revision > 0

    assert Store.get(record.session_id, record.agent_id, record.id, deadline()) == {:ok, row}

    assert Store.find_submission(
             record.session_id,
             record.agent_id,
             record.submission_id,
             deadline()
           ) == {:ok, row}

    assert Store.page(record.session_id, record.agent_id, :all, [limit: 10], deadline()) ==
             {:ok, %{rows: [row], next_cursor: nil}}
  end

  test "active replacements publish the exact job and active mirror at one storage revision",
       context do
    record = record(context, Ecto.UUID.generate())
    assert {:ok, created} = Store.create(record, deadline())

    initial_records = stored_copies(record)
    assert length(initial_records) == 2
    assert Enum.all?(initial_records, &(&1.mod_revision == created.storage_revision))

    next = %{
      record
      | revision: 2,
        status: "vendor-ready 雪",
        result: %{
          "provider_job_id" => "生成-😀",
          "tracks" => [
            %{"title" => "夜の café", "duration_seconds" => 31.25, "url" => nil}
          ],
          "metadata" => %{"empty" => %{}, "values" => [true, false, nil, 0]}
        },
        updated_at: @epoch_ms + 123
    }

    assert {:ok, replaced} = Store.replace(created, next, deadline())
    assert replaced.record === next
    assert replaced.record.revision == created.record.revision + 1
    assert replaced.storage_revision > created.storage_revision

    updated_records = stored_copies(next)
    assert length(updated_records) == 2
    assert Enum.all?(updated_records, &(&1.mod_revision == replaced.storage_revision))
    assert stored_copies(record) == []

    assert Store.get(record.session_id, record.agent_id, record.id, deadline()) ==
             {:ok, replaced}

    assert Store.find_submission(
             record.session_id,
             record.agent_id,
             record.submission_id,
             deadline()
           ) == {:ok, replaced}

    assert Store.page(record.session_id, record.agent_id, :active, [limit: 10], deadline()) ==
             {:ok, %{rows: [replaced], next_cursor: nil}}
  end

  test "all and active pages use UUID order and observe a completed job leaving the active view",
       context do
    first =
      record(context, @first_id, %{created_at: @epoch_ms + 400, updated_at: @epoch_ms + 400})

    second = record(context, @second_id, %{active: false, status: "finished"})

    third =
      record(context, @third_id, %{created_at: @epoch_ms + 200, updated_at: @epoch_ms + 200})

    fourth =
      record(context, @fourth_id, %{created_at: @epoch_ms + 100, updated_at: @epoch_ms + 100})

    rows =
      Map.new([fourth, second, third, first], fn value ->
        assert {:ok, row} = Store.create(value, deadline())
        {value.id, row}
      end)

    first_row = rows[@first_id]
    second_row = rows[@second_id]
    third_row = rows[@third_id]
    fourth_row = rows[@fourth_id]

    assert {:ok, %{rows: [^first_row, ^second_row], next_cursor: all_cursor}} =
             Store.page(context.session_id, context.agent_id, :all, [limit: 2], deadline())

    refute is_nil(all_cursor)

    assert Store.page(
             context.session_id,
             context.agent_id,
             :all,
             [limit: 2, cursor: all_cursor],
             deadline()
           ) == {:ok, %{rows: [third_row, fourth_row], next_cursor: nil}}

    assert {:ok, %{rows: [^first_row], next_cursor: active_cursor}} =
             Store.page(context.session_id, context.agent_id, :active, [limit: 1], deadline())

    refute is_nil(active_cursor)

    assert Store.page(
             context.session_id,
             context.agent_id,
             :active,
             [limit: 2, cursor: active_cursor],
             deadline()
           ) == {:ok, %{rows: [third_row, fourth_row], next_cursor: nil}}

    completed = %{
      third
      | revision: 2,
        status: "completed",
        active: false,
        result: %{"tracks" => [], "message" => "完了 😀"},
        updated_at: @epoch_ms + 1_000
    }

    assert {:ok, completed_row} = Store.replace(third_row, completed, deadline())
    assert completed_row.record === completed
    assert [persisted] = stored_copies(completed)
    assert persisted.mod_revision == completed_row.storage_revision
    assert stored_copies(third) == []

    assert Store.page(
             context.session_id,
             context.agent_id,
             :active,
             [limit: 2, cursor: active_cursor],
             deadline()
           ) == {:ok, %{rows: [fourth_row], next_cursor: nil}}

    assert Store.page(context.session_id, context.agent_id, :all, [limit: 10], deadline()) ==
             {:ok, %{rows: [first_row, second_row, completed_row, fourth_row], next_cursor: nil}}

    assert Store.find_submission(
             context.session_id,
             context.agent_id,
             completed.submission_id,
             deadline()
           ) == {:ok, completed_row}
  end

  test "normally exited creators leave durable jobs readable by a fresh process", context do
    record = record(context, Ecto.UUID.generate())

    assert {:ok, created} =
             in_fresh_process(fn -> Store.create(record, deadline()) end)

    assert created.record === record

    observed =
      in_fresh_process(fn ->
        {
          Store.get(record.session_id, record.agent_id, record.id, deadline()),
          Store.find_submission(
            record.session_id,
            record.agent_id,
            record.submission_id,
            deadline()
          ),
          Store.page(record.session_id, record.agent_id, :active, [limit: 10], deadline())
        }
      end)

    assert observed ==
             {{:ok, created}, {:ok, created}, {:ok, %{rows: [created], next_cursor: nil}}}
  end

  defp record(context, id, overrides \\ %{}) do
    Map.merge(
      %{
        schema_version: 1,
        id: id,
        session_id: context.session_id,
        agent_id: context.agent_id,
        revision: 1,
        status: "accepted 音楽",
        active: true,
        submission_id: "native-submission-" <> id,
        request_key: String.duplicate("a1", 32),
        request: %{
          "prompt" => "  café 雪 😀\n二行目\u2028第三行  ",
          "instrumental" => false,
          "duration_seconds" => 31.25,
          "provider_options" => %{
            "tags" => ["ambient", "夜", nil],
            "seed" => 0,
            "empty" => %{}
          }
        },
        origin: %{
          "run_id" => "run-雪",
          "invocation_id" => "invocation-😀",
          "tool_call_id" => "call-café",
          "tool_name" => "synapsis::music_generate",
          "context" => %{"label" => nil, "values" => [true, false, %{}]}
        },
        result: nil,
        created_at: @epoch_ms,
        updated_at: @epoch_ms
      },
      overrides
    )
  end

  # Discover public records by their values, without depending on job/index key layout.
  defp stored_copies(record) do
    stored_records(nil, []) |> Enum.filter(&(&1.value === record))
  end

  defp stored_records(cursor, acc) do
    options =
      [
        engine: :turso,
        prefix: "coord/music-generation/v1/",
        keys_only: true,
        limit: 1_000,
        queue: true,
        timeout: 5_000
      ]

    options =
      if is_nil(cursor) do
        options
      else
        options
        |> Keyword.delete(:prefix)
        |> Keyword.put(:range, {cursor <> <<0>>, "coord/music-generation/v1/\u{10FFFF}"})
      end

    assert {:ok, keys, page} = KV.list(options)

    records =
      Enum.map(keys, fn key ->
        assert {:ok, stored} = KV.get(key.key, engine: :turso, metadata: true, timeout: 5_000)
        stored
      end)

    if page.has_more,
      do: stored_records(page.last_key, acc ++ records),
      else: acc ++ records
  end

  defp in_fresh_process(fun) do
    caller = self()
    tag = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(caller, {tag, fun.()}) end)
    assert_receive {^tag, result}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 10_000
    result
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
