defmodule Synapsis.Agent.Tools.AutomationWakeFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.InputSchema

  alias Synapsis.Agent.Tools.{
    AutomationConfiguration,
    AutomationManagement,
    AutomationMutation,
    Automations,
    AutomationWake,
    DisplayCatalog,
    Profiles
  }

  alias Synapsis.Session.Store

  @name "synapsis::automations_wake"

  setup do
    context = %{
      session_id: Ecto.UUID.generate(),
      source_agent_id: Ecto.UUID.generate(),
      requester_name: "main",
      primary?: true,
      run_id: "/root/automation-wake",
      incarnation: 1,
      catalog_revision: 1
    }

    %{context: context}
  end

  test "wake has its own revision and positive target schema while existing automation descriptors stay intact",
       %{context: context} do
    reader_context = Map.drop(context, [:source_agent_id, :primary?])
    creator_context = Map.put(reader_context, :creator_agent_id, context.source_agent_id)
    assert {:ok, readers} = Automations.descriptors(reader_context)
    assert {:ok, runners} = AutomationManagement.descriptors(reader_context)
    assert {:ok, creators} = AutomationConfiguration.descriptors(creator_context)
    assert {:ok, mutations} = AutomationMutation.descriptors(creator_context)

    assert AutomationWake.names() == [@name]
    assert AutomationWake.revision() == 1
    assert {:ok, [descriptor]} = AutomationWake.descriptors(context)
    assert descriptor.tool_name == @name
    assert descriptor.tool_revision == 1
    assert descriptor.backend == AutomationWake
    assert descriptor.backend_context == context
    assert descriptor.schema["required"] == ["text"]

    assert Enum.sort(Map.keys(descriptor.schema["properties"])) ==
             ~w(agent_id mode session_id text)

    for arguments <- [
          %{"text" => "Caller-bound notice"},
          %{"text" => "Next ordinary turn", "mode" => "next-heartbeat"},
          %{
            "text" => "Explicit target notice",
            "mode" => "now",
            "session_id" => Ecto.UUID.generate(),
            "agent_id" => Ecto.UUID.generate()
          },
          %{"text" => "Same caller Agent", "agent_id" => context.source_agent_id}
        ] do
      assert {:ok, _} = InputSchema.validate(descriptor.schema, arguments)
    end

    assert @name in Profiles.supported_names()
    assert Enum.any?(DisplayCatalog.list(), &(&1.name == @name))
    assert {:ok, ^readers} = Automations.descriptors(reader_context)
    assert {:ok, ^runners} = AutomationManagement.descriptors(reader_context)
    assert {:ok, ^creators} = AutomationConfiguration.descriptors(creator_context)
    assert {:ok, ^mutations} = AutomationMutation.descriptors(creator_context)
  end

  test "Profiles issues only explicitly selected wake and retains trusted caller identity",
       %{context: context} do
    assert :ok =
             Store.put_value(context.session_id, "permission", %Synapsis.SessionPermission{
               session_id: context.session_id,
               tool_contract_version: 1
             })

    on_exit(fn -> Store.delete_session(context.session_id) end)

    identity =
      context
      |> Map.take([:session_id, :run_id, :incarnation, :catalog_revision])
      |> Map.put(:caller, "synapsis:" <> context.session_id)

    profile_context = %{
      session: %{id: context.session_id, config: %{"subagents" => false}},
      agent: %{
        id: context.source_agent_id,
        name: context.requester_name,
        tools: [@name],
        tool_contract_version: 1
      },
      tool_primary?: true
    }

    ceiling = %{
      caller: identity.caller,
      run_id: identity.run_id,
      grants: [@name],
      tool_revisions: %{@name => 1}
    }

    assert {:ok, %{bundle: bundle, snapshot: snapshot}} =
             Profiles.build(profile_context, identity, [], ceiling)

    assert Map.keys(bundle.registry.tools) == [@name]
    assert Map.keys(snapshot.selected) == [@name]
    assert bundle.registry.tools[@name].backend == AutomationWake
    assert bundle.registry.tools[@name].backend_context == context
  end
end
