defmodule Synapsis.SessionDirectoryTest do
  use ExUnit.Case, async: false
  alias Synapsis.Session.Store
  alias Synapsis.SessionDirectory

  setup do
    :ok = Store.ensure_started()
    prefix = "directory-#{Ecto.UUID.generate()}"
    %{prefix: prefix, context: %{session_id: Ecto.UUID.generate(), agent_id: "main"}}
  end

  test "durable inactive sessions are listed by default without a live process", ctx do
    id = persist(%{title: ctx.prefix, agent: "archive", status: "idle"})
    assert {:ok, page} = SessionDirectory.list(%{}, ctx.context)
    assert page.source == "durable"
    assert Enum.any?(page.sessions, &(&1.id == id))
    assert page.limit_applied == 100
  end

  test "filtering precedes stable recency ordering and offset pagination", ctx do
    old = persist(%{title: ctx.prefix, updated_at: "2024-01-01T00:00:00Z"})
    tied = for _ <- 1..2, do: persist(%{title: ctx.prefix, updated_at: ~U[2025-01-01 00:00:00Z]})
    absent = persist(%{title: ctx.prefix})
    persist(%{title: "unrelated", updated_at: "2026-01-01T00:00:00Z"})
    input = %{"search" => String.upcase(ctx.prefix), "limit" => 2}
    assert {:ok, first} = SessionDirectory.list(input, ctx.context)
    assert Enum.map(first.sessions, & &1.id) == Enum.sort(tied)
    assert first.count == 2 and first.has_more and first.next_offset == 2
    assert {:ok, last} = SessionDirectory.list(Map.put(input, "offset", 2), ctx.context)
    assert Enum.map(last.sessions, & &1.id) == [old, absent]
    assert last.count == 2 and last.has_more == false
    refute Map.has_key?(last, :next_offset)
    assert Enum.all?(first.sessions, &(&1.updated_at == "2025-01-01T00:00:00Z"))
  end

  test "agent search and durable activity filters compose across public metadata", ctx do
    current = DateTime.utc_now()

    target =
      persist(%{
        title: ctx.prefix,
        agent: "archive",
        provider: "ProviderABC",
        updated_at: current
      })

    persist(%{title: ctx.prefix, agent: "archive", updated_at: DateTime.add(current, -7200)})
    persist(%{title: ctx.prefix, agent: "other", updated_at: current})

    assert {:ok, page} =
             SessionDirectory.list(
               %{"search" => ctx.prefix, "agent" => "archive", "active_minutes" => 10},
               ctx.context
             )

    assert Enum.map(page.sessions, & &1.id) == [target]
    assert {:ok, providers} = SessionDirectory.list(%{"search" => "providerabc"}, ctx.context)
    assert Enum.any?(providers.sessions, &(&1.id == target))
  end

  test "global recency includes the newest match beyond the first candidate key page", ctx do
    ids = Enum.sort(for _ <- 1..105, do: Ecto.UUID.generate())
    newest = List.last(ids)

    for id <- ids do
      persist(%{
        id: id,
        title: ctx.prefix,
        updated_at: if(id == newest, do: "2026-01-01T00:00:00Z", else: "2024-01-01T00:00:00Z")
      })
    end

    assert {:ok, page} =
             SessionDirectory.list(%{"search" => ctx.prefix, "limit" => 1}, ctx.context)

    assert [%{id: ^newest}] = page.sessions
    assert page.has_more and page.next_offset == 1

    assert {:ok, second} =
             SessionDirectory.list(
               %{"search" => ctx.prefix, "limit" => 1, "offset" => 1},
               ctx.context
             )

    assert Enum.map(second.sessions, & &1.id) == [hd(ids)]
  end

  test "expired shared deadline reports timeout", ctx do
    assert {:error, :timeout} =
             SessionDirectory.list(%{}, ctx.context,
               deadline: System.monotonic_time(:millisecond) - 1
             )
  end

  defp persist(fields) do
    id = Map.get(fields, :id, Ecto.UUID.generate())

    :ok =
      Store.put_meta(
        id,
        Map.merge(%{id: id, agent: "main", config: %{"ordinary_setting" => "value"}}, fields)
      )

    on_exit(fn -> Store.delete_session(id) end)
    id
  end
end
