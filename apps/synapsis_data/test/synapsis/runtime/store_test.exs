defmodule Synapsis.Runtime.StoreTest do
  use ExUnit.Case, async: false

  alias Synapsis.Runtime.Store

  setup do
    :ok = Synapsis.Session.Store.ensure_started()
    %{namespace: Ecto.UUID.generate()}
  end

  test "aggregate commits atomically and rejects stale revision and incarnation", %{namespace: ns} do
    first = %{
      revision: 1,
      incarnation: 4,
      run: %{state: :running, context: String.duplicate("context", 1_000)},
      outbox: [:admit]
    }

    assert :not_found = Store.load(ns, "run")
    assert :ok = Store.commit(ns, "run", 0, 4, first)
    assert {:ok, ^first} = Store.load(ns, "run")
    assert {:error, :resource_conflict} = Store.commit(ns, "run", 0, 4, first)

    fenced = %{first | revision: 2, incarnation: 5}
    assert :ok = Store.commit(ns, "run", 1, 4, fenced)
    stale = %{first | revision: 3}
    assert {:error, :resource_conflict} = Store.commit(ns, "run", 2, 4, stale)
    assert {:ok, ^fenced} = Store.load(ns, "run")
  end

  test "only one concurrent writer wins", %{namespace: ns} do
    snapshot = %{revision: 1, incarnation: 1, run: %{}, outbox: []}

    results =
      1..8
      |> Task.async_stream(fn _ -> Store.commit(ns, "race", 0, 1, snapshot) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :resource_conflict})) == 7
  end

  test "facts are immutable, idempotent, and isolated by session and kind", %{namespace: id} do
    fact = %{child: "child", status: :admitted, prompt: String.duplicate("context", 1_000)}
    assert :ok = Store.put_fact(id, :admission, "event-1", fact)
    assert :ok = Store.put_fact(id, :admission, "event-1", fact)
    assert {:error, :fact_conflict} = Store.put_fact(id, :admission, "event-1", %{other: true})
    assert {:ok, [^fact]} = Store.list_facts(id, :admission)
    assert {:ok, []} = Store.list_facts(id, :completion)
    assert {:ok, []} = Store.list_facts(id <> "other", :admission)
  end

  test "projection writes acknowledge the complete value including large payloads", %{
    namespace: id
  } do
    value = %{roster: [%{prompt: String.duplicate("context", 1_000)}]}
    assert :not_found = Store.get_projection(id)
    assert :ok = Store.put_projection(id, value)
    assert {:ok, ^value} = Store.get_projection(id)
  end
end
