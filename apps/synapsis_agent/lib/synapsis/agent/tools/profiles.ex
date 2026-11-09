defmodule Synapsis.Agent.Tools.Profiles do
  @moduledoc """
  Builds exact issued descriptors and immutable host policy material per run.

  Only selected host descriptors are built.
  Native bundles retain their original backends and contexts. Permission and
  selected skill evidence are checked again before each invocation; classifiers
  receive a local view enriched with their trusted descriptor context, while
  the original invocation and its arguments remain unchanged. Trusted compound
  invocation permission requirements survive classification instead of being
  replaced by the scalar tool fallback; the permission compiler validates them.
  """

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Backplane.AgentRuntime.Codex.Backend

  alias Synapsis.Agent.Tools.{
    AgentDirectory,
    AutomationConfiguration,
    AutomationManagement,
    AutomationMutation,
    AutomationWake,
    Automations,
    Browser,
    Catalog,
    CatalogBinding,
    CodeMode,
    Discovery,
    ExplicitSkill,
    Filesystem,
    Freshness,
    HostMemory,
    MCP,
    MCPResources,
    MemoryDomain,
    NativeLocal,
    PermissionSnapshot,
    ProcessInspection,
    Questions,
    Readiness,
    SessionDirectory,
    SessionStatus,
    SessionHistory,
    SessionState,
    SessionSummary,
    Skills,
    SkillBodyCache,
    SkillWorkshop,
    ToolInspection,
    WorkspaceMemory
  }

  alias Synapsis.Agent.Tools.Web.{Fetch, Search}
  alias Synapsis.{AgentConfigs, Session, SkillReader, SkillDiscovery}
  alias Synapsis.Session.Store

  @memory ~w(synapsis::workspace_memory_search synapsis::workspace_memory_get)
  @host_memory ~w(memory::get)
  @semantic ~w(synapsis::memory_source_search synapsis::memory_save synapsis::memory_update)
  @filesystem Filesystem.names()
  @questions Questions.names()
  @session_state SessionState.names()
  @summary SessionSummary.names()
  @skills ~w(synapsis::skills_search synapsis::skills_read)
  @explicit_skill ExplicitSkill.names()
  @skill_workshop SkillWorkshop.names()
  @session_directory SessionDirectory.names()
  @session_status SessionStatus.names()
  @history SessionHistory.names()
  @directory AgentDirectory.names()
  @inspection ToolInspection.names()
  @automations Automations.names()
  @automation_configuration AutomationConfiguration.names()
  @automation_management AutomationManagement.names()
  @automation_mutation AutomationMutation.names()
  @automation_wake AutomationWake.names()
  @collaboration ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)
  @code_mode CodeMode.names()
  @local NativeLocal.names()
  @process_inspection ProcessInspection.names()
  @browser Browser.names()
  @mcp_resources MCPResources.names()
  @web_fetch Fetch.names()
  @web_search Search.names()
  @web @web_fetch ++ @web_search
  @collaboration_actions %{
    "spawn_agent" => "collaboration.spawn",
    "send_message" => "collaboration.message",
    "followup_task" => "collaboration.followup",
    "interrupt_agent" => "collaboration.interrupt",
    "list_agents" => "collaboration.list",
    "wait_agent" => "collaboration.wait"
  }
  @dependencies %{provider_ids: [], credential_ids: []}
  @identity_fields [:caller, :session_id, :run_id, :incarnation, :catalog_revision]

  @doc "Pure names of the implemented static native families; availability is checked per run."
  def supported_names do
    @inspection ++
      @browser ++
      @mcp_resources ++
      @web ++
      @local ++
      @process_inspection ++
      @code_mode ++
      @collaboration ++
      @filesystem ++
      @memory ++
      @host_memory ++
      @semantic ++
      @skills ++
      @explicit_skill ++
      @skill_workshop ++
      @questions ++
      @session_state ++
      @summary ++
      @session_status ++
      @session_directory ++
      @history ++
      @directory ++
      @automations ++
      @automation_management ++
      @automation_configuration ++
      @automation_mutation ++
      @automation_wake
  end

  def selection(%{agent: %{tool_selection_error: _}}),
    do: invalid("saved toolset selection is unavailable")

  def selection(%{agent: %{tools: names} = agent, session: session})
      when is_list(names) and is_map(session) do
    cond do
      agent[:tool_contract_version] !== 1 ->
        invalid("tool selection requires explicit native contract version 1")

      not Enum.all?(names, &exact_name?/1) or length(names) != length(Enum.uniq(names)) ->
        invalid("tool selection must contain unique exact names")

      not Session.subagents_enabled?(session) and Enum.any?(names, &(&1 in @collaboration)) ->
        invalid("collaboration tools require subagents to be enabled")

      true ->
        {:ok, names}
    end
  end

  def selection(_), do: invalid("tool selection must be an explicit list")

  def build(context, identity, native_bundles, ceiling) do
    with {:ok, names} <- selection(context),
         :ok <- identity_valid(context, identity, ceiling),
         {:ok, mcp} <- mcp_descriptors(context, identity),
         :ok <- available(names, native_bundles, mcp),
         {:ok, raw} <- permission(identity.session_id),
         {:ok, evidence} <- Freshness.capture(identity.session_id, @dependencies),
         true <- evidence.permission_fingerprint === PermissionSnapshot.fingerprint(raw),
         {:ok, permission_revision} <- skill_permission_revision(context, names, identity, raw),
         {:ok, descriptors, skill_snapshot, skill_cache} <-
           descriptors(context, identity, names, raw) do
      result =
        finish_build(
          context,
          identity,
          native_bundles,
          ceiling,
          names,
          mcp,
          raw,
          evidence,
          permission_revision,
          descriptors,
          skill_snapshot,
          skill_cache
        )

      case result do
        {:ok, _} ->
          result

        error ->
          SkillBodyCache.release(skill_cache)
          error
      end
    else
      false -> {:error, :freshness_changed}
      error -> error
    end
  end

  defp finish_build(
         context,
         identity,
         native_bundles,
         ceiling,
         names,
         mcp,
         raw,
         evidence,
         permission_revision,
         descriptors,
         skill_snapshot,
         skill_cache
       ) do
    with {:ok, bundle} <- Catalog.compose(native_bundles, descriptors ++ mcp, ceiling, names),
         {:ok, bundle} <-
           ToolInspection.prepare(bundle, names, identity, context[:tool_session_binding]),
         {:ok, plan} <- Discovery.plan(context.agent, names),
         {:ok, bundle, initial, discovery} <-
           Discovery.prepare(bundle, plan, context[:tool_session_binding], ceiling) do
      scope = Map.put(identity, :permission_fingerprint, evidence.permission_fingerprint)

      selected =
        Map.new(bundle.registry.tools, fn {name, descriptor} ->
          {name, descriptor_binding(descriptor, identity)}
        end)

      permission_levels =
        Map.new(bundle.registry.tools, fn {name, descriptor} ->
          level =
            if descriptor.backend == MCP,
              do:
                Enum.find(
                  descriptor.backend_context.source.tools,
                  &("mcp::#{descriptor.backend_context.source.source_id}::#{&1.raw_name}" == name)
                ).permission_level,
              else: permission_level(name)

          {name, level}
        end)

      known =
        Map.new(
          @memory ++
            @host_memory ++
            @semantic ++
            @filesystem ++
            @questions ++
            @session_state ++
            @summary ++
            @skills ++
            @explicit_skill ++
            @skill_workshop ++
            @session_status ++
            @session_directory ++
            @history ++
            @directory ++
            @automations ++
            @automation_management ++
            @automation_configuration ++
            @automation_mutation ++
            @automation_wake ++
            @collaboration ++
            @local ++
            @web ++
            @browser ++
            @mcp_resources ++
            @code_mode ++ @inspection,
          fn name ->
            {name,
             Map.get(selected, name, %{tool_revision: 1, classify: &unavailable_classification/1})}
          end
        )
        |> Map.merge(Map.new(mcp, &{&1.tool_name, descriptor_binding(&1, identity)}))
        |> Map.merge(selected)

      snapshot = %{
        scope: scope,
        permission: raw,
        evidence: evidence,
        selected: selected,
        permission_levels: permission_levels,
        known_bindings: known,
        skill_snapshot: skill_snapshot,
        skill_body_cache: skill_cache,
        permission_revision: permission_revision,
        issued_descriptors: bundle.registry.tools
      }

      {:ok,
       %{bundle: initial, snapshot: snapshot, discovery: discovery, skill_body_cache: skill_cache}}
    else
      false -> {:error, :freshness_changed}
      error -> error
    end
  end

  @doc "Projects host policy sidecars from Conversation's exact pinned catalog."
  def project_catalog(
        subject,
        %{scope: scope, issued_descriptors: issued} = snapshot,
        %{revision: revision, registry: %{tools: descriptors}, tools: tools, authority: authority} =
          catalog
      )
      when is_map(subject) and is_map(scope) and is_map(issued) and is_integer(revision) and
             revision > 0 and is_map(descriptors) and is_list(tools) and is_map(authority) do
    with true <- Enum.all?([:run_id, :incarnation], &(subject[&1] === scope[&1])),
         true <- subject[:catalog_revision] === revision,
         true <- authority[:caller] === scope.caller and authority[:run_id] === scope.run_id,
         true <- not Map.has_key?(subject, :caller) or subject.caller === scope.caller,
         true <-
           not Map.has_key?(subject, :tools) or
             (is_list(subject.tools) and Enum.sort(subject.tools) === Enum.sort(tools)),
         true <-
           Enum.all?(descriptors, fn {name, descriptor} ->
             Map.has_key?(issued, name) and descriptor === issued[name]
           end) do
      identity = Map.take(scope, @identity_fields)

      selected =
        Map.new(descriptors, fn {name, descriptor} ->
          {name, descriptor_binding(descriptor, identity, catalog)}
        end)

      {:ok,
       %{
         snapshot
         | scope: Map.put(scope, :catalog_revision, revision),
           selected: selected,
           known_bindings: Map.merge(snapshot.known_bindings, selected)
       }}
    else
      _ -> {:error, :scope_mismatch}
    end
  end

  def project_catalog(_, _, _), do: {:error, :invalid_tool_snapshot}

  @doc "Checks the current issued binding before any argument classification."
  def preparation_binding(invocation, %{scope: scope, selected: selected} = snapshot)
      when is_map(invocation) and is_map(scope) and is_map(selected) do
    with :ok <- matching_scope(invocation, scope),
         {:ok, binding} <- selected_binding(invocation, selected),
         {:ok, current} <- Freshness.capture(scope.session_id, @dependencies),
         :ok <- Freshness.check(snapshot.evidence, current),
         :ok <- skills_current(snapshot.skill_snapshot),
         {:ok, descriptor} <- Map.fetch(snapshot.issued_descriptors, invocation.tool_name) do
      {:ok, %{descriptor: descriptor, binding: binding}}
    else
      :error -> {:error, :unknown_tool}
      {:needs_review, reason} -> {:error, reason}
      error -> error
    end
  end

  def preparation_binding(_, _), do: {:error, :invalid_tool_snapshot}

  @doc "Prepare body access from the real search and its exact native paired reader."
  def prepare_skill_search(%{tool_name: "synapsis::skills_search"} = operation, catalog, snapshot) do
    with {:ok, projected} <- project_catalog(operation, snapshot, catalog),
         {:ok, %{descriptor: search}} <- preparation_binding(operation, projected),
         true <-
           search.backend == Skills and
             search.backend_context.snapshot === snapshot.skill_snapshot,
         {:ok, revision} <- current_skill_permission(projected) do
      reader = Map.get(catalog.registry.tools, "synapsis::skills_read")
      paired = Map.get(snapshot.issued_descriptors, "synapsis::skills_read")

      if is_map(reader) and reader === paired and reader.backend == Skills and
           reader.tool_revision == search.tool_revision and
           reader.backend_context === search.backend_context do
        binding = Map.fetch!(projected.selected, "synapsis::skills_read")

        with {:ok, targets} <- skill_search_targets(projected, binding),
             :ok <- skills_current(snapshot.skill_snapshot) do
          {:ok,
           %{
             catalog_id: search.backend_context.catalog_id,
             availability: reader,
             targets: targets,
             permission_revision: revision
           }}
        end
      else
        {:ok,
         %{
           catalog_id: search.backend_context.catalog_id,
           availability: :metadata_only,
           targets: %{},
           permission_revision: revision
         }}
      end
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  def prepare_skill_search(_, _, _), do: {:error, :invalid_tool_snapshot}

  defp current_skill_permission(%{
         scope: scope,
         permission: expected,
         permission_revision: revision
       })
       when is_integer(revision) do
    with {:ok, %{value: raw, revision: ^revision}} <-
           Store.value_snapshot(scope.session_id, "permission"),
         true <- PermissionSnapshot.fingerprint(raw) === PermissionSnapshot.fingerprint(expected) do
      {:ok, revision}
    else
      _ -> {:error, :freshness_changed}
    end
  end

  defp current_skill_permission(_), do: {:error, :invalid_tool_snapshot}

  defp skill_search_targets(snapshot, reader_binding) do
    SkillReader.bindings(snapshot.skill_snapshot)
    |> Enum.filter(&(&1.entry.enabled and &1.entry.prompt_visible))
    |> Enum.reduce_while({:ok, %{}}, fn assigned, {:ok, targets} ->
      with {:ok, target} <- Skills.read_target(snapshot.skill_snapshot, assigned),
           target =
             Map.merge(target, %{
               tool: "synapsis::skills_read",
               binding: reader_binding,
               permission_level: :read
             }),
           {:ok, policy} <-
             PermissionSnapshot.compile_invocation(
               snapshot.permission,
               snapshot.scope,
               snapshot.known_bindings,
               target
             ),
           decision when decision in [:allow, :ask, :deny] <-
             Map.get(policy.decisions, {target.tool, target.action, target.resource}) do
        {:cont, {:ok, Map.put(targets, SkillReader.binding_key(assigned), decision)}}
      else
        {:needs_review, reason} -> {:halt, {:error, reason}}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_tool_snapshot}}
      end
    end)
  end

  def prepare_context(invocation, %{scope: scope, selected: selected} = snapshot)
      when is_map(invocation) and is_map(scope) and is_map(selected) do
    with {:ok, %{binding: binding}} <- preparation_binding(invocation, snapshot),
         {:ok, target} <- binding.classify.(invocation),
         target =
           Map.merge(target, %{
             tool: invocation.tool_name,
             binding: binding
           }),
         target =
           if(Map.has_key?(target, :permission_levels),
             do: target,
             else:
               Map.put_new(
                 target,
                 :permission_level,
                 Map.fetch!(snapshot.permission_levels, invocation.tool_name)
               )
           ),
         {:ok, policy} <-
           PermissionSnapshot.compile_invocation(
             snapshot.permission,
             scope,
             snapshot.known_bindings,
             target
           ) do
      readiness = %{
        scope: scope,
        tools: %{
          invocation.tool_name => %{tool_revision: invocation.tool_revision, status: :ready}
        }
      }

      {:ok, %{tool_scope: scope, tool_policy: policy, tool_readiness: readiness}}
    else
      {:needs_review, reason} -> {:error, reason}
      error -> error
    end
  end

  def prepare_context(_, _), do: {:error, :invalid_tool_snapshot}

  defp identity_valid(%{session: %{id: session_id}}, identity, ceiling)
       when is_map(identity) and is_map(ceiling) do
    if Enum.sort(Map.keys(identity)) == Enum.sort(@identity_fields) and
         identity[:session_id] === session_id and exact_name?(session_id) and
         identity[:caller] === ceiling[:caller] and identity[:run_id] === ceiling[:run_id] do
      Readiness.check(%{scope: identity, tools: %{}}, %{scope: identity, tools: %{}})
    else
      {:error, :scope_mismatch}
    end
  end

  defp identity_valid(_, _, _), do: {:error, :invalid_scope}

  # Dynamic candidates retain original source identity and native publication.
  defp available(names, native_bundles, mcp) when is_list(native_bundles) do
    native_names =
      Enum.flat_map(native_bundles, fn
        %{registry: %{tools: tools}} when is_map(tools) ->
          Map.keys(tools)
          |> Enum.filter(
            &(&1 in @collaboration or &1 in @local or &1 in @web or &1 in @browser or
                &1 in @code_mode or &1 in @mcp_resources or &1 in @process_inspection)
          )

        _ ->
          []
      end)

    case names --
           (@memory ++
              @host_memory ++
              @semantic ++
              @filesystem ++
              @questions ++
              @session_state ++
              @summary ++
              @skills ++
              @explicit_skill ++
              @skill_workshop ++
              @session_status ++
              @session_directory ++
              @history ++
              @directory ++
              @automations ++
              @automation_management ++
              @automation_configuration ++
              @automation_mutation ++
              @automation_wake ++
              @inspection ++ native_names ++ Enum.map(mcp, & &1.tool_name)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.new(
           :unsupported_capability,
           "selected tools are unavailable: " <> Enum.join(missing, ", "),
           details: %{tools: missing}
         )}
    end
  end

  defp available(_, _, _), do: invalid("native bundles must be an explicit list")

  defp mcp_descriptors(context, identity) do
    scope = Map.take(identity, [:run_id, :incarnation, :catalog_revision])

    case Map.get(context.agent, :mcp_sources, %{}) do
      sources when is_map(sources) ->
        Enum.reduce_while(Enum.sort_by(sources, &elem(&1, 0)), {:ok, []}, fn
          {id, %{source_id: id} = source}, {:ok, descriptors} ->
            case MCP.descriptors(Map.put(scope, :source, source)) do
              {:ok, next} -> {:cont, {:ok, descriptors ++ next}}
              error -> {:halt, error}
            end

          _, _ ->
            {:halt, invalid("invalid MCP source snapshots")}
        end)

      _ ->
        invalid("invalid MCP source snapshots")
    end
  end

  defp permission(session_id) do
    raw = Store.get_value(session_id, "permission", :permission_unavailable)

    case PermissionSnapshot.validate(raw, session_id) do
      :ok -> {:ok, raw}
      {:needs_review, reason} -> {:error, reason}
    end
  end

  defp descriptors(context, identity, names, raw) do
    scope = Map.take(identity, [:run_id, :incarnation, :catalog_revision])

    with {:ok, agent} <- domain_agent(context, names),
         {:ok, files} <- filesystem_descriptors(context, scope, names, agent),
         {:ok, semantic} <- semantic_descriptors(context, scope, names, agent),
         {:ok, questions} <- question_descriptors(context, scope, names, raw),
         {:ok, session} <- session_descriptors(context, scope, names),
         {:ok, summary} <- summary_descriptors(context, scope, names),
         {:ok, sessions} <- session_directory_descriptors(context, scope, names, agent),
         {:ok, status} <- status_descriptors(context, scope, names, agent),
         {:ok, history} <- history_descriptors(context, scope, names, agent),
         {:ok, directory} <- directory_descriptors(context, scope, names),
         {:ok, automations} <- automation_descriptors(context, scope, names),
         {:ok, automation_management} <- automation_management_descriptors(context, scope, names),
         {:ok, automation_configuration} <-
           automation_configuration_descriptors(context, scope, names),
         {:ok, automation_mutation} <- automation_mutation_descriptors(context, scope, names),
         {:ok, automation_wake} <- automation_wake_descriptors(context, scope, names),
         {:ok, memory} <- memory_descriptors(context, scope, names),
         {:ok, host_memory} <- host_memory_descriptors(scope, names),
         {:ok, inspection} <- inspection_descriptors(context, identity, names),
         {:ok, skills, snapshot, skill_cache} <- skill_descriptors(context, scope, names) do
      {:ok,
       Enum.filter(
         files ++
           semantic ++
           questions ++
           session ++
           summary ++
           status ++
           sessions ++
           history ++
           directory ++
           automations ++
           automation_management ++
           automation_configuration ++
           automation_mutation ++
           automation_wake ++
           memory ++ host_memory ++ skills ++ inspection,
         &(&1.tool_name in names)
       ), snapshot, skill_cache}
    end
  end

  defp inspection_descriptors(context, identity, names) do
    if Enum.any?(names, &(&1 in @inspection)),
      do:
        ToolInspection.descriptors(%{
          identity: identity,
          session_binding: context[:tool_session_binding],
          inventory: %{},
          mcp_sources: %{}
        }),
      else: {:ok, []}
  end

  defp question_descriptors(context, scope, names, raw) do
    if Enum.any?(names, &(&1 in @questions)) do
      Questions.descriptors(
        Map.merge(scope, %{
          session_id: context.session.id,
          primary?: Map.get(context, :tool_primary?, true),
          permission_fingerprint: PermissionSnapshot.fingerprint(raw)
        })
      )
    else
      {:ok, []}
    end
  end

  defp session_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @session_state)),
      do: SessionState.descriptors(Map.put(scope, :session_id, context.session.id)),
      else: {:ok, []}
  end

  defp summary_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @summary)),
      do: SessionSummary.descriptors(Map.put(scope, :session_id, context.session.id)),
      else: {:ok, []}
  end

  defp directory_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @directory)),
      do:
        AgentDirectory.descriptors(
          Map.merge(scope, %{
            session_id: context.session.id,
            requester_name: context.agent[:name]
          })
        ),
      else: {:ok, []}
  end

  defp automation_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @automations)),
      do:
        Automations.descriptors(
          Map.merge(scope, %{
            session_id: context.session.id,
            requester_name: context.agent[:name]
          })
        ),
      else: {:ok, []}
  end

  defp automation_configuration_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @automation_configuration)),
      do:
        AutomationConfiguration.descriptors(
          Map.merge(scope, %{
            session_id: context.session.id,
            creator_agent_id: context.agent[:id],
            requester_name: context.agent[:name]
          })
        ),
      else: {:ok, []}
  end

  defp automation_management_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @automation_management)),
      do:
        AutomationManagement.descriptors(
          Map.merge(scope, %{
            session_id: context.session.id,
            requester_name: context.agent[:name]
          })
        ),
      else: {:ok, []}
  end

  defp automation_mutation_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @automation_mutation)),
      do:
        AutomationMutation.descriptors(
          Map.merge(scope, %{
            session_id: context.session.id,
            creator_agent_id: context.agent[:id],
            requester_name: context.agent[:name]
          }),
          names
        ),
      else: {:ok, []}
  end

  defp automation_wake_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @automation_wake)),
      do:
        AutomationWake.descriptors(
          Map.merge(scope, %{
            session_id: context.session.id,
            source_agent_id: context.agent[:id],
            requester_name: context.agent[:name],
            primary?: Map.get(context, :tool_primary?, true)
          })
        ),
      else: {:ok, []}
  end

  defp domain_agent(context, names) do
    if Enum.any?(
         names,
         &(&1 in @filesystem or &1 in @semantic or &1 in @history or &1 in @session_directory or
             &1 in @session_status)
       ) do
      with name when is_binary(name) <- context.agent[:name],
           %Synapsis.AgentConfig{enabled: true} = agent <- AgentConfigs.get_by_name(name) do
        {:ok, agent}
      else
        _ -> {:error, :agent_unavailable}
      end
    else
      {:ok, nil}
    end
  end

  defp session_directory_descriptors(context, scope, names, agent) do
    if Enum.any?(names, &(&1 in @session_directory)),
      do:
        SessionDirectory.descriptors(
          Map.merge(scope, %{session_id: context.session.id, agent_id: agent.name})
        ),
      else: {:ok, []}
  end

  defp status_descriptors(context, scope, names, agent) do
    if Enum.any?(names, &(&1 in @session_status)),
      do:
        SessionStatus.descriptors(
          Map.merge(scope, %{session_id: context.session.id, agent_id: agent.name})
        ),
      else: {:ok, []}
  end

  defp history_descriptors(context, scope, names, agent) do
    if Enum.any?(names, &(&1 in @history)),
      do:
        SessionHistory.descriptors(
          Map.merge(scope, %{session_id: context.session.id, agent_id: agent.name})
        ),
      else: {:ok, []}
  end

  defp filesystem_descriptors(context, scope, names, agent) do
    if Enum.any?(names, &(&1 in @filesystem)) do
      Filesystem.descriptors(
        Map.merge(scope, %{
          root: context[:project_path],
          workspace: %{role: :session, agent_id: agent.name, session_id: context.session.id},
          path_environment: get_in(context, [:tool_filesystem, :path_environment]),
          prepared_target_resolver:
            get_in(context, [:tool_filesystem, :prepared_target_resolver]),
          execution_options: get_in(context, [:tool_filesystem, :execution_options])
        })
      )
    else
      {:ok, []}
    end
  end

  defp semantic_descriptors(context, scope, names, agent) do
    if Enum.any?(names, &(&1 in @semantic)) do
      MemoryDomain.descriptors(
        Map.merge(scope, %{
          project_path: context[:project_path],
          session_id: context.session.id,
          agent_id: agent.id
        })
      )
    else
      {:ok, []}
    end
  end

  defp memory_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @memory)),
      do: WorkspaceMemory.descriptors(Map.put(scope, :root, context[:project_path])),
      else: {:ok, []}
  end

  defp host_memory_descriptors(scope, names) do
    if Enum.any?(names, &(&1 in @host_memory)) do
      with {:ok, source} <- Synapsis.Memory.Settings.host_source(),
           {:ok, descriptors} <- HostMemory.descriptors(Map.put(scope, :source, source)),
           true <- Enum.any?(descriptors, &(&1.tool_name in @host_memory)) do
        {:ok, Enum.filter(descriptors, &(&1.tool_name in @host_memory))}
      else
        false -> {:error, :host_memory_unavailable}
        error -> error
      end
    else
      {:ok, []}
    end
  end

  defp skill_permission_revision(context, names, identity, raw) do
    if "synapsis::skills_search" in names and is_function(context[:skill_search_preparation], 2) and
         is_map(context[:tool_session_binding]) do
      with {:ok, %{value: value, revision: revision}} <-
             Store.value_snapshot(identity.session_id, "permission"),
           true <- PermissionSnapshot.fingerprint(value) === PermissionSnapshot.fingerprint(raw) do
        {:ok, revision}
      else
        _ -> {:error, :freshness_changed}
      end
    else
      {:ok, nil}
    end
  end

  defp skill_descriptors(context, scope, names) do
    if Enum.any?(names, &(&1 in @skills or &1 in @explicit_skill or &1 in @skill_workshop)) do
      with snapshot when is_map(snapshot) <- context.agent[:skill_snapshot],
           true <- SkillDiscovery.valid_snapshot?(snapshot),
           true <- context.agent[:skill_catalog] === SkillDiscovery.entries(snapshot),
           skill_scope = Map.put(scope, :snapshot, snapshot),
           {:ok, explicit} <-
             if(Enum.any?(names, &(&1 in @explicit_skill)),
               do: ExplicitSkill.descriptors(skill_scope),
               else: {:ok, []}
             ),
           {:ok, workshop} <- workshop_descriptors(context, scope, names, snapshot),
           {:ok, automatic_scope, cache} <- skill_search_scope(context, skill_scope, names) do
        result =
          if Enum.any?(names, &(&1 in @skills)),
            do: Skills.descriptors(automatic_scope),
            else: {:ok, []}

        case result do
          {:ok, automatic} ->
            {:ok, automatic ++ explicit ++ workshop, snapshot, cache}

          error ->
            SkillBodyCache.release(cache)
            error
        end
      else
        _ -> {:error, :skills_unavailable}
      end
    else
      {:ok, [], nil, nil}
    end
  end

  defp workshop_descriptors(context, scope, names, snapshot) do
    if Enum.any?(names, &(&1 in @skill_workshop)) do
      SkillWorkshop.descriptors(
        Map.merge(scope, %{
          scope: snapshot.learned.scope,
          session_id: context.session.id,
          prepare_successor: context[:skill_workshop_preparation]
        })
      )
    else
      {:ok, []}
    end
  end

  @doc "Prepare a strictly admitted successor while preserving active and deferred membership."
  def skill_successor(context, issued, catalog, snapshot, binding, preparation, ceiling) do
    names = Map.keys(issued.issued_descriptors)
    readers = Enum.filter(names, &(&1 in @skills or &1 in @explicit_skill))

    identity =
      Map.put(Map.take(issued.scope, @identity_fields), :catalog_revision, catalog.revision + 1)

    agent =
      context.agent
      |> Map.put(:skill_snapshot, snapshot)
      |> Map.put(:skill_catalog, SkillDiscovery.entries(snapshot))

    capture_context =
      context
      |> Map.put(:agent, agent)
      |> Map.put(:tool_session_binding, binding)
      |> Map.put(:skill_search_preparation, preparation)

    with {:ok, replacements, _reader_snapshot, cache} <-
           skill_descriptors(
             capture_context,
             Map.take(identity, [:run_id, :incarnation, :catalog_revision]),
             readers
           ) do
      descriptors =
        Map.merge(issued.issued_descriptors, Map.new(replacements, &{&1.tool_name, &1}))

      result = successor_bundle(descriptors, context.agent, catalog, binding, ceiling)

      case result do
        {:ok, full, active, discovery} ->
          selected =
            Map.new(full.registry.tools, fn {name, descriptor} ->
              {name, descriptor_binding(descriptor, identity)}
            end)

          next = %{
            issued
            | scope: Map.put(issued.scope, :catalog_revision, identity.catalog_revision),
              skill_snapshot: snapshot,
              skill_body_cache: cache,
              issued_descriptors: full.registry.tools,
              selected: selected,
              known_bindings: Map.merge(issued.known_bindings, selected)
          }

          {:ok, %{bundle: active, snapshot: next, skill_body_cache: cache, discovery: discovery}}

        error ->
          SkillBodyCache.release(cache)
          error
      end
    end
  end

  defp successor_bundle(descriptors, agent, catalog, binding, ceiling) do
    active = Map.keys(catalog.registry.tools)
    deferred = Map.get(agent, :deferred_tool_names, []) -- active
    names = Map.keys(descriptors)

    with {:ok, full} <- Catalog.compose([], Map.values(descriptors), ceiling, names) do
      if deferred == [] do
        with {:ok, active_bundle} <- Catalog.compose([full], [], ceiling, active),
             do: {:ok, full, active_bundle, nil}
      else
        selected = names -- ["tool_search"]
        plan = %{selected: selected, deferred: deferred, runtime: names, initial: active}
        # A new native discovery resource owns the newly frozen deferred readers.
        # No existing candidate runtime or previously issued descriptor is retargeted.
        source =
          Map.update!(full, :registry, fn registry ->
            %{registry | tools: Map.delete(registry.tools, "tool_search")}
          end)

        with {:ok, issued, initial, discovery} <-
               Discovery.prepare(source, plan, binding, ceiling),
             do: {:ok, issued, initial, discovery}
      end
    end
  end

  defp skill_search_scope(context, scope, names) do
    if "synapsis::skills_search" in names and is_function(context[:skill_search_preparation], 2) and
         is_map(context[:tool_session_binding]) do
      catalog_id = make_ref()

      with {:ok, cache} <- SkillBodyCache.start(context.tool_session_binding, catalog_id) do
        {:ok,
         Map.merge(scope, %{
           catalog_id: catalog_id,
           body_cache: cache,
           prepare_search: context.skill_search_preparation
         }), cache}
      end
    else
      {:ok, scope, nil}
    end
  end

  defp descriptor_binding(descriptor, identity, catalog \\ nil)

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @browser do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &Browser.classify(descriptor, identity, classification_operation(&1, descriptor, catalog))
    }
  end

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @web_search do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &Search.classify(descriptor, identity, classification_operation(&1, descriptor, catalog))
    }
  end

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @web_fetch do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &Fetch.classify(descriptor, identity, classification_operation(&1, descriptor, catalog))
    }
  end

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @code_mode do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &CodeMode.classify(
          descriptor,
          identity,
          classification_operation(&1, descriptor, catalog)
        )
    }
  end

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @process_inspection do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &ProcessInspection.classify(
          descriptor,
          identity,
          classification_operation(&1, descriptor, catalog)
        )
    }
  end

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @local do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &NativeLocal.classify(
          descriptor,
          identity,
          classification_operation(&1, descriptor, catalog)
        )
    }
  end

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @collaboration do
    %{
      tool_revision: descriptor.tool_revision,
      classify: fn invocation ->
        classify_collaboration(
          descriptor,
          identity,
          classification_operation(invocation, descriptor, catalog)
        )
      end
    }
  end

  defp descriptor_binding(%{tool_name: name} = descriptor, identity, catalog)
       when name in @mcp_resources do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &MCPResources.classify(
          descriptor,
          identity,
          classification_operation(&1, descriptor, catalog)
        )
    }
  end

  defp descriptor_binding(%{tool_name: "tool_search"} = descriptor, identity, catalog) do
    %{
      tool_revision: descriptor.tool_revision,
      classify:
        &Discovery.classify(
          descriptor,
          identity,
          classification_operation(&1, descriptor, catalog)
        )
    }
  end

  defp descriptor_binding(descriptor, _identity, catalog) do
    %{
      tool_revision: descriptor.tool_revision,
      classify: fn invocation ->
        descriptor.backend.classify(
          descriptor.backend_context,
          classification_operation(invocation, descriptor, catalog)
        )
      end
    }
  end

  defp classification_operation(invocation, descriptor, catalog) do
    context =
      if is_nil(catalog),
        do: descriptor.backend_context,
        else: Map.put(descriptor.backend_context, :catalog_snapshot, catalog)

    Map.put(invocation, :backend_context, context)
  end

  defp classify_collaboration(
         %{
           backend: Backend,
           backend_context: %{family: :collaboration, profile: :v2, runtime: runtime}
         } = descriptor,
         identity,
         invocation
       )
       when is_pid(runtime) do
    with true <-
           invocation[:tool_name] === descriptor.tool_name and
             invocation[:tool_revision] === descriptor.tool_revision and
             invocation[:collaboration_binding] === descriptor[:collaboration_binding],
         :ok <- CatalogBinding.descriptor(descriptor, identity, invocation),
         {:ok, _} <- InputSchema.validate(descriptor.schema, invocation[:arguments]) do
      {:ok,
       %{
         action: Map.fetch!(@collaboration_actions, descriptor.tool_name),
         resource: "collaboration:session:" <> identity.session_id
       }}
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  defp classify_collaboration(_, _, _), do: {:error, :unsupported_classification}

  defp unavailable_classification(_), do: {:error, :tool_unavailable}

  defp permission_level(name) when name in @inspection, do: ToolInspection.permission_level(name)
  defp permission_level(name) when name in @browser, do: Browser.permission_level(name)

  defp permission_level(name) when name in @web_fetch, do: Fetch.permission_level(name)
  defp permission_level(name) when name in @web_search, do: Search.permission_level(name)
  defp permission_level(name) when name in @code_mode, do: CodeMode.permission_level(name)

  defp permission_level(name) when name in @local, do: NativeLocal.permission_level(name)

  defp permission_level(name) when name in @process_inspection,
    do: ProcessInspection.permission_level(name)

  defp permission_level(name) when name in @session_status,
    do: SessionStatus.permission_level(name)

  defp permission_level(name) when name in @session_directory,
    do: SessionDirectory.permission_level(name)

  defp permission_level(name) when name in @history, do: SessionHistory.permission_level(name)

  defp permission_level(name) when name in @filesystem, do: Filesystem.permission_level(name)

  defp permission_level(name) when name in ~w(synapsis::memory_save synapsis::memory_update),
    do: :write

  defp permission_level(name) when name in @collaboration, do: :none

  defp permission_level(name) when name in @questions or name in @session_state, do: :none
  defp permission_level(name) when name in @explicit_skill, do: :none

  defp permission_level(name) when name in @skill_workshop,
    do: SkillWorkshop.permission_level(name)

  defp permission_level(name) when name in @automation_configuration,
    do: AutomationConfiguration.permission_level(name)

  defp permission_level(name) when name in @automation_management,
    do: AutomationManagement.permission_level(name)

  defp permission_level(name) when name in @automation_mutation,
    do: AutomationMutation.permission_level(name)

  defp permission_level(name) when name in @automation_wake,
    do: AutomationWake.permission_level(name)

  defp permission_level(_), do: :read

  defp matching_scope(invocation, scope) do
    if Enum.all?(
         [:run_id, :incarnation, :catalog_revision],
         &(Map.get(invocation, &1) === scope[&1])
       ),
       do: :ok,
       else: {:error, :scope_mismatch}
  end

  defp selected_binding(%{tool_name: name, tool_revision: revision}, selected) do
    case selected[name] do
      %{tool_revision: ^revision} = binding -> {:ok, binding}
      nil -> {:error, :unknown_tool}
      _ -> {:error, :stale_policy}
    end
  end

  defp selected_binding(_, _), do: {:error, :invalid_invocation}

  defp skills_current(nil), do: :ok

  defp skills_current(%{schema: 2} = snapshot), do: SkillDiscovery.assigned_current(snapshot)

  defp skills_current(snapshot) do
    case SkillReader.snapshot(snapshot.agent_id) do
      {:ok, ^snapshot} -> :ok
      _ -> {:error, :skills_changed}
    end
  end

  defp exact_name?(value),
    do:
      is_binary(value) and String.trim(value) != "" and
        not String.contains?(value, ["*", "?", "(", ")"])

  defp invalid(message), do: {:error, Error.new(:validation, message)}
end
