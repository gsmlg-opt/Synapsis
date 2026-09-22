defmodule Synapsis.Agent.RunsIdentityTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.{RunEvents, Runs}

  @attrs %{
    kind: "manual",
    source: "web",
    prompt: "Identity regression",
    tool_profile: "read_only"
  }

  for key <- [:id, "id"] do
    test "preserves a supplied #{inspect(key)} during creation and transitions" do
      id = Ecto.UUID.generate()
      assert {:ok, run} = Runs.create(Map.put(@attrs, unquote(key), id))
      assert run.id == id
      assert {:ok, ^run} = Runs.fetch(id)
      assert Enum.all?(RunEvents.list_for_run(id), &(&1["run_id"] == id))

      other_id = Ecto.UUID.generate()
      assert {:ok, running} = Runs.mark_running(run, %{unquote(key) => other_id})
      assert running.id == id
      assert {:ok, completed} = Runs.mark_completed(running, "done", %{unquote(key) => other_id})
      assert completed.id == id
      assert Runs.get(id).status == "completed"
      assert Runs.get(other_id) == nil
    end

    test "validates a supplied #{inspect(key)} as a UUID" do
      assert {:error, changeset} = Runs.create(Map.put(@attrs, unquote(key), "invalid-id"))
      assert Keyword.has_key?(changeset.errors, :id)
      assert Runs.get("invalid-id") == nil
    end
  end

  test "generates an ID when none is supplied" do
    assert {:ok, run} = Runs.create(@attrs)
    assert {:ok, _} = Ecto.UUID.cast(run.id)
    assert {:ok, ^run} = Runs.fetch(run.id)
  end

  test "duplicate creation cannot reset a terminal run or append another creation event" do
    id = Ecto.UUID.generate()
    attrs = Map.put(@attrs, :id, id)
    assert {:ok, created} = Runs.create(attrs)
    assert {:ok, running} = Runs.mark_running(created)
    assert {:ok, completed} = Runs.mark_completed(running, "original completion")
    events = RunEvents.list_for_run(id)

    assert {:error, :already_exists} = Runs.create(%{attrs | prompt: "replacement"})
    assert Runs.get(id) == completed
    assert RunEvents.list_for_run(id) == events
  end

  test "concurrent creation of one ID has one winner" do
    id = Ecto.UUID.generate()
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      for prompt <- ["first", "second"] do
        Task.Supervisor.async_nolink(supervisor, fn ->
          receive do
            :go -> Runs.create(Map.merge(@attrs, %{id: id, prompt: prompt}))
          after
            1_000 -> {:error, :fixture_timeout}
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 2_000))
    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert [{:error, :already_exists}] = Enum.filter(results, &match?({:error, _}, &1))
    assert winner.id == id
    assert Runs.get(id) == winner
    assert [%{"type" => "run.created"}] = RunEvents.list_for_run(id)
  end

  test "an existing idempotency key still resolves to its original identity" do
    attrs = Map.put(@attrs, :idempotency_key, Ecto.UUID.generate())
    assert {:ok, first} = Runs.create(Map.put(attrs, :id, Ecto.UUID.generate()))
    unused_id = Ecto.UUID.generate()
    assert {:ok, ^first} = Runs.create(Map.put(attrs, :id, unused_id))
    assert Runs.get(unused_id) == nil
  end
end
