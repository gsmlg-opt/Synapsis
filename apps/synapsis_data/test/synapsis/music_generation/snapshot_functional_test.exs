defmodule Synapsis.MusicGeneration.SnapshotFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.KV.Record
  alias Synapsis.MusicGeneration.Store

  @epoch_ms 1_800_000_000_000
  @first_id "00000000-0000-4000-8000-000000000003"
  @second_id "00000000-0000-4000-8000-000000000002"
  @third_id "00000000-0000-4000-8000-000000000001"

  setup do
    assert :ok = Synapsis.Session.Store.ensure_started()
    %{session_id: Ecto.UUID.generate(), agent_id: Ecto.UUID.generate()}
  end

  test "an empty scope returns a complete empty snapshot with its committed revision", context do
    assert {:ok, %{revision: revision, rows: []} = snapshot} =
             Store.snapshot(context.session_id, context.agent_id, deadline())

    assert is_integer(revision) and revision >= 0
    assert snapshot === %{revision: revision, rows: []}
  end

  test "admission order survives inverse UUIDs timestamps and replacements and rows remain replace receipts",
       context do
    first =
      record(context, @first_id, %{created_at: @epoch_ms + 900, updated_at: @epoch_ms + 900})

    second =
      record(context, @second_id, %{created_at: @epoch_ms + 500, updated_at: @epoch_ms + 500})

    third =
      record(context, @third_id, %{
        created_at: @epoch_ms + 100,
        updated_at: @epoch_ms + 100,
        status: "succeeded",
        active: false,
        result: %{"tracks" => [], "label" => "already complete 雪"}
      })

    assert {:ok, first_row} = Store.create(first, deadline())
    assert {:ok, second_row} = Store.create(second, deadline())
    assert {:ok, third_row} = Store.create(third, deadline())
    assert first_row.storage_revision < second_row.storage_revision
    assert second_row.storage_revision < third_row.storage_revision

    finished_first = %{
      first
      | revision: 2,
        status: "succeeded",
        active: false,
        result: %{"tracks" => [%{"title" => "夜 café 😀", "metadata" => %{"ok" => true}}]},
        updated_at: @epoch_ms + 1_000
    }

    assert {:ok, finished_first_row} = Store.replace(first_row, finished_first, deadline())
    assert finished_first_row.storage_revision > third_row.storage_revision

    assert {:ok, %{revision: snapshot_revision, rows: rows}} =
             Store.snapshot(context.session_id, context.agent_id, deadline())

    assert rows === [finished_first_row, second_row, third_row]
    assert Enum.map(rows, & &1.record.id) === [@first_id, @second_id, @third_id]
    assert Enum.all?(rows, &(Enum.sort(Map.keys(&1)) === [:record, :storage_revision]))
    assert Enum.all?(rows, &(&1.storage_revision <= snapshot_revision))

    [_, receipt, _] = rows

    running_second = %{
      receipt.record
      | revision: 2,
        status: "running",
        updated_at: @epoch_ms + 2_000
    }

    assert {:ok, running_second_row} = Store.replace(receipt, running_second, deadline())
    assert running_second_row.record === running_second
    assert running_second_row.storage_revision > receipt.storage_revision

    assert {:ok, %{rows: updated_rows}} =
             Store.snapshot(context.session_id, context.agent_id, deadline())

    assert updated_rows === [finished_first_row, running_second_row, third_row]
  end

  test "a normal 101-record inventory returns every admitted task across all internal pages",
       context do
    expected_rows =
      for index <- 1..101 do
        id = sequential_id(102 - index)
        active = rem(index, 2) == 1

        value =
          record(context, id, %{
            created_at: @epoch_ms + 102 - index,
            updated_at: @epoch_ms + 102 - index,
            active: active,
            status: if(active, do: "queued", else: "succeeded"),
            result: if(active, do: nil, else: %{"ordinal" => index, "complete" => true})
          })

        assert {:ok, row} = Store.create(value, deadline())
        row
      end

    assert {:ok, %{revision: revision, rows: rows} = snapshot} =
             Store.snapshot(context.session_id, context.agent_id, deadline())

    assert snapshot === %{revision: revision, rows: expected_rows}
    assert rows === expected_rows
    assert length(rows) === 101
    assert length(Enum.uniq_by(rows, & &1.record.id)) === 101
    assert hd(rows).record.id === "00000000-0000-4000-8000-000000000065"
    assert List.last(rows).record.id === "00000000-0000-4000-8000-000000000001"
    assert Enum.all?(rows, &(&1.storage_revision <= revision))
  end

  test "normally exited writers leave the complete admission-ordered snapshot for a fresh reader",
       context do
    first = record(context, @first_id)

    second =
      record(context, @third_id, %{active: false, status: "succeeded", result: %{"done" => true}})

    {first_row, second_row} =
      in_fresh_process(fn ->
        assert {:ok, first_row} = Store.create(first, deadline())
        assert {:ok, second_row} = Store.create(second, deadline())
        {first_row, second_row}
      end)

    assert {:ok, %{revision: revision, rows: rows} = snapshot} =
             in_fresh_process(fn ->
               Store.snapshot(context.session_id, context.agent_id, deadline())
             end)

    assert snapshot === %{revision: revision, rows: [first_row, second_row]}
    assert Enum.map(rows, & &1.record) === [first, second]
    assert first_row.storage_revision < second_row.storage_revision
    assert second_row.storage_revision <= revision
  end

  test "returned revision reads actual historical Records after a later acknowledged replacement",
       context do
    original = record(context, @first_id)
    assert {:ok, created} = Store.create(original, deadline())

    assert {:ok, %{revision: captured_revision, rows: [captured_row]}} =
             Store.snapshot(context.session_id, context.agent_id, deadline())

    assert captured_row === created
    assert captured_revision >= created.storage_revision

    completed = %{
      original
      | revision: 2,
        status: "succeeded",
        active: false,
        result: %{"tracks" => [%{"title" => "完了 😀", "duration_seconds" => 31.25}]},
        updated_at: @epoch_ms + 800
    }

    assert {:ok, updated} = Store.replace(created, completed, deadline())
    assert updated.storage_revision > captured_revision

    prefix =
      "coord/music-generation/v1/" <> context.session_id <> "/" <> context.agent_id <> "/jobs/"

    assert {:ok, [historical], %{has_more: false}} =
             Concord.Turso.list(
               prefix: prefix,
               revision: captured_revision,
               keys_only: false,
               limit: 100,
               queue: true,
               timeout: 5_000
             )

    assert Map.get(historical, :key) === prefix <> @first_id

    assert Map.drop(historical, [:key]) === %Record{
             value: original,
             create_revision: created.storage_revision,
             mod_revision: created.storage_revision,
             version: 1,
             metadata: %{},
             expires_at: nil,
             lease_id: nil,
             content_type: nil
           }

    assert Store.get(context.session_id, context.agent_id, @first_id, deadline()) ===
             {:ok, updated}

    assert {:ok, %{revision: current_revision, rows: [current_row]}} =
             Store.snapshot(context.session_id, context.agent_id, deadline())

    assert current_revision >= updated.storage_revision
    assert current_row === %{record: completed, storage_revision: updated.storage_revision}
    assert captured_row === %{record: original, storage_revision: created.storage_revision}
  end

  defp record(context, id, overrides \\ %{}) do
    Map.merge(
      %{
        schema_version: 1,
        id: id,
        session_id: context.session_id,
        agent_id: context.agent_id,
        revision: 1,
        status: "queued",
        active: true,
        submission_id: "native-submission-" <> id,
        request_key: String.duplicate("a1", 32),
        request: %{
          "prompt" => "  café 雪 😀\n二行目  ",
          "instrumental" => false,
          "duration_seconds" => 31.25,
          "references" => ["first.png", "second.png"],
          "metadata" => %{"empty" => %{}, "values" => [true, false, nil, 0]}
        },
        origin: %{
          "run_id" => "run-雪",
          "invocation_id" => "invocation-😀",
          "tool_call_id" => "call-café",
          "tool_name" => "music_generate"
        },
        result: nil,
        created_at: @epoch_ms,
        updated_at: @epoch_ms
      },
      overrides
    )
  end

  defp sequential_id(index) do
    suffix = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    "00000000-0000-4000-8000-" <> suffix
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
