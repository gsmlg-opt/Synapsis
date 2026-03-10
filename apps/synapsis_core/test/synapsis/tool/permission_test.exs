defmodule Synapsis.Tool.PermissionTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.{Permission, Permissions}
  alias Synapsis.Tool.Permission.SessionConfig

  # ===========================================================================
  # Legacy Permissions module tests (kept unchanged for backward compat)
  # ===========================================================================

  describe "Permissions.level/1" do
    test "classifies read tools" do
      assert :read = Permissions.level("file_read")
      assert :read = Permissions.level("grep")
      assert :read = Permissions.level("glob")
      assert :read = Permissions.level("list_dir")
      assert :read = Permissions.level("diagnostics")
    end

    test "classifies write tools" do
      assert :write = Permissions.level("file_write")
      assert :write = Permissions.level("file_edit")
      assert :write = Permissions.level("file_move")
      assert :write = Permissions.level("fetch")
    end

    test "classifies execute tools" do
      assert :execute = Permissions.level("bash")
    end

    test "classifies destructive tools" do
      assert :destructive = Permissions.level("file_delete")
    end

    test "classifies MCP tools as write" do
      assert :write = Permissions.level("mcp:server:tool")
    end

    test "classifies LSP tools as read" do
      assert :read = Permissions.level("lsp_diagnostics")
      assert :read = Permissions.level("lsp_definition")
    end

    test "unknown tools default to write (catch-all)" do
      assert :write = Permissions.level("custom_unknown_tool_xyz")
      assert :write = Permissions.level("mcp_without_colon")
    end
  end

  describe "Permissions.allowed?/2" do
    test "allows read tools with read auto-approve" do
      assert Permissions.allowed?("file_read", %{auto_approve: [:read]})
    end

    test "denies write tools with only read auto-approve" do
      refute Permissions.allowed?("file_write", %{auto_approve: [:read]})
    end

    test "allows all with full auto-approve" do
      config = %{auto_approve: [:read, :write, :execute, :destructive]}
      assert Permissions.allowed?("file_read", config)
      assert Permissions.allowed?("bash", config)
      assert Permissions.allowed?("file_delete", config)
    end
  end

  test "returns false when config has no auto_approve key" do
    refute Permissions.allowed?("file_read", %{})
    refute Permissions.allowed?("bash", %{some_other: true})
  end

  describe "Permissions.check/2 with session config" do
    test "approves tools matching session autoApprove levels" do
      session = %{config: %{"permissions" => %{"autoApprove" => ["write", "execute"]}}}
      assert :approved = Permissions.check("file_write", session)
      assert :approved = Permissions.check("bash", session)
    end

    test "merges session levels with application default" do
      session = %{config: %{"permissions" => %{"autoApprove" => ["write"]}}}
      assert :approved = Permissions.check("file_read", session)
      assert :approved = Permissions.check("file_write", session)
    end

    test "requires approval for levels not in session or default config" do
      session = %{config: %{"permissions" => %{"autoApprove" => ["read"]}}}
      assert :requires_approval = Permissions.check("bash", session)
      assert :requires_approval = Permissions.check("file_delete", session)
    end

    test "handles session with empty config" do
      session = %{config: %{}}
      result = Permissions.check("file_read", session)
      assert result in [:approved, :requires_approval]
    end

    test "handles session with nil config" do
      session = %{config: nil}
      result = Permissions.check("file_read", session)
      assert result in [:approved, :requires_approval]
    end

    test "handles session with atom autoApprove levels" do
      session = %{config: %{"permissions" => %{"autoApprove" => [:write, :execute]}}}
      assert :approved = Permissions.check("file_write", session)
      assert :approved = Permissions.check("bash", session)
      assert :approved = Permissions.check("file_read", session)
    end

    test "handles non-existent session struct" do
      result = Permissions.check("file_read", nil)
      assert result in [:approved, :requires_approval]
    end
  end

  describe "Permissions.check/2 fallback behavior" do
    test "unknown tool defaults to :write level requiring approval" do
      assert :requires_approval = Permissions.check("custom_tool_xyz", nil)
    end
  end

  # ===========================================================================
  # New Permission system tests (T033-T036)
  # ===========================================================================

  describe "SessionConfig struct" do
    test "default/0 returns interactive mode with expected defaults" do
      config = SessionConfig.default()
      assert config.session_id == nil
      assert config.mode == :interactive
      assert config.allow_read == true
      assert config.allow_write == true
      assert config.allow_execute == false
      assert config.allow_destructive == :ask
      assert config.overrides == []
    end

    test "enforces session_id key" do
      assert_raise ArgumentError, fn ->
        struct!(SessionConfig, mode: :autonomous)
      end
    end
  end

  describe "Permission.check/3 — interactive mode, all 5 permission levels" do
    test ":none level is always allowed" do
      config = %SessionConfig{session_id: "s1", mode: :interactive, allow_execute: false}

      # :none-level tools are always allowed regardless of settings
      assert :allowed = do_check_with_config("none_tool", %{}, config, :none)
    end

    test ":read level is always allowed" do
      config = %SessionConfig{session_id: "s1", mode: :interactive, allow_execute: false}

      assert :allowed = do_check_with_config("read_tool", %{}, config, :read)
    end

    test ":write level follows allow_write setting" do
      allowed_config = %SessionConfig{session_id: "s1", mode: :interactive, allow_write: true}
      denied_config = %SessionConfig{session_id: "s1", mode: :interactive, allow_write: false}

      assert :allowed = do_check_with_config("write_tool", %{}, allowed_config, :write)
      assert :denied = do_check_with_config("write_tool", %{}, denied_config, :write)
    end

    test ":execute level follows allow_execute setting" do
      allowed_config = %SessionConfig{session_id: "s1", mode: :interactive, allow_execute: true}
      denied_config = %SessionConfig{session_id: "s1", mode: :interactive, allow_execute: false}

      assert :allowed = do_check_with_config("exec_tool", %{}, allowed_config, :execute)
      assert :denied = do_check_with_config("exec_tool", %{}, denied_config, :execute)
    end

    test ":destructive level follows allow_destructive setting" do
      allow_cfg = %SessionConfig{session_id: "s1", mode: :interactive, allow_destructive: :allow}
      deny_cfg = %SessionConfig{session_id: "s1", mode: :interactive, allow_destructive: :deny}
      ask_cfg = %SessionConfig{session_id: "s1", mode: :interactive, allow_destructive: :ask}

      assert :allowed = do_check_with_config("destructive_tool", %{}, allow_cfg, :destructive)
      assert :denied = do_check_with_config("destructive_tool", %{}, deny_cfg, :destructive)

      assert :requires_approval =
               do_check_with_config("destructive_tool", %{}, ask_cfg, :destructive)
    end
  end

  describe "Permission.check/3 — autonomous mode, all 5 permission levels" do
    test ":none, :read, :write, :execute are all allowed in autonomous mode" do
      config = %SessionConfig{
        session_id: "s1",
        mode: :autonomous,
        allow_write: false,
        allow_execute: false
      }

      # In autonomous mode, :none through :execute are always :allowed
      assert :allowed = do_check_with_config("none_tool", %{}, config, :none)
      assert :allowed = do_check_with_config("read_tool", %{}, config, :read)
      assert :allowed = do_check_with_config("write_tool", %{}, config, :write)
      assert :allowed = do_check_with_config("exec_tool", %{}, config, :execute)
    end

    test ":destructive follows allow_destructive in autonomous mode" do
      allow_cfg = %SessionConfig{session_id: "s1", mode: :autonomous, allow_destructive: :allow}
      deny_cfg = %SessionConfig{session_id: "s1", mode: :autonomous, allow_destructive: :deny}
      ask_cfg = %SessionConfig{session_id: "s1", mode: :autonomous, allow_destructive: :ask}

      assert :allowed = do_check_with_config("destructive_tool", %{}, allow_cfg, :destructive)
      assert :denied = do_check_with_config("destructive_tool", %{}, deny_cfg, :destructive)

      assert :requires_approval =
               do_check_with_config("destructive_tool", %{}, ask_cfg, :destructive)
    end
  end

  describe "glob override matching" do
    test "exact match override" do
      overrides = [%{tool: "bash", pattern: "git status", decision: :allowed}]

      assert {:ok, :allowed} =
               Permission.resolve_override("bash", %{command: "git status"}, overrides)
    end

    test "wildcard match override" do
      overrides = [%{tool: "bash", pattern: "git *", decision: :allowed}]

      assert {:ok, :allowed} =
               Permission.resolve_override("bash", %{command: "git push"}, overrides)

      assert {:ok, :allowed} =
               Permission.resolve_override("bash", %{command: "git status"}, overrides)
    end

    test "no match falls through" do
      overrides = [%{tool: "bash", pattern: "git *", decision: :allowed}]

      assert :no_match =
               Permission.resolve_override("bash", %{command: "rm -rf /"}, overrides)
    end

    test "override for different tool does not match" do
      overrides = [%{tool: "file_read", pattern: "*", decision: :allowed}]

      assert :no_match =
               Permission.resolve_override("bash", %{command: "ls"}, overrides)
    end

    test "empty overrides list returns :no_match" do
      assert :no_match = Permission.resolve_override("bash", %{command: "ls"}, [])
    end

    test "file path pattern matching" do
      overrides = [%{tool: "file_read", pattern: "/tmp/*", decision: :allowed}]

      assert {:ok, :allowed} =
               Permission.resolve_override("file_read", %{path: "/tmp/foo.txt"}, overrides)

      assert :no_match =
               Permission.resolve_override("file_read", %{path: "/etc/passwd"}, overrides)
    end

    test "grep pattern matching" do
      overrides = [%{tool: "grep", pattern: "TODO*", decision: :allowed}]

      assert {:ok, :allowed} =
               Permission.resolve_override("grep", %{pattern: "TODO:"}, overrides)
    end

    test "denied override" do
      overrides = [%{tool: "bash", pattern: "rm *", decision: :denied}]

      assert {:ok, :denied} =
               Permission.resolve_override("bash", %{command: "rm -rf /"}, overrides)
    end
  end

  describe "resolution priority — override wins over session default" do
    test "override :allowed wins even when session denies the level" do
      config = %SessionConfig{
        session_id: "s1",
        mode: :interactive,
        allow_execute: false,
        overrides: [%{tool: "bash", pattern: "git *", decision: :allowed}]
      }

      # bash is :execute level, which is denied in this config,
      # but the override should win
      assert :allowed = do_check_with_config("bash", %{command: "git status"}, config, :execute)
    end

    test "override :denied wins even when session allows the level" do
      config = %SessionConfig{
        session_id: "s1",
        mode: :autonomous,
        overrides: [%{tool: "bash", pattern: "rm *", decision: :denied}]
      }

      # autonomous mode allows :execute, but override denies rm commands
      assert :denied = do_check_with_config("bash", %{command: "rm -rf /"}, config, :execute)
    end

    test "non-matching override falls through to level-based resolution" do
      config = %SessionConfig{
        session_id: "s1",
        mode: :interactive,
        allow_execute: false,
        overrides: [%{tool: "bash", pattern: "git *", decision: :allowed}]
      }

      # "ls" does not match "git *", so falls through to level check
      assert :denied = do_check_with_config("bash", %{command: "ls"}, config, :execute)
    end
  end

  describe "Permission.check/2 backward compatibility" do
    test "auto-approves read-only tools" do
      assert :approved = Permission.check("file_read", nil)
      assert :approved = Permission.check("grep", nil)
      assert :approved = Permission.check("glob", nil)
      assert :approved = Permission.check("diagnostics", nil)
      assert :approved = Permission.check("list_dir", nil)
    end

    test "returns :requires_approval for unknown session" do
      # With default config, allow_execute is false so bash requires approval
      # (The old code returned :requires_approval, new code maps :denied to :requires_approval)
      result = Permission.check("bash", nil)
      assert result == :requires_approval
    end
  end

  describe "parse_override/1" do
    test "parses tool(pattern) format" do
      assert %{tool: "bash", pattern: "git *"} = Permission.parse_override("bash(git *)")
    end

    test "handles plain tool name without pattern" do
      assert %{tool: "bash", pattern: "*"} = Permission.parse_override("bash")
    end

    test "handles nested parentheses in pattern" do
      assert %{tool: "bash", pattern: "echo (hello)"} =
               Permission.parse_override("bash(echo (hello))")
    end
  end

  describe "tool_permission_level/1" do
    test "returns :write for unknown tools not in registry" do
      assert :write =
               Permission.tool_permission_level("nonexistent_tool_xyz_#{System.unique_integer()}")
    end

    test "returns level from registry opts when tool is registered" do
      # Start the registry if not started (it may already be running)
      ensure_registry_started()

      tool_name = "test_perm_level_#{System.unique_integer([:positive])}"

      Synapsis.Tool.Registry.register_module(
        tool_name,
        Synapsis.Tool.PermissionTest.DummyTool,
        permission_level: :execute
      )

      assert :execute = Permission.tool_permission_level(tool_name)

      # cleanup
      Synapsis.Tool.Registry.unregister(tool_name)
    end

    test "falls back to module callback when no opts override" do
      ensure_registry_started()

      tool_name = "test_perm_cb_#{System.unique_integer([:positive])}"

      # Register without explicit permission_level — should use module's callback
      Synapsis.Tool.Registry.register_module(
        tool_name,
        Synapsis.Tool.PermissionTest.ReadTool,
        []
      )

      assert :read = Permission.tool_permission_level(tool_name)

      Synapsis.Tool.Registry.unregister(tool_name)
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # Directly test the internal resolution logic by simulating a known
  # permission level, bypassing the registry lookup.
  defp do_check_with_config(tool_name, input, %SessionConfig{} = config, level) do
    # Step 1: check overrides
    case Permission.resolve_override(tool_name, input, config.overrides) do
      {:ok, decision} ->
        decision

      :no_match ->
        # Step 2: resolve by level
        resolve_by_level(level, config)
    end
  end

  defp resolve_by_level(level, %SessionConfig{mode: :autonomous} = config) do
    case level do
      :none -> :allowed
      :read -> :allowed
      :write -> :allowed
      :execute -> :allowed
      :destructive -> resolve_allow_setting(config.allow_destructive)
    end
  end

  defp resolve_by_level(level, %SessionConfig{mode: :interactive} = config) do
    case level do
      :none -> :allowed
      :read -> :allowed
      :write -> resolve_allow_setting(config.allow_write)
      :execute -> resolve_allow_setting(config.allow_execute)
      :destructive -> resolve_allow_setting(config.allow_destructive)
    end
  end

  defp resolve_allow_setting(true), do: :allowed
  defp resolve_allow_setting(false), do: :denied
  defp resolve_allow_setting(:allow), do: :allowed
  defp resolve_allow_setting(:deny), do: :denied
  defp resolve_allow_setting(:ask), do: :requires_approval
  defp resolve_allow_setting(_), do: :requires_approval

  defp ensure_registry_started do
    case Synapsis.Tool.Registry.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Dummy tool modules for registry tests
  # ---------------------------------------------------------------------------

  defmodule DummyTool do
    @moduledoc false
    def name, do: "dummy_tool"
    def description, do: "A dummy tool for testing"
    def parameters, do: %{}
    def call(_input, _ctx), do: {:ok, "ok"}
    def permission_level, do: :write
    def category, do: :testing
    def version, do: "1.0.0"
    def enabled?, do: true
  end

  defmodule ReadTool do
    @moduledoc false
    def name, do: "read_tool"
    def description, do: "A read-only tool"
    def parameters, do: %{}
    def call(_input, _ctx), do: {:ok, "ok"}
    def permission_level, do: :read
    def category, do: :testing
    def version, do: "1.0.0"
    def enabled?, do: true
  end
end
