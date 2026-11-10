defmodule Synapsis.Agent.Tools.SkillBodyCacheFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.Tools.SkillBodyCache
  alias Synapsis.SkillSearch

  test "actual owner publishes once, a second caller joins and later callers reuse the view" do
    {session, binding} = native_session()
    catalog_id = make_ref()
    assert {:ok, resource} = SkillBodyCache.start(binding, catalog_id)
    assert is_pid(resource.pid)
    assert {:owner, claim} = SkillBodyCache.claim(resource, catalog_id)
    owner = self()

    waiter =
      Task.async(fn ->
        assert {:join, ref} = SkillBodyCache.claim(resource, catalog_id)
        send(owner, {:body_cache_joined, self()})
        SkillBodyCache.await(resource, ref, 5_000)
      end)

    waiter_pid = waiter.pid
    assert_receive {:body_cache_joined, ^waiter_pid}, 5_000
    view = view()
    assert :ok = SkillBodyCache.complete(resource, claim, view)
    assert Task.await(waiter, 5_000) == {:ok, view}
    assert SkillBodyCache.claim(resource, catalog_id) == {:ready, view}
    pid = resource.pid
    monitor = Process.monitor(pid)
    assert :ok = SkillBodyCache.release(resource)
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 5_000
    assert reason in [:normal, :shutdown]
    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  test "ordinary native Session close owns cleanup of the ready catalog cache" do
    {session, binding} = native_session()
    catalog_id = make_ref()
    assert {:ok, resource} = SkillBodyCache.start(binding, catalog_id)
    assert {:owner, claim} = SkillBodyCache.claim(resource, catalog_id)
    view = view()
    assert :ok = SkillBodyCache.complete(resource, claim, view)
    assert SkillBodyCache.claim(resource, catalog_id) == {:ready, view}
    pid = resource.pid
    monitor = Process.monitor(pid)
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 5_000
    assert reason in [:normal, :shutdown]
  end

  defp native_session do
    session = start_supervised!({Session, owner_pid: self()})

    authority = %{
      caller: "body-cache-ordinary",
      run_id: Ecto.UUID.generate(),
      grants: [],
      tool_revision: 1,
      tool_revisions: %{}
    }

    assert {:ok, binding} = Session.bind(session, authority)
    {session, binding}
  end

  defp view do
    %{
      snapshot: %{agent_id: Ecto.UUID.generate(), assignment_ids: [], bindings: []},
      index: SkillSearch.prepare_bodies([]),
      coverage: %{bodyIndexed: 0, metadataOnly: 0, truncatedBodies: 0}
    }
  end
end
