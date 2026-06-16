# Replace `synapsis_plugin` with `anubis_mcp` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-rolled MCP client with the `anubis_mcp` library in a new `synapsis_mcp` app, move the sandbox bridge to a new `synapsis_sandbox` app, remove LSP and the plugin framework, and delete the `synapsis_plugin` umbrella app.

**Architecture:** One `Anubis.Client` per configured MCP server, each owned by a `Synapsis.MCP.Server` GenServer under a `DynamicSupervisor` + `Registry`. The server discovers tools via `Anubis.Client.list_tools/1` and registers them into `Synapsis.Tool.Registry` as process-dispatch tools that route `call_tool` back to its `Anubis.Client`. `Synapsis.Tool.Registry` gains a pid monitor so dead tool owners are auto-purged (root-cause fix for the restart-leaves-stale-tools bug).

**Tech Stack:** Elixir umbrella, `anubis_mcp ~> 1.6`, `Req`, `Bypass` (tests), Phoenix LiveView (web), `Synapsis.Config.Store` (TOML), Concord.

**Spec:** `docs/superpowers/specs/2026-06-15-replace-synapsis-plugin-with-anubis-mcp-design.md`

---

## Sequencing notes

- Phases 1–3 are additive and safe to land while `synapsis_plugin` still exists.
- Phase 4 (wire-in + removals) is the cutover; do it only after Phases 1–3 are green.
- Run all `mix` commands from the umbrella root unless noted.
- The earlier loose change in `apps/synapsis_plugin/lib/synapsis_plugin/server.ex`
  (`Process.flag(:trap_exit, true)`) is removed when that file is deleted in Task 16;
  no separate revert needed.

---

## Phase 0 — Scaffolding

### Task 1: Create the `synapsis_mcp` app skeleton with the `anubis_mcp` dep

**Files:**
- Create: `apps/synapsis_mcp/mix.exs`
- Create: `apps/synapsis_mcp/lib/synapsis_mcp/application.ex`
- Create: `apps/synapsis_mcp/test/test_helper.exs`
- Modify: `mix.lock` (via `mix deps.get`)

- [ ] **Step 1: Create `apps/synapsis_mcp/mix.exs`**

```elixir
defmodule SynapsisMcp.MixProject do
  use Mix.Project

  def project do
    [
      app: :synapsis_mcp,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SynapsisMcp.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_core, in_umbrella: true},
      {:synapsis_data, in_umbrella: true},
      {:anubis_mcp, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
```

- [ ] **Step 2: Create `apps/synapsis_mcp/lib/synapsis_mcp/application.ex`**

```elixir
defmodule SynapsisMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Synapsis.MCP.Supervisor]
    opts = [strategy: :one_for_one, name: SynapsisMcp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

> Note: `Synapsis.MCP.Supervisor` is created in Task 9. Until then this app will not
> compile if started; that's fine because nothing depends on it yet.

- [ ] **Step 3: Create `apps/synapsis_mcp/test/test_helper.exs`**

```elixir
ExUnit.start()
```

- [ ] **Step 4: Fetch deps**

Run: `mix deps.get`
Expected: resolves and downloads `anubis_mcp` 1.6.x; updates `mix.lock`.

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_mcp/mix.exs apps/synapsis_mcp/lib apps/synapsis_mcp/test mix.lock
git commit -m "chore(mcp): scaffold synapsis_mcp app with anubis_mcp dep"
```

---

### Task 2: Create the `synapsis_sandbox` app skeleton

**Files:**
- Create: `apps/synapsis_sandbox/mix.exs`
- Create: `apps/synapsis_sandbox/lib/synapsis_sandbox/application.ex`
- Create: `apps/synapsis_sandbox/test/test_helper.exs`

- [ ] **Step 1: Create `apps/synapsis_sandbox/mix.exs`**

```elixir
defmodule SynapsisSandbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :synapsis_sandbox,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {SynapsisSandbox.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:synapsis_core, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
```

- [ ] **Step 2: Create `apps/synapsis_sandbox/lib/synapsis_sandbox/application.ex`**

```elixir
defmodule SynapsisSandbox.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: SynapsisSandbox.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 3: Create `apps/synapsis_sandbox/test/test_helper.exs`**

```elixir
ExUnit.start()
```

- [ ] **Step 4: Compile to verify the umbrella picks up both new apps**

Run: `mix compile`
Expected: compiles (new apps have no real modules yet).

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_sandbox mix.lock
git commit -m "chore(sandbox): scaffold synapsis_sandbox app"
```

---

## Phase 1 — Root-cause registry fix (independent, in `synapsis_core`)

### Task 3: `Synapsis.Tool.Registry` auto-purges tools when the owning pid dies

**Files:**
- Modify: `apps/synapsis_core/lib/synapsis/tool/registry.ex`
- Test: `apps/synapsis_core/test/synapsis/tool/registry_monitor_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/synapsis_core/test/synapsis/tool/registry_monitor_test.exs`:

```elixir
defmodule Synapsis.Tool.RegistryMonitorTest do
  use ExUnit.Case, async: false

  alias Synapsis.Tool.Registry

  test "process-registered tools are purged when the owner dies" do
    name = "mon_tool_#{System.unique_integer([:positive])}"

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    :ok = Registry.register_process(name, owner, description: "x", parameters: %{})
    assert {:ok, _} = Registry.lookup(name)

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}, 1_000

    # Give the registry a moment to handle its own :DOWN
    Process.sleep(50)
    assert {:error, :not_found} = Registry.lookup(name)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/synapsis_core/test/synapsis/tool/registry_monitor_test.exs`
Expected: FAIL — tool still found after owner dies (no monitor today).

- [ ] **Step 3: Make `register_process/3` notify the GenServer to monitor**

In `apps/synapsis_core/lib/synapsis/tool/registry.ex`, replace `register_process/3`:

```elixir
  @doc "Register a process-based tool (plugin GenServer)."
  def register_process(name, pid, opts \\ []) do
    :ets.insert(@table, {name, {:process, pid, opts}})
    GenServer.cast(__MODULE__, {:monitor, name, pid})
    broadcast_tool_registry_changed(:registered, name)
    :ok
  end
```

- [ ] **Step 4: Track monitors in GenServer state and purge on `:DOWN`**

Replace `init/1` and add the cast/info handlers. Change state from the bare table
to a map `%{table: table, monitors: %{ref => {pid, MapSet.of_names}}, pids: %{pid => ref}}`:

```elixir
  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Synapsis.Tool.Teammate.ensure_table()
    {:ok, %{table: table, monitors: %{}, pids: %{}}}
  end

  @impl true
  def handle_cast({:monitor, name, pid}, state) do
    case Map.get(state.pids, pid) do
      nil ->
        ref = Process.monitor(pid)
        monitors = Map.put(state.monitors, ref, {pid, MapSet.new([name])})
        pids = Map.put(state.pids, pid, ref)
        {:noreply, %{state | monitors: monitors, pids: pids}}

      ref ->
        {pid, names} = Map.fetch!(state.monitors, ref)
        monitors = Map.put(state.monitors, ref, {pid, MapSet.put(names, name)})
        {:noreply, %{state | monitors: monitors}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{^pid, names}, monitors} ->
        Enum.each(names, fn name ->
          :ets.delete(@table, name)
          broadcast_tool_registry_changed(:unregistered, name)
        end)

        {:noreply, %{state | monitors: monitors, pids: Map.delete(state.pids, pid)}}
    end
  end
```

> If any existing code references the GenServer state as a bare `table`, update it.
> Grep first: `grep -n "state" apps/synapsis_core/lib/synapsis/tool/registry.ex`
> (current `init/1` returns just `table`; only `init` uses it, so the change is local).

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/synapsis_core/test/synapsis/tool/registry_monitor_test.exs`
Expected: PASS

- [ ] **Step 6: Run the full core tool tests for regressions**

Run: `mix test apps/synapsis_core/test/synapsis/tool`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add apps/synapsis_core/lib/synapsis/tool/registry.ex apps/synapsis_core/test/synapsis/tool/registry_monitor_test.exs
git commit -m "fix(tools): auto-purge process tools when owner dies"
```

---

## Phase 2 — MCP config schema (`synapsis_data`)

### Task 4: Add a dedicated MCP config schema + store-backed context

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/mcp_config.ex`
- Create: `apps/synapsis_data/lib/synapsis/mcp_configs.ex`
- Test: `apps/synapsis_data/test/synapsis/mcp_configs_test.exs`

**Design:** Reuse the existing `:mcp` store type already declared in
`apps/synapsis_data/lib/synapsis/config/store.ex` (`@types` includes `:mcp`). The new
schema is MCP-only with `transport` in `~w(stdio streamable_http sse)` and a
`headers` map for HTTP transports.

- [ ] **Step 1: Write the failing test**

Create `apps/synapsis_data/test/synapsis/mcp_configs_test.exs`:

```elixir
defmodule Synapsis.MCPConfigsTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCPConfigs

  setup do
    on_exit(fn ->
      for c <- MCPConfigs.list(), do: MCPConfigs.delete(c)
    end)

    :ok
  end

  test "create + get_by_name round-trips a stdio config" do
    {:ok, cfg} =
      MCPConfigs.create(%{
        name: "ctx7_#{System.unique_integer([:positive])}",
        transport: "stdio",
        command: "uvx",
        args: ["mcp-server-context7"],
        env: %{"TOKEN" => "abc"},
        enabled: true
      })

    assert cfg.transport == "stdio"
    assert MCPConfigs.get_by_name(cfg.name).command == "uvx"
  end

  test "rejects unknown transport" do
    {:error, changeset} =
      MCPConfigs.create(%{name: "bad", transport: "carrier-pigeon"})

    assert "is invalid" in errors_on(changeset).transport
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/synapsis_data/test/synapsis/mcp_configs_test.exs`
Expected: FAIL — `Synapsis.MCPConfigs` undefined.

- [ ] **Step 3: Create the schema `apps/synapsis_data/lib/synapsis/mcp_config.ex`**

```elixir
defmodule Synapsis.MCPConfig do
  @moduledoc """
  Configuration for a single MCP server (anubis_mcp client).

  Persisted in the file-backed `Config.Store` (`mcp.toml`). Embedded schema only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_transports ~w(stdio streamable_http sse)

  @primary_key {:id, :binary_id, autogenerate: false}
  embedded_schema do
    field(:name, :string)
    field(:transport, :string, default: "stdio")
    field(:enabled, :boolean, default: true)
    # stdio
    field(:command, :string)
    field(:args, {:array, :string}, default: [])
    field(:env, :map, default: %{})
    # http / sse
    field(:url, :string)
    field(:headers, :map, default: %{})

    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :id,
      :name,
      :transport,
      :enabled,
      :command,
      :args,
      :env,
      :url,
      :headers
    ])
    |> validate_required([:name, :transport])
    |> validate_inclusion(:transport, @valid_transports)
    |> validate_length(:name, max: 255)
    |> validate_length(:command, max: 4_096)
    |> validate_length(:url, max: 2_048)
    |> validate_transport_fields()
  end

  defp validate_transport_fields(changeset) do
    case get_field(changeset, :transport) do
      "stdio" -> validate_required(changeset, [:command])
      t when t in ["streamable_http", "sse"] -> validate_required(changeset, [:url])
      _ -> changeset
    end
  end
end
```

- [ ] **Step 4: Create the context `apps/synapsis_data/lib/synapsis/mcp_configs.ex`**

```elixir
defmodule Synapsis.MCPConfigs do
  @moduledoc """
  Context for MCP server configs, backed by `Config.Store` type `:mcp`.
  """
  alias Synapsis.{Config.Store, MCPConfig}

  @store_type :mcp

  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(& &1.name)
  end

  def enabled, do: Enum.filter(list(), & &1.enabled)

  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  def get_by_name(name), do: Enum.find(list(), &(&1.name == name))

  def create(attrs) when is_map(attrs),
    do: persist(MCPConfig.changeset(%MCPConfig{}, attrs))

  def update(%MCPConfig{} = config, attrs),
    do: persist(MCPConfig.changeset(config, attrs))

  def delete(%MCPConfig{} = config) do
    Store.delete(@store_type, config.id)
    {:ok, config}
  end

  defp persist(%Ecto.Changeset{valid?: true} = changeset) do
    record = changeset |> Ecto.Changeset.apply_changes() |> ensure_id()

    case Store.put(@store_type, to_store_map(record)) do
      :ok -> {:ok, record}
      {:ok, _} -> {:ok, record}
      error -> error
    end
  end

  defp persist(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp ensure_id(%MCPConfig{id: nil} = r), do: %{r | id: Ecto.UUID.generate()}
  defp ensure_id(%MCPConfig{} = r), do: r

  defp to_store_map(%MCPConfig{} = r), do: Map.from_struct(r)

  defp to_struct(map) when is_map(map) do
    MCPConfig.changeset(%MCPConfig{}, map) |> Ecto.Changeset.apply_changes()
  end
end
```

> Verify `Config.Store` maps `:mcp` to a filename. `store.ex:56` shows the `:plugin`
> case; confirm there is an `:mcp -> "mcp.toml"` clause. If missing, add it next to
> the `:plugin -> "plugins.toml"` clause.

- [ ] **Step 5: Ensure `:mcp` has a filename in `Config.Store`**

Run: `grep -n ":mcp ->" apps/synapsis_data/lib/synapsis/config/store.ex`
If absent, add to the filename `case` (near `store.ex:56`):

```elixir
      :mcp -> "mcp.toml"
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test apps/synapsis_data/test/synapsis/mcp_configs_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add apps/synapsis_data/lib/synapsis/mcp_config.ex apps/synapsis_data/lib/synapsis/mcp_configs.ex apps/synapsis_data/lib/synapsis/config/store.ex apps/synapsis_data/test/synapsis/mcp_configs_test.exs
git commit -m "feat(data): add MCP-only config schema (mcp.toml)"
```

---

### Task 5: One-time migration of legacy MCP plugin configs

**Files:**
- Create: `apps/synapsis_data/lib/synapsis/mcp_configs/migration.ex`
- Test: `apps/synapsis_data/test/synapsis/mcp_configs/migration_test.exs`

**Design:** Map legacy `:plugin` records with `type == "mcp"` into the new `:mcp`
store. Transport mapping: `"http" -> "streamable_http"`, `"sse" -> "sse"`,
`"stdio" -> "stdio"`. Legacy headers live under `settings["headers"]`.

- [ ] **Step 1: Write the failing test**

Create `apps/synapsis_data/test/synapsis/mcp_configs/migration_test.exs`:

```elixir
defmodule Synapsis.MCPConfigs.MigrationTest do
  use ExUnit.Case, async: false

  alias Synapsis.{Config.Store, MCPConfigs, MCPConfigs.Migration}

  setup do
    on_exit(fn ->
      for c <- MCPConfigs.list(), do: MCPConfigs.delete(c)
      for m <- Store.list(:plugin), do: Store.delete(:plugin, m["id"] || m[:id])
    end)

    :ok
  end

  test "migrates a legacy http mcp plugin into a streamable_http mcp config" do
    id = Ecto.UUID.generate()

    :ok =
      Store.put(:plugin, %{
        id: id,
        type: "mcp",
        name: "legacy_http",
        transport: "http",
        url: "https://example.com/mcp",
        settings: %{"headers" => %{"Authorization" => "Bearer x"}}
      })

    assert {:ok, 1} = Migration.run()

    cfg = MCPConfigs.get_by_name("legacy_http")
    assert cfg.transport == "streamable_http"
    assert cfg.url == "https://example.com/mcp"
    assert cfg.headers == %{"Authorization" => "Bearer x"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/synapsis_data/test/synapsis/mcp_configs/migration_test.exs`
Expected: FAIL — `Synapsis.MCPConfigs.Migration` undefined.

- [ ] **Step 3: Create `apps/synapsis_data/lib/synapsis/mcp_configs/migration.ex`**

```elixir
defmodule Synapsis.MCPConfigs.Migration do
  @moduledoc """
  One-time migration of legacy `:plugin` (type "mcp") configs into the new
  `:mcp` store. Idempotent: skips names that already exist in the new store.
  """
  alias Synapsis.{Config.Store, MCPConfigs}

  @transport_map %{"http" => "streamable_http", "sse" => "sse", "stdio" => "stdio"}

  @doc "Returns {:ok, migrated_count}."
  def run do
    existing = MapSet.new(MCPConfigs.list(), & &1.name)

    migrated =
      :plugin
      |> Store.list()
      |> Enum.filter(&(get(&1, "type") == "mcp"))
      |> Enum.reject(&MapSet.member?(existing, get(&1, "name")))
      |> Enum.map(&migrate_one/1)
      |> Enum.count(&match?({:ok, _}, &1))

    {:ok, migrated}
  end

  defp migrate_one(legacy) do
    settings = get(legacy, "settings") || %{}

    MCPConfigs.create(%{
      name: get(legacy, "name"),
      transport: Map.get(@transport_map, get(legacy, "transport") || "stdio", "stdio"),
      enabled: get(legacy, "auto_start") || false,
      command: get(legacy, "command"),
      args: get(legacy, "args") || [],
      env: get(legacy, "env") || %{},
      url: get(legacy, "url"),
      headers: Map.get(settings, "headers", %{})
    })
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/synapsis_data/test/synapsis/mcp_configs/migration_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_data/lib/synapsis/mcp_configs/migration.ex apps/synapsis_data/test/synapsis/mcp_configs/migration_test.exs
git commit -m "feat(data): migrate legacy mcp plugin configs to mcp store"
```

---

## Phase 3 — `synapsis_mcp` implementation

### Task 6: Config → Anubis transport tuple (pure function)

**Files:**
- Create: `apps/synapsis_mcp/lib/synapsis/mcp/transport.ex`
- Test: `apps/synapsis_mcp/test/synapsis/mcp/transport_test.exs`

> Verification point: confirm the exact option keys against `Anubis.Transport.STDIO`,
> `Anubis.Transport.StreamableHTTP`, `Anubis.Transport.SSE` docs. The shapes below
> use the documented `{:stdio, command:, args:}`, `{:streamable_http, url:}`,
> `{:sse, base_url:}`; `env`/`headers` are added per transport. If a key name differs
> (e.g. `base_url` vs `url`), fix it here only — this module is the single mapping point.

- [ ] **Step 1: Write the failing test**

Create `apps/synapsis_mcp/test/synapsis/mcp/transport_test.exs`:

```elixir
defmodule Synapsis.MCP.TransportTest do
  use ExUnit.Case, async: true

  alias Synapsis.MCP.Transport
  alias Synapsis.MCPConfig

  test "builds a stdio tuple with command, args, env" do
    cfg = %MCPConfig{transport: "stdio", command: "uvx", args: ["x"], env: %{"K" => "v"}}

    assert {:stdio, opts} = Transport.build(cfg)
    assert opts[:command] == "uvx"
    assert opts[:args] == ["x"]
    assert opts[:env] == %{"K" => "v"}
  end

  test "builds a streamable_http tuple with url and headers" do
    cfg = %MCPConfig{transport: "streamable_http", url: "https://h/mcp", headers: %{"A" => "b"}}

    assert {:streamable_http, opts} = Transport.build(cfg)
    assert opts[:url] == "https://h/mcp"
    assert opts[:headers] == %{"A" => "b"}
  end

  test "builds an sse tuple with base_url and headers" do
    cfg = %MCPConfig{transport: "sse", url: "https://h", headers: %{"A" => "b"}}

    assert {:sse, opts} = Transport.build(cfg)
    assert opts[:base_url] == "https://h"
    assert opts[:headers] == %{"A" => "b"}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp/transport_test.exs`
Expected: FAIL — `Synapsis.MCP.Transport` undefined.

- [ ] **Step 3: Create `apps/synapsis_mcp/lib/synapsis/mcp/transport.ex`**

```elixir
defmodule Synapsis.MCP.Transport do
  @moduledoc """
  Maps a `Synapsis.MCPConfig` to an `Anubis.Client` transport tuple.

  Single source of truth for transport option names; if anubis_mcp changes a
  key, change it here only.
  """
  alias Synapsis.MCPConfig

  @spec build(MCPConfig.t()) :: tuple()
  def build(%MCPConfig{transport: "stdio"} = c) do
    {:stdio, command: c.command, args: c.args || [], env: c.env || %{}}
  end

  def build(%MCPConfig{transport: "streamable_http"} = c) do
    {:streamable_http, url: c.url, headers: c.headers || %{}}
  end

  def build(%MCPConfig{transport: "sse"} = c) do
    {:sse, base_url: c.url, headers: c.headers || %{}}
  end
end
```

> Add `@type t :: %__MODULE__{}` to `Synapsis.MCPConfig` if dialyzer/typespec
> complains; not required for tests to pass.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp/transport_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_mcp/lib/synapsis/mcp/transport.ex apps/synapsis_mcp/test/synapsis/mcp/transport_test.exs
git commit -m "feat(mcp): map config to anubis transport tuple"
```

---

### Task 7: Normalize Anubis responses into tool shapes (pure functions)

**Files:**
- Create: `apps/synapsis_mcp/lib/synapsis/mcp/response.ex`
- Test: `apps/synapsis_mcp/test/synapsis/mcp/response_test.exs`

**Design:** `Anubis.MCP.Response` exposes `.result` (MCP-spec map), `.is_error`, and
helpers `success?/1`/`unwrap/1`. `list_tools` → `result["tools"]`; `call_tool` →
`result["content"]` (list of `%{"type" => "text", "text" => ...}`). We operate on
plain maps so tests don't need the Anubis struct.

- [ ] **Step 1: Write the failing test**

Create `apps/synapsis_mcp/test/synapsis/mcp/response_test.exs`:

```elixir
defmodule Synapsis.MCP.ResponseTest do
  use ExUnit.Case, async: true

  alias Synapsis.MCP.Response

  test "tools/1 maps a tools result to registry tool maps" do
    result = %{
      "tools" => [
        %{"name" => "search", "description" => "find", "inputSchema" => %{"type" => "object"}}
      ]
    }

    assert [tool] = Response.tools(result, "ctx7")
    assert tool.name == "mcp:ctx7:search"
    assert tool.description == "find"
    assert tool.parameters == %{"type" => "object"}
  end

  test "content/1 joins text content blocks" do
    result = %{"content" => [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}]}
    assert Response.content(result) == "a\nb"
  end

  test "content/1 handles missing content" do
    assert Response.content(%{}) == "[no content in MCP response]"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp/response_test.exs`
Expected: FAIL — `Synapsis.MCP.Response` undefined.

- [ ] **Step 3: Create `apps/synapsis_mcp/lib/synapsis/mcp/response.ex`**

```elixir
defmodule Synapsis.MCP.Response do
  @moduledoc "Normalizes anubis_mcp result maps into Synapsis tool shapes."

  @doc "Map a tools/list result map to Synapsis.Tool.Registry tool definitions."
  def tools(result, server_name) when is_map(result) do
    (result["tools"] || [])
    |> Enum.map(fn t ->
      %{
        name: "mcp:#{server_name}:#{t["name"]}",
        description: t["description"] || "",
        parameters: t["inputSchema"] || %{}
      }
    end)
  end

  @doc "Extract text content from a tools/call result map."
  def content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[unsupported content type: #{type}]"
      _ -> "[unsupported content format]"
    end)
    |> Enum.join("\n")
  end

  def content(%{"content" => content}) when is_binary(content), do: content
  def content(_), do: "[no content in MCP response]"

  @doc "Strip the `mcp:<server>:` prefix to recover the raw MCP tool name."
  def raw_tool_name(full_name) do
    case String.split(full_name, ":", parts: 3) do
      [_mcp, _server, name] -> name
      _ -> full_name
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp/response_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/synapsis_mcp/lib/synapsis/mcp/response.ex apps/synapsis_mcp/test/synapsis/mcp/response_test.exs
git commit -m "feat(mcp): normalize anubis responses to tool shapes"
```

---

### Task 8: `Synapsis.MCP.Server` — owns one Anubis client, bridges tools

**Files:**
- Create: `apps/synapsis_mcp/lib/synapsis/mcp/server.ex`
- Test: `apps/synapsis_mcp/test/synapsis/mcp/server_test.exs`
- Test support: `apps/synapsis_mcp/test/support/stdio_echo.exs`

**Design:** A GenServer started with a `%MCPConfig{}`. In `init`, it traps exits,
starts an `Anubis.Client` linked child with the built transport, then continues
async (`{:continue, :discover}`) to `await_ready` + `list_tools` + register. Tools
register as process-dispatch pointing at the server pid. `handle_call({:execute, ...})`
strips the prefix and calls `Anubis.Client.call_tool/3`. `terminate/2` unregisters
(belt-and-suspenders with the Task 3 monitor).

- [ ] **Step 1: Create the stdio echo test server `apps/synapsis_mcp/test/support/stdio_echo.exs`**

A minimal MCP stdio server (newline-delimited JSON-RPC) that answers `initialize`,
`tools/list` (one tool `echo`), and `tools/call` (returns the input text):

```elixir
# Minimal MCP stdio server for tests. Reads line-delimited JSON-RPC on stdin.
defmodule StdioEcho do
  def loop do
    case IO.gets("") do
      :eof ->
        :ok

      line ->
        line |> String.trim() |> handle()
        loop()
    end
  end

  defp handle(""), do: :ok

  defp handle(json) do
    req = Jason.decode!(json)
    case req["method"] do
      "initialize" ->
        reply(req["id"], %{
          "protocolVersion" => "2024-11-05",
          "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "stdio-echo", "version" => "0.1.0"}
        })

      "notifications/initialized" ->
        :ok

      "tools/list" ->
        reply(req["id"], %{
          "tools" => [
            %{"name" => "echo", "description" => "echo", "inputSchema" => %{"type" => "object"}}
          ]
        })

      "tools/call" ->
        text = get_in(req, ["params", "arguments", "text"]) || ""
        reply(req["id"], %{"content" => [%{"type" => "text", "text" => text}]})

      _ ->
        :ok
    end
  end

  defp reply(nil, _result), do: :ok

  defp reply(id, result) do
    IO.puts(Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}))
  end
end

Mix.install([{:jason, "~> 1.4"}])
StdioEcho.loop()
```

> If `Mix.install` is undesirable in CI, instead depend on the umbrella's jason by
> running the script with `elixir -pa _build/...`; simplest is to keep `Mix.install`.
> The exact transport the test uses is decided in Step 2; prefer the Bypass-based
> streamable_http test as the primary coverage and treat stdio as a secondary test
> that can be tagged `@tag :stdio` and excluded in CI if `Mix.install` is slow.

- [ ] **Step 2: Write the failing test (Bypass streamable_http path)**

Create `apps/synapsis_mcp/test/synapsis/mcp/server_test.exs`:

```elixir
defmodule Synapsis.MCP.ServerTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfig
  alias Synapsis.Tool.Registry

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  defp stub_mcp(bypass, server_name) do
    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      result =
        case req["method"] do
          "initialize" ->
            %{"protocolVersion" => "2024-11-05", "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => server_name, "version" => "0"}}

          "tools/list" ->
            %{"tools" => [%{"name" => "echo", "description" => "e", "inputSchema" => %{}}]}

          "tools/call" ->
            %{"content" => [%{"type" => "text", "text" => req["params"]["arguments"]["text"]}]}

          _ ->
            %{}
        end

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result}))
    end)
  end

  test "discovers tools and routes calls", %{bypass: bypass} do
    name = "srv_#{System.unique_integer([:positive])}"
    stub_mcp(bypass, name)

    cfg = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}/mcp"
    }

    {:ok, pid} = Server.start_link(cfg)

    tool = "mcp:#{name}:echo"
    wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)
    assert {:ok, _} = Registry.lookup(tool)

    assert {:ok, "hi"} = GenServer.call(pid, {:execute, tool, %{"text" => "hi"}, %{}})

    GenServer.stop(pid)
    wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
    assert {:error, :not_found} = Registry.lookup(tool)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      tries <= 0 -> :timeout
      fun.() -> :ok
      true -> Process.sleep(20); wait_until(fun, tries - 1)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp/server_test.exs`
Expected: FAIL — `Synapsis.MCP.Server` undefined.

- [ ] **Step 4: Create `apps/synapsis_mcp/lib/synapsis/mcp/server.ex`**

```elixir
defmodule Synapsis.MCP.Server do
  @moduledoc """
  Owns one `Anubis.Client` for a configured MCP server and bridges its tools
  into `Synapsis.Tool.Registry`.
  """
  use GenServer
  require Logger

  alias Synapsis.MCP.{Response, Transport}
  alias Synapsis.Tool.Registry

  @await_ready_ms 15_000
  @call_timeout_ms 30_000

  defstruct [:config, :client, :registered_tools]

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: via(config.name))
  end

  defp via(name), do: {:via, Registry, {Synapsis.MCP.Registry, name}}

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    client_name = client_name(config.name)

    child = {
      Anubis.Client,
      name: client_name,
      transport: Transport.build(config),
      client_info: %{"name" => "synapsis", "version" => "0.1.0"},
      capabilities: %{"roots" => %{}},
      protocol_version: "2024-11-05"
    }

    case start_client(child) do
      {:ok, client} ->
        state = %__MODULE__{config: config, client: client, registered_tools: []}
        {:ok, state, {:continue, :discover}}

      {:error, reason} ->
        Logger.warning("mcp_client_start_failed", server: config.name, reason: inspect(reason))
        {:stop, reason}
    end
  end

  defp start_client(child) do
    case start_supervised_or_link(child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # Anubis.Client is a GenServer; start it linked to this server so its lifetime
  # is bound to ours.
  defp start_supervised_or_link({mod, opts}), do: mod.start_link(opts)

  defp client_name(name), do: :"anubis_client_#{name}"

  @impl true
  def handle_continue(:discover, state) do
    with :ok <- Anubis.Client.await_ready(state.client, timeout: @await_ready_ms),
         {:ok, response} <- Anubis.Client.list_tools(state.client) do
      tools = Response.tools(Anubis.MCP.Response.unwrap(response), state.config.name)
      registered = register_tools(tools)
      Logger.info("mcp_server_ready", server: state.config.name, tools: length(registered))
      {:noreply, %{state | registered_tools: registered}}
    else
      {:error, reason} ->
        Logger.warning("mcp_discover_failed", server: state.config.name, reason: inspect(reason))
        {:stop, {:discover_failed, reason}, state}
    end
  end

  @impl true
  def handle_call({:execute, tool_name, input, _ctx}, _from, state) do
    raw = Response.raw_tool_name(tool_name)

    case Anubis.Client.call_tool(state.client, raw, input, timeout: @call_timeout_ms) do
      {:ok, response} ->
        {:reply, {:ok, Response.content(Anubis.MCP.Response.unwrap(response))}, state}

      {:error, error} ->
        {:reply, {:error, inspect(error)}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, client, reason}, %{client: client} = state) do
    Logger.warning("mcp_client_exited", server: state.config.name, reason: inspect(reason))
    {:stop, {:client_exited, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.registered_tools || [], &Registry.unregister/1)
    :ok
  end

  defp register_tools(tools) do
    for tool <- tools do
      Registry.register_process(tool.name, self(),
        description: tool.description,
        parameters: tool.parameters,
        timeout: @call_timeout_ms,
        plugin: :mcp
      )

      tool.name
    end
  end
end
```

> Verification point: confirm `Anubis.Client.start_link/1` accepts `name:` +
> `transport:` as shown, and `call_tool/4` accepts `timeout:`. If `Anubis.Client`
> must be started under a supervisor rather than `start_link`, adjust `start_client/1`
> only. The test in Step 2 will surface any mismatch.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp/server_test.exs`
Expected: PASS (tools discovered, call routed, tools purged on stop).

- [ ] **Step 6: Commit**

```bash
git add apps/synapsis_mcp/lib/synapsis/mcp/server.ex apps/synapsis_mcp/test/synapsis/mcp/server_test.exs apps/synapsis_mcp/test/support/stdio_echo.exs
git commit -m "feat(mcp): anubis-backed MCP server bridging tools to registry"
```

---

### Task 9: Supervisor, Registry, façade, and restart regression

**Files:**
- Create: `apps/synapsis_mcp/lib/synapsis/mcp/supervisor.ex`
- Create: `apps/synapsis_mcp/lib/synapsis/mcp.ex`
- Test: `apps/synapsis_mcp/test/synapsis/mcp_test.exs`

- [ ] **Step 1: Write the failing test**

Create `apps/synapsis_mcp/test/synapsis/mcp_test.exs`:

```elixir
defmodule Synapsis.MCPTest do
  use ExUnit.Case, async: false

  alias Synapsis.MCPConfig
  alias Synapsis.Tool.Registry

  setup do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      result =
        case req["method"] do
          "initialize" ->
            %{"protocolVersion" => "2024-11-05", "capabilities" => %{"tools" => %{}},
              "serverInfo" => %{"name" => "x", "version" => "0"}}

          "tools/list" ->
            %{"tools" => [%{"name" => "echo", "description" => "e", "inputSchema" => %{}}]}

          _ ->
            %{}
        end

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result}))
    end)

    {:ok, bypass: bypass}
  end

  test "start, restart resets tools, stop removes them", %{bypass: bypass} do
    name = "facade_#{System.unique_integer([:positive])}"

    cfg = %MCPConfig{
      name: name,
      transport: "streamable_http",
      url: "http://localhost:#{bypass.port}/mcp"
    }

    {:ok, _} = Synapsis.MCP.start(cfg)
    tool = "mcp:#{name}:echo"
    wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)

    :ok = Synapsis.MCP.restart(cfg)
    wait_until(fn -> match?({:ok, _}, Registry.lookup(tool)) end)
    assert {:ok, _} = Registry.lookup(tool)

    :ok = Synapsis.MCP.stop(name)
    wait_until(fn -> match?({:error, :not_found}, Registry.lookup(tool)) end)
    assert {:error, :not_found} = Registry.lookup(tool)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      tries <= 0 -> :timeout
      fun.() -> :ok
      true -> Process.sleep(20); wait_until(fun, tries - 1)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp_test.exs`
Expected: FAIL — `Synapsis.MCP`/`Synapsis.MCP.Supervisor` undefined.

- [ ] **Step 3: Create `apps/synapsis_mcp/lib/synapsis/mcp/supervisor.ex`**

```elixir
defmodule Synapsis.MCP.Supervisor do
  @moduledoc "Top-level supervisor: Registry + DynamicSupervisor for MCP servers."
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Synapsis.MCP.Registry},
      {DynamicSupervisor, name: Synapsis.MCP.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
```

- [ ] **Step 4: Create the façade `apps/synapsis_mcp/lib/synapsis/mcp.ex`**

```elixir
defmodule Synapsis.MCP do
  @moduledoc "Public API for managing MCP servers (anubis_mcp clients)."
  require Logger

  alias Synapsis.MCP.Server
  alias Synapsis.MCPConfigs

  @doc "Start a configured MCP server."
  def start(%Synapsis.MCPConfig{} = config) do
    spec = %{
      id: {:mcp, config.name},
      start: {Server, :start_link, [config]},
      restart: :transient
    }

    DynamicSupervisor.start_child(Synapsis.MCP.DynamicSupervisor, spec)
  end

  @doc "Stop a running MCP server by name."
  def stop(name) do
    case Registry.lookup(Synapsis.MCP.Registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Synapsis.MCP.DynamicSupervisor, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Restart a server: stop (purges tools) then start fresh."
  def restart(%Synapsis.MCPConfig{} = config) do
    _ = stop(config.name)
    wait_gone(config.name)

    case start(config) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "List running MCP server names."
  def list do
    Synapsis.MCP.DynamicSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(Synapsis.MCP.Registry, pid) do
        [name | _] -> [name]
        [] -> []
      end
    end)
  end

  @doc "Start all enabled MCP configs (boot-time)."
  def start_enabled do
    for cfg <- MCPConfigs.enabled() do
      case start(cfg) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("mcp_autostart_failed", server: cfg.name, reason: inspect(reason))
      end
    end

    :ok
  end

  defp wait_gone(name, tries \\ 50) do
    cond do
      tries <= 0 -> :ok
      Registry.lookup(Synapsis.MCP.Registry, name) == [] -> :ok
      true -> Process.sleep(20); wait_gone(name, tries - 1)
    end
  end
end
```

- [ ] **Step 5: Boot-time auto-start in the app supervisor**

Edit `apps/synapsis_mcp/lib/synapsis_mcp/application.ex` `start/2` to start enabled
configs after the supervision tree is up:

```elixir
defmodule SynapsisMcp.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Synapsis.MCP.Supervisor]
    opts = [strategy: :one_for_one, name: SynapsisMcp.RootSupervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Synapsis.MCP.start_enabled()
        {:ok, pid}

      other ->
        other
    end
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test apps/synapsis_mcp/test/synapsis/mcp_test.exs`
Expected: PASS (including the restart-resets-tools assertion).

- [ ] **Step 7: Run the whole `synapsis_mcp` suite**

Run: `mix test apps/synapsis_mcp/test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add apps/synapsis_mcp/lib apps/synapsis_mcp/test/synapsis/mcp_test.exs
git commit -m "feat(mcp): supervisor, facade, auto-start, restart regression"
```

---

## Phase 4 — Cutover (wire-in + removals)

### Task 10: Move the sandbox bridge into `synapsis_sandbox`

**Files:**
- Create: `apps/synapsis_sandbox/lib/synapsis/sandbox/bridge.ex` (moved)
- Create: `apps/synapsis_sandbox/test/synapsis/sandbox/bridge_test.exs` (moved)
- Delete: `apps/synapsis_plugin/lib/synapsis_plugin/sandbox_bridge.ex`
- Delete: `apps/synapsis_plugin/test/synapsis_plugin/sandbox_bridge_test.exs`

- [ ] **Step 1: Move and rename the module**

```bash
mkdir -p apps/synapsis_sandbox/lib/synapsis/sandbox apps/synapsis_sandbox/test/synapsis/sandbox
git mv apps/synapsis_plugin/lib/synapsis_plugin/sandbox_bridge.ex apps/synapsis_sandbox/lib/synapsis/sandbox/bridge.ex
git mv apps/synapsis_plugin/test/synapsis_plugin/sandbox_bridge_test.exs apps/synapsis_sandbox/test/synapsis/sandbox/bridge_test.exs
```

- [ ] **Step 2: Rename the module + any internal references**

Edit `apps/synapsis_sandbox/lib/synapsis/sandbox/bridge.ex`: change
`defmodule SynapsisPlugin.SandboxBridge` → `defmodule Synapsis.Sandbox.Bridge`.
Edit the moved test similarly (`alias`/module references).
Then grep for external references:

Run: `grep -rn "SandboxBridge\|SynapsisPlugin.SandboxBridge" apps --include="*.ex" --include="*.exs"`
Update each hit to `Synapsis.Sandbox.Bridge`.

- [ ] **Step 3: Run the moved tests**

Run: `mix test apps/synapsis_sandbox/test`
Expected: PASS (same assertions as before, new module name).

- [ ] **Step 4: Commit**

```bash
git add apps/synapsis_sandbox apps/synapsis_plugin
git commit -m "refactor(sandbox): move sandbox bridge to synapsis_sandbox"
```

---

### Task 11: Repoint `synapsis_server` deps and core boot

**Files:**
- Modify: `apps/synapsis_server/mix.exs:37`
- Modify: `apps/synapsis_core/lib/synapsis_core/application.ex:8-9,49`

- [ ] **Step 1: Swap the umbrella dep**

In `apps/synapsis_server/mix.exs`, replace:

```elixir
      {:synapsis_plugin, in_umbrella: true},
```

with:

```elixir
      {:synapsis_mcp, in_umbrella: true},
      {:synapsis_sandbox, in_umbrella: true},
```

- [ ] **Step 2: Remove the soft plugin boot from core**

In `apps/synapsis_core/lib/synapsis_core/application.ex`, delete the
`optional_children = [SynapsisPlugin.Supervisor] |> Enum.filter(...)` block and the
`++ optional_children` usage, and delete the
`maybe_apply(SynapsisPlugin.Loader, :start_auto_plugins, [])` line. (MCP now boots
from `SynapsisMcp.Application`.)

- [ ] **Step 3: Compile**

Run: `mix compile`
Expected: may still fail until LSP/diagnostics + web LiveViews are handled (Tasks
12–13). Note remaining errors; proceed.

- [ ] **Step 4: Commit**

```bash
git add apps/synapsis_server/mix.exs apps/synapsis_core/lib/synapsis_core/application.ex
git commit -m "chore: repoint server deps and core boot off synapsis_plugin"
```

---

### Task 12: Remove LSP and the LSP diagnostics tool

**Files:**
- Delete: `apps/synapsis_plugin/lib/synapsis_plugin/lsp.ex` and `lsp/*.ex`
- Delete: `apps/synapsis_core/lib/synapsis/tool/diagnostics.ex`
- Delete: any diagnostics test (`apps/synapsis_core/test/synapsis/tool/diagnostics_test.exs` if present)
- Modify: wherever `Synapsis.Tool.Diagnostics` is registered

- [ ] **Step 1: Find the diagnostics registration**

Run: `grep -rn "Tool.Diagnostics\|Diagnostics" apps/synapsis_core/lib --include="*.ex"`
Note the registration site (likely a tool list/registration module).

- [ ] **Step 2: Delete LSP + diagnostics files**

```bash
git rm apps/synapsis_plugin/lib/synapsis_plugin/lsp.ex
git rm -r apps/synapsis_plugin/lib/synapsis_plugin/lsp
git rm apps/synapsis_core/lib/synapsis/tool/diagnostics.ex
git rm apps/synapsis_plugin/test/synapsis_plugin/lsp_test.exs 2>/dev/null || true
git rm -r apps/synapsis_plugin/test/synapsis_plugin/lsp 2>/dev/null || true
ls apps/synapsis_core/test/synapsis/tool/diagnostics_test.exs 2>/dev/null && git rm apps/synapsis_core/test/synapsis/tool/diagnostics_test.exs || true
```

- [ ] **Step 3: Remove the diagnostics registration line** found in Step 1.

- [ ] **Step 4: Confirm no dangling references**

Run: `grep -rn "LSP\|Lsp\|Diagnostics" apps/synapsis_core apps/synapsis_server apps/synapsis_web --include="*.ex" --include="*.exs"`
Expected: only unrelated hits (e.g. comments). Fix any code references.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove LSP subsystem and LSP diagnostics tool"
```

---

### Task 13: Remove LSP web pages and update MCP LiveView

**Files:**
- Delete: `apps/synapsis_web/lib/synapsis_web/live/lsp_live/` (Index + Show)
- Modify: `apps/synapsis_server/lib/synapsis_server/router.ex:20-23,108-114`
- Modify: `apps/synapsis_web/lib/synapsis_web/live/mcp_live/index.ex`
- Modify: `apps/synapsis_web/lib/synapsis_web/live/mcp_live/show.ex` (if present)

- [ ] **Step 1: Delete LSP LiveViews**

```bash
git rm -r apps/synapsis_web/lib/synapsis_web/live/lsp_live
```

- [ ] **Step 2: Remove LSP from the router**

In `apps/synapsis_server/lib/synapsis_server/router.ex`, delete the
`SynapsisWeb.LSPLive.Index`/`Show` entries (lines ~22-23) and the three
`live "/settings/lsp..."` routes (lines ~112-114).

- [ ] **Step 3: Update `mcp_live/index.ex` to the new façade + schema**

Replace the plugin-based calls:
- `SynapsisPlugin.start_plugin(SynapsisPlugin.MCP, name, cfg)` → `Synapsis.MCP.start(cfg)` where `cfg` is a `%Synapsis.MCPConfig{}` from `Synapsis.MCPConfigs.get_by_name/1`.
- `SynapsisPlugin.stop_plugin(name)` → `Synapsis.MCP.stop(name)`.
- `Synapsis.PluginConfigs` → `Synapsis.MCPConfigs` (and `PluginConfig` → `MCPConfig`).
- Replace config fields `auto_start` → `enabled`; drop `settings`/`transport "http"`
  in favor of `transport "streamable_http"` and a `headers` map.
- Add a `"restart_plugin"` event calling `Synapsis.MCP.restart(cfg)`.

Run after editing: `grep -n "SynapsisPlugin\|PluginConfig\|auto_start\|settings" apps/synapsis_web/lib/synapsis_web/live/mcp_live/index.ex`
Expected: no remaining `SynapsisPlugin`/`PluginConfig` references.

- [ ] **Step 4: Compile**

Run: `mix compile --warnings-as-errors`
Expected: PASS now that server/core/web no longer reference `SynapsisPlugin`.

- [ ] **Step 5: Run web MCP LiveView tests**

Run: `mix test apps/synapsis_web/test/synapsis_web/live/mcp_live` 2>/dev/null || mix test apps/synapsis_web/test
Expected: PASS (update assertions for the new fields/labels as needed).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(web): drive MCP UI via Synapsis.MCP facade; remove LSP pages"
```

---

### Task 14: Delete the `synapsis_plugin` app

**Files:**
- Delete: `apps/synapsis_plugin/` (entire directory)
- Modify: `apps/synapsis_data/lib/synapsis/plugin_configs.ex` + `plugin_config.ex`
  (only if no longer referenced — see Step 1)

- [ ] **Step 1: Confirm nothing outside the app still references it**

Run: `grep -rn "synapsis_plugin\|SynapsisPlugin\|Synapsis.Plugin\b" apps --include="*.ex" --include="*.exs" | grep -v "apps/synapsis_plugin/"`
Expected: no hits. Fix any stragglers before deleting.

- [ ] **Step 2: Decide legacy `PluginConfigs` fate**

Run: `grep -rn "PluginConfigs\|PluginConfig\b" apps --include="*.ex" --include="*.exs" | grep -v "apps/synapsis_data/"`
- If only the migration (Task 5) uses `Store.list(:plugin)` directly (not `PluginConfigs`), you may delete `plugin_configs.ex` and `plugin_config.ex`.
- If still referenced, leave them. (Migration uses `Config.Store` directly, so deletion is expected to be safe.)

```bash
# Only if Step 2 shows no external references:
git rm apps/synapsis_data/lib/synapsis/plugin_configs.ex apps/synapsis_data/lib/synapsis/plugin_config.ex
ls apps/synapsis_data/test/synapsis/plugin_configs_test.exs 2>/dev/null && git rm apps/synapsis_data/test/synapsis/plugin_configs_test.exs || true
```

- [ ] **Step 3: Delete the app**

```bash
git rm -r apps/synapsis_plugin
```

- [ ] **Step 4: Clean build artifacts and recompile**

Run: `mix deps.get && mix compile --warnings-as-errors`
Expected: PASS; umbrella no longer lists `synapsis_plugin`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete synapsis_plugin app (MCP via anubis, sandbox rehomed, LSP removed)"
```

---

### Task 15: Update docs and config references

**Files:**
- Modify: `CLAUDE.md` (app list: 9 → updated apps; remove plugin/LSP claims)
- Modify: `AGENTS.md` (keep aligned with CLAUDE.md)
- Modify: any `config/*.exs` referencing `synapsis_plugin` or LSP
- Modify: `docs/architecture/*` references to the plugin app (as needed)

- [ ] **Step 1: Find references**

Run: `grep -rn "synapsis_plugin\|SynapsisPlugin\|LSP\|\.opencode" CLAUDE.md AGENTS.md config docs`
Update the app inventory and remove obsolete MCP/LSP/`.opencode.json` guidance,
noting the new `synapsis_mcp` + `synapsis_sandbox` apps and the `anubis_mcp` dep.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md AGENTS.md config docs
git commit -m "docs: reflect anubis_mcp cutover and synapsis_plugin removal"
```

---

### Task 16: Final verification gates

- [ ] **Step 1: Format**

Run: `mix format && mix format --check-formatted`
Expected: clean.

- [ ] **Step 2: Compile strict**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Full test suite**

Run: `mix test`
Expected: all pass. Investigate and fix any failure before finishing.

- [ ] **Step 4: Boot smoke test**

Run: `iex -S mix` then in the shell: `Synapsis.MCP.list()` returns a list
(empty if no enabled configs) without raising; exit with `Ctrl-C Ctrl-C`.

- [ ] **Step 5: Final commit (if anything adjusted)**

```bash
git add -A
git commit -m "chore: finalize anubis_mcp cutover"
```

---

## Self-review notes (coverage vs. spec)

- Spec §4.1 (layout/boot) → Tasks 1, 2, 9, 11.
- Spec §4.2 (synapsis_mcp internals) → Tasks 6, 7, 8, 9.
- Spec §4.3 (sandbox) → Task 10.
- Spec §5 (removals) → Tasks 11, 12, 13, 14.
- Spec §6 (config redesign + migration) → Tasks 4, 5.
- Spec §7 (bug fix: registry monitor + terminate) → Tasks 3, 8.
- Spec §8 (web) → Task 13.
- Spec §9 (testing) → Tasks 3, 6, 7, 8, 9, 10, 16.
- Spec §10 (consequences) → Task 12 (diagnostics removal), Task 5 (migration), Task 1 (LGPL dep — conscious add).

**Known verification points carried into implementation** (single-location fixes, surfaced by tests):
- Exact Anubis transport option keys (`env`, `headers`, `url` vs `base_url`) — Task 6.
- `Anubis.Client` start/`call_tool` arities and `await_ready`/`unwrap` usage — Task 8.
- `Config.Store` `:mcp` filename clause — Task 4 Step 5.
