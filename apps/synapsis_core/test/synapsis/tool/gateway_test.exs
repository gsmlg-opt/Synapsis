defmodule Synapsis.Tool.GatewayTest do
  use ExUnit.Case, async: false

  alias Synapsis.Tool.Capability.{Grant, PolicySnapshot}
  alias Synapsis.Tool.Gateway
  alias Synapsis.Tool.Registry

  defmodule ReadTool do
    use Synapsis.Tool

    @impl true
    def name, do: "gateway_test_read"

    @impl true
    def description, do: "read"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def permission_level, do: :read

    @impl true
    def execute(_input, _ctx), do: {:ok, "read-ok"}
  end

  defmodule WriteTool do
    use Synapsis.Tool

    @impl true
    def name, do: "gateway_test_write"

    @impl true
    def description, do: "write"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def permission_level, do: :write

    @impl true
    def execute(_input, _ctx), do: {:ok, "write-ok"}
  end

  defmodule DestructiveTool do
    use Synapsis.Tool

    @impl true
    def name, do: "gateway_test_destructive"

    @impl true
    def description, do: "destructive"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def permission_level, do: :destructive

    @impl true
    def execute(_input, _ctx), do: {:ok, "should-not-run"}
  end

  setup do
    suffix = System.unique_integer([:positive])
    read = "gateway_read_#{suffix}"
    write = "gateway_write_#{suffix}"
    destructive = "gateway_destructive_#{suffix}"

    :ok = Registry.register_module(read, ReadTool, permission_level: :read)
    :ok = Registry.register_module(write, WriteTool, permission_level: :write)
    :ok = Registry.register_module(destructive, DestructiveTool, permission_level: :destructive)

    on_exit(fn ->
      Registry.unregister(read)
      Registry.unregister(write)
      Registry.unregister(destructive)
    end)

    %{read: read, write: write, destructive: destructive, session_id: "gw-sess-#{suffix}"}
  end

  test "executes allowed read tools", %{read: read, session_id: session_id} do
    assert {:ok, "read-ok"} =
             Gateway.execute(read, %{}, %{
               session_id: session_id,
               permission_mode: "ask",
               attended?: true
             })
  end

  test "requires approval for write under ask without operator_approval", %{
    write: write,
    session_id: session_id
  } do
    assert {:error, :requires_approval} =
             Gateway.execute(write, %{}, %{
               session_id: session_id,
               permission_mode: "ask",
               attended?: true
             })
  end

  test "operator_approval elevates write approval to allow", %{
    write: write,
    session_id: session_id
  } do
    assert {:ok, "write-ok"} =
             Gateway.execute(write, %{}, %{
               session_id: session_id,
               permission_mode: "ask",
               attended?: true,
               operator_approval: true
             })
  end

  test "denies destructive under ask even with operator_approval", %{
    destructive: destructive,
    session_id: session_id
  } do
    assert {:error, :capability_denied} =
             Gateway.execute(destructive, %{}, %{
               session_id: session_id,
               permission_mode: "ask",
               attended?: true,
               operator_approval: true
             })
  end

  test "unattended write becomes approval_unavailable", %{write: write, session_id: session_id} do
    snapshot =
      PolicySnapshot.from_permission_mode("ask", session_id: session_id, attended?: false)

    assert {:error, :approval_unavailable} =
             Gateway.execute(write, %{}, %{
               session_id: session_id,
               policy_snapshot: snapshot
             })
  end

  test "missing session fails closed", %{read: read} do
    assert {:error, :missing_session_context} =
             Gateway.execute(read, %{}, %{permission_mode: "ask", attended?: true})
  end

  test "execute_approved without grant is rejected", %{read: read, session_id: session_id} do
    assert {:error, :grant_required} =
             Synapsis.Tool.Executor.execute_approved(read, %{}, %{session_id: session_id})
  end

  test "forged grant is rejected", %{read: read, session_id: session_id} do
    grant =
      Grant.mint(
        tool_name: read,
        permission_level: :read,
        source: :policy_allow,
        session_id: session_id
      )

    forged = %{grant | tool_name: read, mac: :crypto.strong_rand_bytes(32)}

    assert {:error, :forged_grant} =
             Gateway.execute_authorized(read, %{}, %{session_id: session_id}, forged)
  end

  test "expired grant is rejected", %{read: read, session_id: session_id} do
    grant =
      Grant.mint(
        tool_name: read,
        permission_level: :read,
        source: :policy_allow,
        session_id: session_id,
        ttl_ms: 1
      )

    Process.sleep(5)

    assert {:error, :expired_grant} =
             Gateway.execute_authorized(read, %{}, %{session_id: session_id}, grant)
  end
end
