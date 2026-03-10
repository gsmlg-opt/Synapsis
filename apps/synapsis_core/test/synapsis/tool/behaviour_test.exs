defmodule Synapsis.Tool.BehaviourTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Context

  # A minimal tool using defaults
  defmodule DefaultTool do
    use Synapsis.Tool

    @impl true
    def name, do: "default_tool"

    @impl true
    def description, do: "A tool with all defaults."

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_input, _context), do: {:ok, "done"}
  end

  # A tool that overrides all optional callbacks
  defmodule CustomTool do
    use Synapsis.Tool

    @impl true
    def name, do: "custom_tool"

    @impl true
    def description, do: "A fully customized tool."

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def execute(_input, _context), do: {:ok, "custom done"}

    @impl true
    def permission_level, do: :destructive

    @impl true
    def category, do: :execution

    @impl true
    def version, do: "2.0.0"

    @impl true
    def enabled?, do: false

    @impl true
    def side_effects, do: [:file_changed, :process_spawned]
  end

  describe "default callbacks" do
    test "permission_level defaults to :read" do
      assert DefaultTool.permission_level() == :read
    end

    test "category defaults to :filesystem" do
      assert DefaultTool.category() == :filesystem
    end

    test "version defaults to 1.0.0" do
      assert DefaultTool.version() == "1.0.0"
    end

    test "enabled? defaults to true" do
      assert DefaultTool.enabled?() == true
    end

    test "side_effects defaults to empty list" do
      assert DefaultTool.side_effects() == []
    end
  end

  describe "overridden callbacks" do
    test "permission_level can be overridden" do
      assert CustomTool.permission_level() == :destructive
    end

    test "category can be overridden" do
      assert CustomTool.category() == :execution
    end

    test "version can be overridden" do
      assert CustomTool.version() == "2.0.0"
    end

    test "enabled? can be overridden" do
      assert CustomTool.enabled?() == false
    end

    test "side_effects can be overridden" do
      assert CustomTool.side_effects() == [:file_changed, :process_spawned]
    end
  end

  describe "existing tool callbacks" do
    test "FileRead has correct permission_level and category" do
      assert Synapsis.Tool.FileRead.permission_level() == :read
      assert Synapsis.Tool.FileRead.category() == :filesystem
    end

    test "FileWrite has correct permission_level and category" do
      assert Synapsis.Tool.FileWrite.permission_level() == :write
      assert Synapsis.Tool.FileWrite.category() == :filesystem
      assert Synapsis.Tool.FileWrite.side_effects() == [:file_changed]
    end

    test "FileEdit has correct permission_level and category" do
      assert Synapsis.Tool.FileEdit.permission_level() == :write
      assert Synapsis.Tool.FileEdit.category() == :filesystem
      assert Synapsis.Tool.FileEdit.side_effects() == [:file_changed]
    end

    test "FileDelete has correct permission_level and category" do
      assert Synapsis.Tool.FileDelete.permission_level() == :destructive
      assert Synapsis.Tool.FileDelete.category() == :filesystem
      assert Synapsis.Tool.FileDelete.side_effects() == [:file_changed]
    end

    test "FileMove has correct permission_level and category" do
      assert Synapsis.Tool.FileMove.permission_level() == :write
      assert Synapsis.Tool.FileMove.category() == :filesystem
      assert Synapsis.Tool.FileMove.side_effects() == [:file_changed]
    end

    test "ListDir has correct permission_level and category" do
      assert Synapsis.Tool.ListDir.permission_level() == :read
      assert Synapsis.Tool.ListDir.category() == :filesystem
    end

    test "Grep has correct permission_level and category" do
      assert Synapsis.Tool.Grep.permission_level() == :read
      assert Synapsis.Tool.Grep.category() == :search
    end

    test "Glob has correct permission_level and category" do
      assert Synapsis.Tool.Glob.permission_level() == :read
      assert Synapsis.Tool.Glob.category() == :search
    end

    test "Bash has correct permission_level and category" do
      assert Synapsis.Tool.Bash.permission_level() == :execute
      assert Synapsis.Tool.Bash.category() == :execution
    end

    test "Fetch has correct permission_level and category" do
      assert Synapsis.Tool.Fetch.permission_level() == :read
      assert Synapsis.Tool.Fetch.category() == :web
    end

    test "Diagnostics has correct permission_level and category" do
      assert Synapsis.Tool.Diagnostics.permission_level() == :read
      assert Synapsis.Tool.Diagnostics.category() == :search
    end
  end

  describe "Tool.Context" do
    test "new/0 creates context with defaults" do
      ctx = Context.new()
      assert ctx.session_id == nil
      assert ctx.project_path == nil
      assert ctx.working_dir == nil
      assert ctx.permissions == %{}
      assert ctx.session_pid == nil
      assert ctx.agent_mode == :build
      assert ctx.parent_agent == nil
    end

    test "new/1 accepts keyword list" do
      ctx = Context.new(session_id: "abc", project_path: "/tmp", agent_mode: :plan)
      assert ctx.session_id == "abc"
      assert ctx.project_path == "/tmp"
      assert ctx.agent_mode == :plan
    end

    test "new/1 accepts map" do
      ctx = Context.new(%{session_id: "xyz", working_dir: "/home"})
      assert ctx.session_id == "xyz"
      assert ctx.working_dir == "/home"
    end

    test "sub_agent_context/2 sets parent_agent" do
      parent = self()
      ctx = Context.new(session_id: "s1", project_path: "/proj")
      sub = Context.sub_agent_context(ctx, parent)
      assert sub.parent_agent == parent
      assert sub.session_id == "s1"
      assert sub.project_path == "/proj"
    end

    test "to_map/1 converts to plain map without nil values" do
      ctx = Context.new(session_id: "s1", project_path: "/proj")
      map = Context.to_map(ctx)
      assert map.session_id == "s1"
      assert map.project_path == "/proj"
      assert map.agent_mode == :build
      assert map.permissions == %{}
      refute Map.has_key?(map, :session_pid)
      refute Map.has_key?(map, :working_dir)
      refute Map.has_key?(map, :parent_agent)
    end
  end
end
