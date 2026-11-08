defmodule Synapsis.SessionStatusTest do
  use ExUnit.Case, async: false
  alias Synapsis.Session.Store
  alias Synapsis.SessionStatus

  setup do
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, title: "Stored 世界", agent: "archive", status: "idle"})
    on_exit(fn -> Store.delete_session(id) end)
    %{id: id, context: %{session_id: id, agent_id: "main"}}
  end

  test "durable metadata reads without a Worker or turns", ctx do
    assert {:ok, result} = SessionStatus.read(%{}, ctx.context)
    assert result.source == "durable"
    assert result.session.id == ctx.id
    assert result.session.title == "Stored 世界"
    assert result.session.status == "idle"
    assert result.session.provider == nil

    assert Enum.sort(Map.keys(result.session)) ==
             ~w(agent id inserted_at model provider status title updated_at)a

    assert byte_size(Jason.encode!(result)) <= 65_536
  end

  test "explicit target reads exact persisted metadata", ctx do
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, title: "Target"})
    on_exit(fn -> Store.delete_session(id) end)

    assert {:ok, %{session: %{id: ^id, title: "Target"}}} =
             SessionStatus.read(%{"session_id" => id, "source" => "durable"}, ctx.context)
  end

  test "shared public projection normalizes DateTime and ISO8601 timestamps", ctx do
    assert {:ok, row} =
             SessionStatus.project(
               %{
                 "id" => ctx.id,
                 "inserted_at" => ~U[2026-10-26 01:00:00Z],
                 "updated_at" => "2026-10-26T09:00:00+08:00"
               },
               ctx.id
             )

    assert row.inserted_at == "2026-10-26T01:00:00Z"
    assert row.updated_at == "2026-10-26T01:00:00Z"
  end

  test "absent durable session stays explicit", ctx do
    assert {:error, :not_found} =
             SessionStatus.read(%{"session_id" => Ecto.UUID.generate()}, ctx.context)
  end

  test "expired deadline returns timeout", ctx do
    assert {:error, :timeout} =
             SessionStatus.read(%{}, ctx.context,
               deadline: System.monotonic_time(:millisecond) - 1
             )
  end
end
