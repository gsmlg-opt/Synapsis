defmodule Synapsis.Backplane.ConsumerIntegrationTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.ContextBuilder
  alias Synapsis.Agent.Resolver
  alias Synapsis.Backplane.{Connection, Snapshot, Sync}
  alias Synapsis.Provider.Registry, as: ProviderRegistry
  alias Synapsis.Session.Worker.Config, as: WorkerConfig
  alias Synapsis.{AgentConfigs, AgentSkills, Providers, Skill, Skills}

  @provider_name "backplane-consumer-matrix"

  defmodule NoopMCPRuntime do
    def restart(_config), do: :ok
    def stop(_name), do: :ok
  end

  setup do
    Enum.each([:backplane, :provider, :skill, :mcp, :agent], fn type ->
      Synapsis.DataCase.clear_config_store(type)
    end)

    on_exit(fn ->
      ProviderRegistry.unregister(@provider_name)

      Enum.each([:backplane, :provider, :skill, :mcp, :agent], fn type ->
        Synapsis.DataCase.clear_config_store(type)
      end)
    end)

    :ok
  end

  test "mock Backplane import reaches the provider resolver and agent skill context" do
    assert {:ok, connection} =
             Connection.create(%{
               name: "consumer-matrix",
               endpoint: "https://backplane.example.test"
             })

    assert {:ok, snapshot} =
             Snapshot.normalize(
               connection,
               %{
                 models: {:ok, [%{"id" => "matrix-model", "owned_by" => "integration"}]},
                 skills:
                   {:ok,
                    [
                      %{
                        "id" => "matrix-skill",
                        "slug" => "matrix-skill",
                        "name" => "Matrix Review",
                        "description" => "Review imported capabilities",
                        "content" => "Use the imported matrix review procedure.",
                        "content_available" => true,
                        "source_kind" => "generated"
                      }
                    ]},
                 mcp_tools: {:ok, []}
               },
               fetched_at: "2026-09-06T00:00:00Z"
             )

    mock_client = fn fetched_connection, _opts ->
      assert fetched_connection.id == connection.id
      {:ok, snapshot}
    end

    assert {:ok, synced} =
             Sync.run(connection.id,
               client: mock_client,
               mcp_runtime: NoopMCPRuntime,
               now: fn -> ~U[2026-09-06 00:00:00Z] end
             )

    provider_id = synced.artifacts["provider_id"]

    assert {:ok, %{id: ^provider_id, name: @provider_name} = provider} =
             Providers.get(provider_id)

    assert {:ok, %{provider_id: ^provider_id}} = ProviderRegistry.get(provider.name)

    assert {:ok,
            %{
              provider_id: ^provider_id,
              type: "openai",
              base_url: "https://backplane.example.test/v1",
              available_models: [%{"id" => "matrix-model", "owned_by" => "integration"}]
            }} = WorkerConfig.resolve_provider_config(provider.name)

    skill_id = synced.artifacts["skill_ids"]["matrix-skill"]

    assert %Skill{
             id: ^skill_id,
             name: "Matrix Review",
             system_prompt_fragment: "Use the imported matrix review procedure."
           } = Skills.get(skill_id)

    assert {:ok, agent} =
             AgentConfigs.create(%{
               name: "backplane-consumer",
               provider: provider.name,
               model: "matrix-model",
               system_prompt: "Consumer base prompt"
             })

    assert {:ok, _assigned_agent} = AgentSkills.assign_skills(agent, [skill_id])

    resolved_agent = Resolver.resolve(agent.name)

    assert %{
             provider: @provider_name,
             model: "matrix-model",
             skills: [
               %Skill{
                 id: ^skill_id,
                 name: "Matrix Review",
                 system_prompt_fragment: "Use the imported matrix review procedure."
               }
             ]
           } = resolved_agent

    prompt = ContextBuilder.build_system_prompt(:coding, agent_config: resolved_agent)

    assert prompt =~ "<assigned_skills>"
    assert prompt =~ "## Matrix Review"
    assert prompt =~ "Review imported capabilities"
    assert prompt =~ "Use the imported matrix review procedure."
  end
end
