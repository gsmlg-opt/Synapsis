defmodule Synapsis.SwarmTest do
  use ExUnit.Case, async: false

  alias Synapsis.Swarm

  @table :synapsis_swarm_teammates

  setup do
    session = Ecto.UUID.generate()
    other = Ecto.UUID.generate()

    on_exit(fn ->
      for id <- [session, other], do: :ets.delete(@table, id)
    end)

    %{session: session, other: other}
  end

  test "metadata uses the core-owned table and preserves legacy records", ctx do
    assert :ets.info(@table, :owner) == Process.whereis(Synapsis.Swarm.Store)

    legacy = %{
      id: Ecto.UUID.generate(),
      name: "legacy",
      prompt: "saved",
      tools: ["file_read"],
      model: nil,
      status: "active"
    }

    :ets.insert(@table, {ctx.session, %{"legacy" => legacy}})
    assert {:ok, ^legacy} = Swarm.teammate(ctx.session, %{"action" => "get", "name" => "legacy"})
    assert {:ok, created} = Swarm.teammate(ctx.session, %{"action" => "create", "name" => "new"})
    assert created.status == "configured"
    assert created.tools == ~w(file_read list_dir grep glob)
    assert {:ok, records} = Swarm.teammate(ctx.session, %{"action" => "list"})
    assert Enum.sort(Enum.map(records, & &1.name)) == ["legacy", "new"]
  end

  test "CRUD changes saved metadata without starting or terminating agents", ctx do
    assert {:ok, created} =
             Swarm.teammate(ctx.session, %{
               "action" => "create",
               "name" => "worker",
               "prompt" => "first",
               "tools" => ["saved_tool"],
               "model" => "provider/model"
             })

    assert {:ok, updated} =
             Swarm.teammate(ctx.session, %{
               "action" => "update",
               "name" => "worker",
               "prompt" => "second"
             })

    assert updated == %{created | prompt: "second"}
    assert {:ok, ^updated} = Swarm.teammate(ctx.session, %{"action" => "get", "name" => "worker"})
    assert {:ok, []} = Swarm.teammate(ctx.other, %{"action" => "list"})
    probe = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(probe, :kill) end)
    assert {:ok, %{count: 1}} = Swarm.delete_team(ctx.session)
    assert Process.alive?(probe)
    assert {:ok, []} = Swarm.teammate(ctx.session, %{"action" => "list"})
    assert {:ok, %{count: 0}} = Swarm.delete_team(ctx.session)

    assert {:error, :not_found} =
             Swarm.teammate(ctx.session, %{"action" => "get", "name" => "worker"})
  end

  test "message is only a session-scoped PubSub notification from the trusted sender", ctx do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "swarm:#{ctx.session}:recipient")
    reply = Ecto.UUID.generate()

    assert {:ok, %{message_id: id, status: "published", to: "recipient"}} =
             Swarm.message(ctx.session, "configured-sender", %{
               "to" => "recipient",
               "content" => "hello",
               "type" => "request",
               "in_reply_to" => reply
             })

    assert {:ok, ^id} = Ecto.UUID.cast(id)

    assert_receive {:swarm_message,
                    %{
                      id: ^id,
                      from: "configured-sender",
                      to: "recipient",
                      content: "hello",
                      type: "request",
                      in_reply_to: ^reply
                    }}

    assert {:ok, []} = Swarm.teammate(ctx.session, %{"action" => "list"})
  end

  test "validation rejects model authority, invalid domain IDs and unbounded values", ctx do
    for args <- [
          %{},
          %{"to" => "target", "content" => "hello", "from" => "forged"},
          %{"to" => "target", "content" => "hello", "session_id" => ctx.other},
          %{"to" => "", "content" => "hello"},
          %{"to" => "target", "content" => <<255>>},
          %{"to" => "target", "content" => String.duplicate("x", 32769)},
          %{"to" => "target", "content" => "hello", "type" => "activate"}
        ] do
      assert {:error, :invalid_input} = Swarm.message(ctx.session, "sender", args)
    end

    for args <- [
          %{"action" => "get"},
          %{"action" => "update", "name" => "unknown", "session_id" => ctx.other},
          %{"action" => "create", "name" => " "},
          %{"action" => "create", "tools" => [123]},
          %{"action" => "spawn", "name" => "forbidden"}
        ] do
      assert {:error, :invalid_input} = Swarm.teammate(ctx.session, args)
    end

    assert {:error, :invalid_scope} = Swarm.teammate("/root/child:1", %{"action" => "list"})

    assert {:error, :invalid_scope} =
             Swarm.message(ctx.session, " ", %{"to" => "target", "content" => "hello"})

    assert {:error, :invalid_scope} = Swarm.delete_team("opaque-run")
    assert :ets.lookup(@table, ctx.session) == []
  end

  test "concurrent domain updates do not lose metadata entries", ctx do
    results =
      1..20
      |> Task.async_stream(
        fn n -> Swarm.teammate(ctx.session, %{"action" => "create", "name" => "worker-#{n}"}) end,
        max_concurrency: 20,
        timeout: 3_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert {:ok, records} = Swarm.teammate(ctx.session, %{"action" => "list"})
    assert length(records) == 20
  end

  test "lock contention expires once and cannot apply a late metadata mutation", ctx do
    started = System.monotonic_time(:millisecond)

    :global.trans(
      {{Swarm, ctx.session}, self()},
      fn ->
        task =
          Task.async(fn ->
            Swarm.teammate(ctx.session, %{"action" => "create", "name" => "late"})
          end)

        assert {:error, :timeout} = Task.await(task, 1_500)
      end,
      [node()],
      0
    )

    assert System.monotonic_time(:millisecond) - started < 1_500
    assert :ets.lookup(@table, ctx.session) == []
  end

  test "bounded metadata rejection leaves the previous complete state intact", ctx do
    for n <- 1..7 do
      assert {:ok, _} =
               Swarm.teammate(ctx.session, %{
                 "action" => "create",
                 "name" => "large-#{n}",
                 "prompt" => String.duplicate("p", 8192)
               })
    end

    previous = :ets.lookup(@table, ctx.session)

    assert {:error, :output_limit} =
             Swarm.teammate(ctx.session, %{
               "action" => "create",
               "name" => "too-large",
               "prompt" => String.duplicate("p", 8192)
             })

    assert :ets.lookup(@table, ctx.session) == previous
  end
end
