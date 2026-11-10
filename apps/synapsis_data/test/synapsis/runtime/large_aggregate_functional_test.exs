defmodule Synapsis.Runtime.LargeAggregateFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Runtime.Store

  test "complete large aggregates preserve their history and outbox through successive commits" do
    assert :ok = Synapsis.Session.Store.ensure_started()
    namespace = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    first_payload = :crypto.strong_rand_bytes(1_100_000)
    next_payload = :crypto.strong_rand_bytes(1_200_000)

    # Advance storage independently of the aggregate's logical revision.
    fact = %{run_id: run_id, event: :admitted}
    assert :ok = Store.put_fact(namespace, :qualification, run_id, fact)
    assert {:ok, ^fact} = Store.get_fact(namespace, :qualification, run_id)

    first = %{
      revision: 1,
      incarnation: 1,
      run: %{run_id: run_id, state: :running, history: [first_payload]},
      transition: %{event: :tool_invoked},
      effects: [],
      outbox: [%{id: "first-intent", arguments: %{payload: first_payload}}]
    }

    assert :erlang.external_size(first) > 1_000_000
    assert :not_found = Store.load(namespace, run_id)
    assert :ok = Store.commit(namespace, run_id, 0, 1, first)
    assert {:ok, ^first} = Store.load(namespace, run_id)

    next = %{
      first
      | revision: 2,
        run: %{run_id: run_id, state: :completed, history: [first_payload, next_payload]},
        transition: %{event: :tool_completed},
        outbox: [%{id: "second-intent", arguments: %{payload: next_payload}}]
    }

    assert :erlang.external_size(next) > 1_000_000
    assert :ok = Store.commit(namespace, run_id, 1, 1, next)
    assert {:ok, ^next} = Store.load(namespace, run_id)
    assert {:ok, ^next} = Store.load(namespace, run_id)

    projection = %{run_id: run_id, revision: 2}
    assert :ok = Store.put_projection(namespace, projection)
    assert {:ok, ^projection} = Store.get_projection(namespace)
  end
end
