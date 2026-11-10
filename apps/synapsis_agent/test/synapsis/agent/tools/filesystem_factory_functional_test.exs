defmodule Synapsis.Agent.Tools.FilesystemFactoryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.ToolCatalog
  alias Synapsis.Agent.Tools.{DisplayCatalog, Filesystem, Profiles}
  alias Synapsis.Session.Store

  @moduletag :tmp_dir
  @names ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @factory Path.expand("../../../fixtures/openclaw/488631c/filesystem-factories.json", __DIR__)
  @node "/tmp/synapsis-openclaw-capture-runtime/node_modules/node/bin/node"
  @ls_description "List directory entries in binary filename order, including dotfiles and links. Names are JSON-quoted; / marks actual directories. Pass the returned after cursor with the same path to continue."

  test "factory publishes exactly the four pinned source input contracts", %{tmp_dir: root} do
    context = trusted_context(root)
    assert Filesystem.names() == @names
    assert {:ok, descriptors} = Filesystem.descriptors(context)
    assert Enum.map(descriptors, & &1.tool_name) == @names

    for descriptor <- descriptors do
      expected = source_metadata(descriptor.tool_name)
      assert descriptor.tool_revision == 1
      assert descriptor.backend == Filesystem
      assert descriptor.backend_context === context
      assert descriptor.description == expected["description"]
      assert descriptor.schema == expected["parameters"]
    end
  end

  test "source descriptors admit as revision one and supply display metadata", %{tmp_dir: root} do
    context = trusted_context(root)
    assert {:ok, descriptors} = Filesystem.descriptors(context)

    authority = %{
      caller: "filesystem-factory-functional",
      run_id: context.run_id,
      grants: @names,
      tool_revision: 1,
      tool_revisions: Map.new(@names, &{&1, 1})
    }

    assert {:ok, admitted} =
             ToolCatalog.admit_batch(descriptors, authority: authority, mode: :strict)

    assert Enum.sort(Map.keys(admitted.registry.tools)) == Enum.sort(@names)

    for descriptor <- descriptors do
      assert admitted.registry.tools[descriptor.tool_name].backend_context === context
      assert descriptor.tool_name in Profiles.supported_names()
      display = Enum.find(DisplayCatalog.list(), &(&1.name == descriptor.tool_name))
      assert display.description == source_metadata(descriptor.tool_name)["description"]
    end
  end

  test "Profiles keeps the captured filesystem context for the exact selected subset", %{
    tmp_dir: root
  } do
    Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)

    assert :ok =
             Store.put_value(session_id, "permission", %Synapsis.SessionPermission{
               session_id: session_id,
               tool_contract_version: 1,
               allow_read: :allow,
               allow_write: :allow,
               allow_execute: :allow,
               allow_destructive: :allow
             })

    captured = trusted_context(root)
    selected = ~w(synapsis::edit synapsis::read)

    identity = %{
      caller: "filesystem-factory-functional",
      session_id: session_id,
      run_id: captured.run_id,
      incarnation: captured.incarnation,
      catalog_revision: captured.catalog_revision
    }

    assert {:ok, agent_config} =
             Synapsis.AgentConfigs.create(%{
               name: "factory-agent-#{System.unique_integer([:positive, :monotonic])}",
               tools: selected,
               tool_contract_version: 1,
               enabled: true
             })

    on_exit(fn -> Synapsis.AgentConfigs.delete(agent_config) end)
    agent = %{name: agent_config.name, tools: selected, tool_contract_version: 1}
    workspace = %{role: :session, agent_id: agent.name, session_id: session_id}

    context = %{
      session: %{id: session_id, config: %{"subagents" => false}},
      agent: agent,
      project_path: root,
      tool_filesystem:
        Map.take(captured, [:path_environment, :prepared_target_resolver, :execution_options])
    }

    ceiling = %{
      caller: identity.caller,
      run_id: identity.run_id,
      grants: selected,
      tool_revision: 1,
      tool_revisions: Map.new(selected, &{&1, 1})
    }

    assert {:ok, %{bundle: bundle}} = Profiles.build(context, identity, [], ceiling)
    assert Enum.sort(Map.keys(bundle.registry.tools)) == Enum.sort(selected)

    for name <- selected do
      descriptor = bundle.registry.tools[name]
      assert descriptor.backend == Filesystem
      assert descriptor.schema == source_metadata(name)["parameters"]
      assert descriptor.backend_context === %{captured | workspace: workspace}
    end
  end

  defp trusted_context(root) do
    %{
      root: root,
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      catalog_revision: 1,
      workspace: %{role: :user},
      path_environment: %{
        cwd: root,
        os_home: Path.join(root, "home"),
        platform: :linux,
        workspace_root: Path.join(root, "workspace")
      },
      prepared_target_resolver: fn _, _, _ -> {:ok, :unused_in_factory_test} end,
      execution_options: [node_executable: @node, model_has_vision: true]
    }
  end

  # Constructor captures are independent source metadata, never runtime output
  # schemas for the native {content, details} envelope.
  defp source_metadata("synapsis::ls") do
    %{
      "description" => @ls_description,
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Directory; default cwd."},
          "limit" => %{"type" => "number", "description" => "Max entries; default 500."},
          "after" => %{
            "type" => "string",
            "description" => "Filename cursor returned by the previous page."
          }
        }
      }
    }
  end

  defp source_metadata("synapsis::" <> name) do
    @factory
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("rows")
    |> Enum.find(&(&1["id"] == name <> "/default"))
    |> Map.fetch!("metadata")
  end
end
