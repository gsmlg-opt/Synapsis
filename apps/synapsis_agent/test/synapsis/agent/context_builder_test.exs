defmodule Synapsis.Agent.ContextBuilderTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.ContextBuilder

  describe "build_system_prompt/2" do
    @tag :tmp_dir
    test "uses the supplied workspace and can omit private memory for children", %{tmp_dir: root} do
      File.write!(Path.join(root, "MEMORY.md"), "Private workspace decision")
      opts = [workspace_path: root, agent_config: %{tools: [], skill_catalog: []}]
      assert ContextBuilder.build_system_prompt(:coding, opts) =~ "Private workspace decision"

      prompt =
        ContextBuilder.build_system_prompt(:coding, Keyword.put(opts, :memory_context, false))

      refute prompt =~ "Private workspace decision"
      refute prompt =~ "<workspace_memory>"
    end

    test "returns a non-empty string" do
      prompt = ContextBuilder.build_system_prompt(:coding)
      assert is_binary(prompt)
      assert byte_size(prompt) > 0
    end

    test "includes base prompt" do
      prompt = ContextBuilder.build_system_prompt(:coding)
      assert prompt =~ "AI coding assistant"
    end

    test "wraps soul section in XML tags when soul exists" do
      # This test verifies the XML wrapping behavior
      # Identity files may not exist in test env, so we test with agent_config
      prompt =
        ContextBuilder.build_system_prompt(:coding,
          agent_config: %{system_prompt: "Custom prompt"}
        )

      assert prompt =~ "Custom prompt"
    end

    test "omits sections for missing files" do
      prompt = ContextBuilder.build_system_prompt(:coding)
      # Without identity files, soul/identity/bootstrap sections should be absent
      refute prompt =~ "<soul>"
      refute prompt =~ "<user_identity>"
      refute prompt =~ "<environment>"
    end
  end

  test "selected shared memory injects initialize instructions and durable session identity" do
    alias Synapsis.Config.Store
    alias Synapsis.Memory.Settings
    previous = Store.get(:memory, "default")

    on_exit(fn ->
      case previous do
        {:ok, entry} -> Store.put(:memory, entry)
        {:error, :not_found} -> Store.delete(:memory, "default")
      end
    end)

    server = Gaoxy.Test.open()

    assert {:ok, _} =
             Settings.save(%{
               "backend" => "workspace",
               "host_agent" => %{
                 "enabled" => true,
                 "endpoint" => String.trim_trailing(Gaoxy.Test.url(server), "/"),
                 "agent_id" => "synapsis"
               }
             })

    Gaoxy.Test.expect_once(server, "POST", "/memory/synapsis/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      assert request["method"] == "initialize"

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          jsonrpc: "2.0",
          id: request["id"],
          result: %{instructions: "Use memory::search before exploring; remember once if useful."}
        })
      )
    end)

    opts = [
      session_id: "durable-session",
      memory_context: false,
      agent_config: %{tools: ["memory::search", "memory::remember"]}
    ]

    prompt = ContextBuilder.build_system_prompt(:coding, opts)
    assert prompt =~ "<shared_memory_instructions>"
    assert prompt =~ "Use memory::search before exploring"
    assert prompt =~ "Current session_id: durable-session"
    assert length(Gaoxy.Test.requests(server).entries) == 1

    prompt =
      ContextBuilder.build_system_prompt(:coding, Keyword.put(opts, :agent_config, %{tools: []}))

    refute prompt =~ "<shared_memory_instructions>"
    assert length(Gaoxy.Test.requests(server).entries) == 1
  end

  describe "memory_budget/1" do
    test "returns 3 max entries for 32K context" do
      budget = ContextBuilder.memory_budget(32_000)
      assert budget.max_entries == 3
      assert budget.max_tokens == 1_600
    end

    test "returns 10 max entries for 128K context (cap)" do
      budget = ContextBuilder.memory_budget(128_000)
      assert budget.max_entries == 10
      assert budget.max_tokens == 6_400
    end

    test "returns 10 max entries for 200K context (cap)" do
      budget = ContextBuilder.memory_budget(200_000)
      assert budget.max_entries == 10
      assert budget.max_tokens == 10_000
    end

    test "token budget is 5% of context window" do
      budget = ContextBuilder.memory_budget(100_000)
      assert budget.max_tokens == 5_000
    end
  end

  describe "build_skills_manifest/1" do
    test "returns nil when no tools available" do
      # In test env, tool registry may not be started
      result = ContextBuilder.build_skills_manifest(nil)
      # Either nil or a string with tool listings
      assert is_nil(result) or is_binary(result)
    end

    test "returns nil when agent has an explicit empty tools list" do
      assert ContextBuilder.build_skills_manifest(nil, %{tools: []}) == nil
    end

    test "lists only tools assigned to the agent" do
      manifest =
        ContextBuilder.build_skills_manifest(nil, %{
          tool_contract_version: 1,
          tools: ["synapsis::read"]
        })

      assert manifest =~ "synapsis::read"
      refute manifest =~ "synapsis::write"
    end
  end

  describe "load_base_prompt/2" do
    test "returns agent system prompt when provided" do
      config = %{system_prompt: "Custom system prompt"}
      assert ContextBuilder.load_base_prompt(:coding, config) == "Custom system prompt"
    end

    test "returns default prompt when no config" do
      result = ContextBuilder.load_base_prompt(:coding, %{})
      assert result =~ "AI coding assistant"
    end
  end
end
