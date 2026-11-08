defmodule Synapsis.SessionPresenceTest do
  use ExUnit.Case, async: false

  alias Synapsis.Session.{Store}
  alias Synapsis.SessionPresence

  @registry Synapsis.SessionPresenceTest.Registry

  defmodule FailedStore do
    def get_meta(_), do: {:error, {:storage_unavailable, "private credential diagnostic"}}
    def get_meta(id, _opts), do: get_meta(id)
    def list_session_ids(_opts), do: get_meta(nil)
  end

  defmodule MalformedStore do
    def get_meta(_), do: {:ok, %{agent: %{token: "private owner payload"}}}
    def get_meta(id, _opts), do: get_meta(id)
  end

  defmodule ScanLimitStore do
    def list_session_ids(_), do: {:error, :scan_limit}
  end

  defmodule EnumerationStore do
    def list_session_ids(opts) do
      state = Agent.get(__MODULE__, & &1)
      send(state.owner, {:candidate_page, opts})
      pause(state, :page)
      ids = Enum.filter(state.ids, &(is_nil(opts[:cursor]) or &1 > opts[:cursor]))
      selected = Enum.take(ids, opts[:limit])
      more = length(ids) > length(selected)

      {:ok,
       %{
         session_ids: selected,
         has_more: more,
         next_cursor: if(more, do: List.last(selected)),
         truncated: false
       }}
    end

    def get_meta(id, opts) do
      state = Agent.get(__MODULE__, & &1)
      send(state.owner, {:owner_read, id, opts})
      pause(state, :metadata)
      Map.get(state.metas, id, {:error, :not_found})
    end

    def get_meta(_), do: raise("metadata reads must have an explicit timeout")
    def list_metas, do: raise("enumeration must not materialize sessions")

    defp pause(state, operation) do
      if state[:block] == operation do
        send(state.owner, {:enumeration_reader, self()})

        receive do
          :release -> :ok
        end
      end

      if state[:delay], do: Process.sleep(state.delay)
    end
  end

  defmodule BlockingStore do
    def get_meta(id, _opts), do: get_meta(id)

    def get_meta(id) do
      [{owner, _}] = Registry.lookup(Synapsis.SessionPresenceTest.Registry, id)
      send(owner, {:metadata_reader, self()})

      receive do
        :release -> {:ok, %{agent: "configured owner"}}
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  setup do
    assert Code.ensure_loaded?(SessionPresence),
           "bounded session presence domain is not implemented"

    :ok = Store.ensure_started()
    start_supervised!({Registry, keys: :unique, name: @registry, partitions: 2})
    id = Ecto.UUID.generate()
    context = %{session_id: id, agent_id: "configured observer #{id}"}
    on_exit(fn -> Store.delete_session(id) end)
    %{context: context, opts: [registry: @registry]}
  end

  test "get observes UUID registration and raw persisted owner without metadata or PID leakage",
       ctx do
    :ok =
      Store.put_meta(ctx.context.session_id, %{
        id: ctx.context.session_id,
        agent: "configured owner",
        provider: %{token: "private provider credential"}
      })

    {:ok, _} =
      Registry.register(@registry, ctx.context.session_id, %{
        agent_id: "misleading registry owner",
        token: "private registry metadata",
        pid: self()
      })

    assert {:ok, %{session: session}} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               ctx.opts
             )

    assert session == %{
             session_id: ctx.context.session_id,
             kind: "session_worker",
             registered: true,
             alive: true,
             owner_agent_id: "configured owner",
             owner_known: true
           }

    output = Jason.encode!(session)
    refute output =~ "private"
    refute output =~ "misleading"
    refute output =~ "pid"
    refute output =~ inspect(self())
  end

  test "get distinguishes missing registration and missing owner metadata", ctx do
    missing = Ecto.UUID.generate()

    assert {:ok, %{session: session}} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => missing},
               ctx.context,
               ctx.opts
             )

    assert session == %{
             session_id: missing,
             kind: "session_worker",
             registered: false,
             alive: false,
             owner_agent_id: nil,
             owner_known: false
           }

    {:ok, _} = Registry.register(@registry, ctx.context.session_id, nil)

    assert {:ok, %{session: %{registered: true, alive: true, owner_known: false}}} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               ctx.opts
             )
  end

  test "registration observation changes after process exit without worker calls", ctx do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(@registry, ctx.context.session_id, nil)
        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered
    monitor = Process.monitor(pid)

    assert {:ok, %{session: %{registered: true, alive: true}}} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               ctx.opts
             )

    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    eventually(fn -> Registry.lookup(@registry, ctx.context.session_id) == [] end)

    assert {:ok, %{session: %{registered: false, alive: false}}} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               ctx.opts
             )
  end

  test "build-agent status remains explicitly unsupported and optional session is observation only",
       ctx do
    assert {:ok, result} = SessionPresence.status(%{}, ctx.context, ctx.opts)
    assert result.build_agents_supported == false
    assert result.agents == []
    assert result.message == "Build Agent system not yet implemented."
    refute Map.has_key?(result, :session)
    {:ok, _} = Registry.register(@registry, ctx.context.session_id, nil)

    assert {:ok, %{build_agents_supported: false, agents: [], session: session}} =
             SessionPresence.status(
               %{"session_id" => ctx.context.session_id},
               ctx.context,
               ctx.opts
             )

    assert session.registered
    assert session.alive
    refute Map.has_key?(session, :running)
    refute Map.has_key?(session, :children)
    refute Map.has_key?(session, :status)
  end

  test "unknown exact type returns empty discovery rather than matching metadata text", ctx do
    {:ok, _} = Registry.register(@registry, ctx.context.session_id, %{type: "build_agent"})

    for type <- ["build_agent", "worker", "session"] do
      assert {:ok, %{sessions: [], count: 0}} =
               SessionPresence.discover(
                 %{"action" => "list", "type" => type},
                 ctx.context,
                 ctx.opts
               )
    end
  end

  test "list skips inactive persisted candidates and only exposes live registration observations",
       ctx do
    [inactive, first, orphan, second] = ids(4)

    enumeration_store([inactive, first, orphan, second], %{
      first => {:ok, %{agent: "configured owner", token: "private metadata"}},
      second => {:ok, %{agent: "another owner"}}
    })

    for id <- [first, second],
        do: Registry.register(@registry, id, %{agent_id: "forged owner", pid: self()})

    assert {:ok, result} = discover_page(ctx, %{"action" => "list", "limit" => 2})
    assert Enum.map(result.sessions, & &1.session_id) == [first, second]
    assert result.count == 2
    assert result.has_more == false
    assert result.next_cursor == nil
    assert result.truncated == false
    assert Enum.all?(result.sessions, &(&1.registered and &1.alive))
    assert Enum.map(result.sessions, & &1.owner_agent_id) == ["configured owner", "another owner"]
    refute Jason.encode!(result) =~ ~r/private|forged|pid/
    refute_received {:owner_read, ^inactive, _}
    refute_received {:owner_read, ^orphan, _}
  end

  test "owner filtering uses raw persisted Agent identity and continues past nonmatches", ctx do
    [inactive, wrong, first, second] = ids(4)

    enumeration_store([inactive, wrong, first, second], %{
      inactive => {:ok, %{agent: "configured owner"}},
      wrong => {:ok, %{agent: "different owner"}},
      first => {:ok, %{agent: "configured owner"}},
      second => {:ok, %{agent: "configured owner"}}
    })

    for id <- [wrong, first, second],
        do: Registry.register(@registry, id, %{agent_id: "configured owner"})

    args = %{"action" => "find_by_agent", "owner_agent_id" => "configured owner", "limit" => 1}
    assert {:ok, page} = discover_page(ctx, args)
    assert Enum.map(page.sessions, & &1.session_id) == [first]
    assert page.has_more
    assert page.next_cursor == first
    refute page.truncated

    assert {:ok, last} = discover_page(ctx, Map.put(args, "cursor", page.next_cursor))
    assert Enum.map(last.sessions, & &1.session_id) == [second]
    refute last.has_more
    assert last.next_cursor == nil
  end

  test "empty and exact-limit pages report the actual end without duplicate continuation", ctx do
    [first, second] = ids(2)
    enumeration_store([first, second], %{})
    for id <- [first, second], do: Registry.register(@registry, id, nil)

    assert {:ok, page} = discover_page(ctx, %{"action" => "list", "limit" => 2})
    assert Enum.map(page.sessions, & &1.session_id) == [first, second]
    refute page.has_more
    assert page.next_cursor == nil

    assert {:ok, %{sessions: [], count: 0, has_more: false, next_cursor: nil}} =
             discover_page(ctx, %{"action" => "list", "cursor" => second})
  end

  test "sparse discovery stops at a bounded candidate budget and advances over examined IDs",
       ctx do
    candidates = ids(2_001)
    enumeration_store(candidates, %{})
    assert {:ok, page} = discover_page(ctx, %{"action" => "list", "limit" => 1})
    assert page.sessions == []
    assert page.count == 0
    assert page.has_more
    assert page.truncated
    assert page.next_cursor in candidates
    assert page.next_cursor != List.last(candidates)

    assert {:ok, next} =
             discover_page(ctx, %{"action" => "list", "limit" => 1, "cursor" => page.next_cursor})

    assert next.next_cursor == nil or next.next_cursor > page.next_cursor
    refute_received {:owner_read, _, _}
  end

  test "enumeration storage failures are explicit and redact private diagnostics", ctx do
    for action <- [
          %{"action" => "list"},
          %{"action" => "find_by_agent", "owner_agent_id" => "configured owner"}
        ] do
      assert {:error, :storage_unavailable} =
               SessionPresence.discover(action, ctx.context,
                 registry: @registry,
                 store: FailedStore
               )
    end

    assert {:error, :scan_limit} =
             SessionPresence.discover(%{"action" => "list"}, ctx.context,
               registry: @registry,
               store: ScanLimitStore
             )
  end

  test "list fails explicitly when a registered candidate has malformed owner metadata", ctx do
    [id] = ids(1)
    enumeration_store([id], %{id => {:ok, %{agent: %{token: "private owner"}}}})
    {:ok, _} = Registry.register(@registry, id, nil)

    assert {:error, :malformed_metadata} = discover_page(ctx, %{"action" => "list"})
  end

  test "all enumeration reads share one absolute deadline and explicit remaining budgets", ctx do
    candidates = ids(10)

    enumeration_store(candidates, Map.new(candidates, &{&1, {:ok, %{agent: "different"}}}),
      delay: 35
    )

    for id <- candidates, do: Registry.register(@registry, id, nil)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             discover_page(ctx, %{"action" => "find_by_agent", "owner_agent_id" => "wanted"},
               deadline: started + 150
             )

    assert System.monotonic_time(:millisecond) - started < 1_000
    assert_receive {:candidate_page, opts}
    assert opts[:deadline] == started + 150
    assert_receive {:owner_read, _, metadata_opts}
    assert is_integer(metadata_opts[:timeout]) and metadata_opts[:timeout] in 1..150
  end

  test "deadline and caller loss terminate linked enumeration readers", ctx do
    enumeration_store(ids(1), %{}, block: :page)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             discover_page(ctx, %{"action" => "list"}, deadline: started + 100)

    assert_receive {:enumeration_reader, reader}
    refute Process.alive?(reader)

    owner = spawn(fn -> discover_page(ctx, %{"action" => "list"}) end)
    assert_receive {:enumeration_reader, reader}, 1_000
    monitor = Process.monitor(reader)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}, 1_000
  end

  test "registry and metadata failures are explicit, never successful emptiness", ctx do
    assert {:error, :registry_unavailable} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               registry: Synapsis.SessionPresenceTest.MissingRegistry
             )

    assert {:error, :storage_unavailable} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               Keyword.put(ctx.opts, :store, FailedStore)
             )

    assert {:error, :malformed_metadata} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               Keyword.put(ctx.opts, :store, MalformedStore)
             )

    assert {:ok, %{build_agents_supported: false}} =
             SessionPresence.status(%{}, ctx.context,
               registry: Synapsis.SessionPresenceTest.MissingRegistry
             )

    assert {:error, :registry_unavailable} =
             SessionPresence.status(%{"session_id" => ctx.context.session_id}, ctx.context,
               registry: Synapsis.SessionPresenceTest.MissingRegistry
             )
  end

  test "short absolute deadline terminates the linked metadata reader", ctx do
    {:ok, _} = Registry.register(@registry, ctx.context.session_id, nil)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               registry: @registry,
               store: BlockingStore,
               deadline: started + 250
             )

    assert System.monotonic_time(:millisecond) - started < 2_000
    assert_receive {:metadata_reader, reader}
    refute Process.alive?(reader)
  end

  test "caller cancellation also terminates its in-flight metadata reader", ctx do
    {:ok, _} = Registry.register(@registry, ctx.context.session_id, nil)

    owner =
      spawn(fn ->
        SessionPresence.discover(
          %{"action" => "get", "agent_id" => ctx.context.session_id},
          ctx.context,
          registry: @registry,
          store: BlockingStore
        )
      end)

    assert_receive {:metadata_reader, reader}, 1_000
    monitor = Process.monitor(reader)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}
    assert_receive {:DOWN, ^monitor, :process, ^reader, :killed}, 1_000
  end

  test "closed input, exact UUID selectors and bounds cannot select runtime identities or backends",
       ctx do
    for input <- [
          %{"action" => "get", "agent_id" => "/root/child:1"},
          %{"action" => "get"},
          %{"action" => "find_by_agent"},
          %{"action" => "list", "limit" => 101},
          %{"action" => "list", "limit" => 0},
          %{"action" => "list", "cursor" => "opaque-runtime-run"},
          %{"action" => "list", "type" => "build_agent", "limit" => 101},
          %{"action" => "list", "owner_agent_id" => String.duplicate("x", 257)},
          %{"action" => "list", "registry" => "another"},
          %{"action" => "list", "session_id" => Ecto.UUID.generate()}
        ] do
      assert {:error, :invalid_input} = SessionPresence.discover(input, ctx.context, ctx.opts)
    end

    for input <- [
          %{"session_id" => "/root/child:1"},
          %{"agent_id" => "forged"},
          %{"registry" => "another"}
        ] do
      assert {:error, :invalid_input} = SessionPresence.status(input, ctx.context, ctx.opts)
    end

    assert {:error, :invalid_context} =
             SessionPresence.status(%{}, %{ctx.context | agent_id: ""}, ctx.opts)

    assert {:error, :timeout} =
             SessionPresence.discover(
               %{"action" => "get", "agent_id" => ctx.context.session_id},
               ctx.context,
               Keyword.put(ctx.opts, :deadline, System.monotonic_time(:millisecond) - 1)
             )
  end

  defp enumeration_store(ids, metas, opts \\ []) do
    state = Map.merge(%{ids: ids, metas: metas, owner: self()}, Map.new(opts))
    pid = start_supervised!({Agent, fn -> state end})
    Process.register(pid, EnumerationStore)
  end

  defp discover_page(ctx, args, opts \\ []) do
    SessionPresence.discover(
      args,
      ctx.context,
      Keyword.merge([registry: @registry, store: EnumerationStore], opts)
    )
  end

  defp ids(count) do
    prefix = Ecto.UUID.generate() |> String.slice(0, 24)

    for n <- 1..count,
        do:
          prefix <>
            (n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0"))
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts),
    do:
      if(fun.(),
        do: :ok,
        else:
          receive do
          after
            10 -> eventually(fun, attempts - 1)
          end
      )
end
