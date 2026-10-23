defmodule Synapsis.BackplaneContractCapture do
  @moduledoc "Offline snapshots of public native APIs; never executes captured tools."
  alias Backplane.AgentRuntime.{Codex, Error, Plan}

  alias Backplane.AgentRuntime.Codex.{
    CodeMode,
    Contract,
    Control,
    DynamicRuntime,
    ExtensionRuntime,
    MultiAgent,
    ResourceRegistry,
    Services,
    Tools
  }

  @version "1.10.31"
  @root Path.expand("../..", __DIR__)
  @default_out "apps/synapsis_agent/test/fixtures/backplane/1.10.31/contracts.json"
  @families [
    :local,
    :interactive,
    :collaboration_v2,
    :services,
    :dynamic,
    :extensions,
    :code_mode
  ]
  @apis [
    Codex,
    Codex.Profile,
    Contract,
    Tools,
    Control,
    MultiAgent,
    Services,
    DynamicRuntime,
    ExtensionRuntime,
    CodeMode,
    ResourceRegistry,
    Backplane.AgentRuntime.ToolCatalog,
    Backplane.AgentRuntime.Execution,
    Backplane.AgentRuntime.Conversation,
    Backplane.AgentRuntime.ConversationAdapter,
    Backplane.AgentRuntime.ToolEffects
  ]

  def main(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [offline: :boolean, check: :boolean, out: :string])

    unless opts[:offline] == true and rest == [] and invalid == [] do
      raise ArgumentError, "capture requires --offline [--check] [--out PATH]"
    end

    path = Path.expand(opts[:out] || @default_out, @root)
    encoded = encode(snapshot())

    if opts[:check] do
      unless File.read!(path) == encoded,
        do: raise("native Backplane contract snapshot drift: #{path}")

      IO.puts("Native Backplane #{@version} contracts match")
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, encoded)
      IO.puts("Captured native Backplane #{@version} contracts: #{path}")
    end
  end

  def snapshot do
    provenance = provenance()
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    try do
      {:ok, resources} = Supervisor.start_child(supervisor, {ResourceRegistry, []})

      {:ok, plan} =
        Supervisor.start_child(
          supervisor,
          %{id: Plan, start: {Plan, :start_link, [:offline_capture]}}
        )

      {:ok, collaboration} =
        Supervisor.start_child(
          supervisor,
          {MultiAgent,
           [
             parent_run_id: "offline-capture",
             parent_name: "root",
             parent_authority: authority([]),
             child_options: fn _, _, _ -> raise "offline capture cannot spawn" end
           ]}
        )

      {:ok, extensions} =
        Supervisor.start_child(
          supervisor,
          {ExtensionRuntime,
           [
             scope: %{
               host_id: "offline",
               caller_id: "offline",
               run_id: "offline-capture",
               project_id: "offline"
             }
           ]}
        )

      {:ok, dynamic} =
        Supervisor.start_child(
          supervisor,
          {DynamicRuntime,
           [candidates: Tools.contracts(%{}), mcp_adapter: __MODULE__, plugin_adapter: __MODULE__]}
        )

      context = %{
        workspace: "/offline/workspace",
        caller: %{},
        command: %{},
        session_registry: resources,
        resource_registry: resources,
        plan: plan,
        collaboration_runtime: collaboration,
        dynamic_runtime: dynamic,
        extension_runtime: extensions,
        root?: true,
        grant_permissions: fn _, _ -> raise "offline binding" end,
        environment_provider: fn _ -> raise "offline binding" end,
        context_remaining: fn -> raise "offline binding" end,
        web_allowed_hosts: ["offline.invalid"],
        search_adapter: __MODULE__,
        x_search_adapter: __MODULE__,
        web_run_adapter: __MODULE__,
        image_adapter: __MODULE__,
        # Declaration-only binding: no executable is launched or claimed to be installed.
        deno_path: "/offline/not-executed/deno"
      }

      %{
        format_version: 1,
        provenance: provenance,
        capture: %{
          offline: true,
          tools_executed: false,
          external_services: false,
          bindings: "Inert declaration bindings; availability is not execution readiness.",
          code_mode_lifecycle: json(CodeMode.lifecycle_capability(context))
        },
        profiles: Map.new(@families, fn family -> {family, capture_profile(family, context)} end),
        unconfigured: Map.new(@families, fn family -> {family, capture_profile(family, %{})} end)
      }
      |> json()
    after
      Supervisor.stop(supervisor, :normal, 5_000)
    end
  end

  defp capture_profile(family, context) do
    contracts = contracts(family, context)

    names =
      Enum.map(contracts, fn attrs ->
        Contract.canonical_name(Map.get(attrs, :namespace), attrs.name)
      end)

    case Codex.profile(:configured, context, authority(names), families: [family]) do
      {:ok, bundle} ->
        %{
          status: :admitted,
          authority: bundle.authority,
          descriptors:
            bundle.registry.tools
            |> Map.values()
            |> Enum.sort_by(& &1.tool_name)
            |> Enum.map(fn descriptor ->
              descriptor
              |> Map.delete(:backend_context)
              |> Map.put(:bindings, binding_shape(descriptor.backend_context))
            end),
          provider_tools: Enum.sort_by(bundle.tools, & &1.name)
        }

      {:error, %Error{} = error} ->
        %{status: :unavailable, error: Map.take(error, [:class, :message, :details])}
    end
  end

  defp contracts(:local, context), do: Tools.contracts(context)
  defp contracts(:interactive, context), do: Control.contracts(context)

  defp contracts(:collaboration_v2, %{collaboration_runtime: runtime}),
    do: MultiAgent.contracts(:v2, runtime)

  defp contracts(:collaboration_v2, _), do: []
  defp contracts(:services, context), do: Services.contracts(context)
  defp contracts(:dynamic, context), do: DynamicRuntime.contracts(context)
  defp contracts(:extensions, context), do: ExtensionRuntime.contracts(context)
  defp contracts(:code_mode, context), do: CodeMode.contracts(context)

  def authority(names) do
    %{
      caller: "offline-capture",
      run_id: "offline-capture",
      grants: Enum.sort(names),
      tool_revision: 1
    }
  end

  defp provenance do
    {lock, _} =
      Path.join(@root, "mix.lock")
      |> File.read!()
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Code.eval_quoted()

    {:hex, :backplane_agent_runtime, @version, checksum, _, _, "hexpm", outer_checksum} =
      lock[:backplane_agent_runtime]

    Application.load(:backplane_agent_runtime)
    @version = to_string(Application.spec(:backplane_agent_runtime, :vsn))
    source_root = Mix.Project.deps_paths()[:backplane_agent_runtime]

    %{
      package: "backplane_agent_runtime",
      version: @version,
      repository: "hexpm",
      package_checksum: checksum,
      outer_checksum: outer_checksum,
      public_apis:
        Enum.map(@apis, fn module ->
          Code.ensure_loaded!(module)
          compiled_source = module.module_info(:compile)[:source] |> to_string()
          source = "lib/" <> List.last(String.split(compiled_source, "/lib/", parts: 2))

          api = %{
            module: module,
            source: source,
            source_sha256:
              Base.encode16(:crypto.hash(:sha256, File.read!(Path.join(source_root, source))),
                case: :lower
              ),
            exports:
              module.__info__(:functions)
              |> Enum.sort()
              |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
          }

          if function_exported?(module, :behaviour_info, 1) do
            Map.merge(api, %{
              callbacks:
                module.behaviour_info(:callbacks)
                |> Enum.sort()
                |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end),
              optional_callbacks:
                module.behaviour_info(:optional_callbacks)
                |> Enum.sort()
                |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
            })
          else
            api
          end
        end)
    }
  end

  # Binding values are never serialized, including paths, callbacks, handles or credentials.
  defp binding_shape(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, binding_shape(child)} end)

  defp binding_shape(value) when is_function(value),
    do: "callback/#{:erlang.fun_info(value, :arity) |> elem(1)}"

  defp binding_shape(value) when is_pid(value), do: "process"
  defp binding_shape(value) when is_binary(value), do: "string"
  defp binding_shape(value) when is_list(value), do: "list"
  defp binding_shape(value) when is_atom(value), do: "atom"
  defp binding_shape(value) when is_integer(value), do: "integer"

  defp json(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {to_string(key), json(child)} end)

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value) when is_tuple(value), do: value |> Tuple.to_list() |> json()
  defp json(value) when value in [true, false, nil], do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value) when is_binary(value) or is_number(value), do: value

  def encode(snapshot), do: Jason.encode!(ordered(snapshot), pretty: true) <> "\n"

  defp ordered(value) when is_map(value),
    do:
      value
      |> Enum.sort()
      |> Enum.map(fn {key, child} -> {key, ordered(child)} end)
      |> Jason.OrderedObject.new()

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value
end
