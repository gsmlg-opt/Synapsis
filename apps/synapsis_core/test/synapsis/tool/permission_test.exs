defmodule Synapsis.Tool.PermissionTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Permission
  alias Synapsis.Tool.Permission.SessionConfig

  describe "SessionConfig struct" do
    test "default/0 returns autonomous (yolo) mode with expected defaults" do
      config = SessionConfig.default()
      assert config.session_id == nil
      assert config.mode == :autonomous
      assert config.allow_read == :allow
      assert config.allow_write == :allow
      assert config.allow_execute == :allow
      assert config.allow_destructive == :allow
      assert config.overrides == []
    end

    test "enforces session_id key" do
      assert_raise ArgumentError, fn ->
        struct!(SessionConfig, mode: :autonomous)
      end
    end

    test "from_db/1 loads read policy and normalizes override decisions" do
      config =
        SessionConfig.from_db(%Synapsis.SessionPermission{
          session_id: "s1",
          mode: :interactive,
          allow_read: :ask,
          allow_write: :allow,
          allow_execute: :allow,
          allow_destructive: :allow,
          tool_overrides: %{"bash(*)" => "requires_approval"}
        })

      assert config.allow_read == :ask
      assert [%{tool: "bash", pattern: "*", decision: :requires_approval}] = config.overrides
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

  describe "config_for_mode/1" do
    test "yolo allows all levels without overrides" do
      assert %{
               mode: :autonomous,
               allow_read: :allow,
               allow_write: :allow,
               allow_execute: :allow,
               allow_destructive: :allow,
               tool_overrides: %{}
             } = Permission.config_for_mode("yolo")
    end

    test "yolo keeps its allowances but records an attending user as interactive" do
      assert %{
               mode: :interactive,
               allow_read: :allow,
               allow_write: :allow,
               allow_execute: :allow,
               allow_destructive: :allow,
               tool_overrides: %{}
             } = Permission.config_for_mode("yolo", interactive: true)

      assert %{mode: :autonomous} = Permission.config_for_mode("yolo", interactive: false)
    end

    test "ask allows reads, asks for write/execute, denies destructive" do
      assert %{
               mode: :interactive,
               allow_read: :allow,
               allow_write: :ask,
               allow_execute: :ask,
               allow_destructive: :deny,
               tool_overrides: %{}
             } = Permission.config_for_mode("ask")
    end

    test "restrict asks for every non-internal tool level" do
      assert %{
               mode: :interactive,
               allow_read: :ask,
               allow_write: :ask,
               allow_execute: :ask,
               allow_destructive: :ask,
               tool_overrides: %{}
             } = Permission.config_for_mode("restrict")
    end
  end
end
