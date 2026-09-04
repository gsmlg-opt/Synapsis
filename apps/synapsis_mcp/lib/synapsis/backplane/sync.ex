defmodule Synapsis.Backplane.Sync do
  @moduledoc "Synchronizes normalized Backplane snapshots into capability stores."

  alias Synapsis.Backplane.{Client, Connection, Events, Snapshot}
  alias Synapsis.{MCPConfigs, Providers, Skills}

  @max_error_length 500

  def status(connection_id) do
    with {:ok, connection} <- Connection.get(connection_id) do
      {:ok, Connection.redacted(connection)}
    end
  end

  def run(connection_id, opts \\ []) when is_binary(connection_id) do
    if Keyword.get(opts, :already_locked, false) do
      do_run(connection_id, opts)
    else
      with_lock(connection_id, opts, fn -> do_run(connection_id, opts) end)
    end
  end

  @doc "Runs a callback under the bounded per-connection reconciliation lock."
  def with_lock(connection_id, opts, fun)
      when is_binary(connection_id) and is_list(opts) and is_function(fun, 0) do
    with {:ok, retries} <- lock_retries(opts) do
      lock_id = {{__MODULE__, :connection, connection_id}, self()}

      case :global.trans(lock_id, fun, [node()], retries) do
        :aborted -> {:error, :sync_busy}
        result -> result
      end
    end
  end

  defp do_run(connection_id, opts) do
    with {:ok, connection} <- Connection.get(connection_id),
         now <- now(opts),
         {:ok, attempted} <- Connection.update(connection, %{last_attempt_at: now}) do
      Events.started(attempted)
      previous_state = managed_capability_state(attempted)

      case fetch_snapshot(attempted, opts) do
        {:ok, snapshot} ->
          case reconcile_snapshot(attempted, snapshot, opts) do
            {:ok, reconciliation} ->
              result = finalize_sync(attempted, reconciliation, now)

              publish_sync_result(
                result,
                surface_reconciled?(snapshot) and capabilities_changed?(previous_state, result)
              )

            {:error, reason} ->
              attempted |> persist_failure(reason) |> publish_sync_result(false)
          end

        {:error, reason} ->
          attempted |> persist_failure(reason) |> publish_sync_result(false)
      end
    end
  end

  defp publish_sync_result({:ok, connection} = result, capabilities_updated?) do
    if connection.status == "ready",
      do: Events.completed(connection),
      else: Events.failed(connection)

    if capabilities_updated?, do: Events.capabilities_updated(connection)
    result
  end

  defp publish_sync_result(error, _capabilities_updated?), do: error

  defp capabilities_changed?(previous_state, {:ok, connection}),
    do: previous_state != managed_capability_state(connection)

  defp capabilities_changed?(_previous_state, _error), do: false

  defp surface_reconciled?(snapshot) do
    Enum.any?([:models, :skills, :mcp_tools], &(!Map.has_key?(snapshot.errors, &1)))
  end

  def set_available(connection_id, available, opts \\ [])
      when is_binary(connection_id) and is_boolean(available) do
    if Keyword.get(opts, :already_locked, false) do
      do_set_available(connection_id, available, opts)
    else
      with_lock(connection_id, opts, fn -> do_set_available(connection_id, available, opts) end)
    end
  end

  defp do_set_available(connection_id, available, opts) do
    runtime = Keyword.get(opts, :mcp_runtime, Synapsis.MCP)

    with {:ok, connection} <- Connection.get(connection_id) do
      previous_state = managed_capability_state(connection)

      result =
        with :ok <- set_providers_available(connection_id, available),
             :ok <- set_skills_available(connection_id, available),
             :ok <- set_mcps_available(connection_id, available, runtime) do
          Connection.update(connection, %{
            stale: not available,
            status: if(available, do: "ready", else: "degraded"),
            unavailable: if(available, do: [], else: ~w(models skills tools))
          })
        end

      if capabilities_changed?(previous_state, result) do
        {:ok, persisted} = result
        Events.capabilities_updated(persisted)
      end

      result
    end
  end

  defp managed_capability_state(connection) do
    providers =
      case Providers.list() do
        {:ok, listed} ->
          listed
          |> Enum.filter(&owned?(&1.config, connection.id, "provider"))
          |> Enum.map(&Map.take(&1, [:id, :name, :type, :base_url, :api_key_encrypted, :config]))
          |> Enum.sort_by(& &1.id)

        _error ->
          []
      end

    skills =
      connection.id
      |> owned_skills()
      |> Enum.map(
        &Map.take(&1, [
          :id,
          :name,
          :description,
          :system_prompt_fragment,
          :config_overrides
        ])
      )
      |> Enum.sort_by(& &1.id)

    mcps =
      MCPConfigs.list()
      |> Enum.filter(&owned?(&1.config, connection.id, "mcp_server"))
      |> Enum.map(&Map.take(&1, [:id, :name, :transport, :command, :args, :env, :url, :config]))
      |> Enum.sort_by(& &1.id)

    %{
      artifacts: connection.artifacts || %{},
      revisions: Map.get(connection.metadata || %{}, "surface_revisions", %{}),
      providers: providers,
      skills: skills,
      mcps: mcps
    }
  end

  defp fetch_snapshot(connection, opts) do
    client = Keyword.get(opts, :client, Client)
    client_opts = Keyword.get(opts, :client_opts, [])

    protect(fn ->
      if is_function(client, 2),
        do: client.(connection, client_opts),
        else: client.fetch_snapshot(connection, client_opts)
    end)
    |> case do
      {:ok, %Snapshot{} = snapshot} -> {:ok, snapshot}
      {:ok, other} -> {:error, {:invalid_snapshot, other}}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_snapshot_response, other}}
    end
  end

  defp reconcile_snapshot(connection, %Snapshot{} = snapshot, opts) do
    runtime = Keyword.get(opts, :mcp_runtime, Synapsis.MCP)

    initial = %{
      artifacts: reconstruct_artifacts(connection.id),
      counts: connection.counts || %{},
      revisions: Map.get(connection.metadata || %{}, "surface_revisions", %{}),
      errors: snapshot.errors
    }

    with {:ok, result} <- reconcile_models_surface(initial, connection, snapshot),
         {:ok, result} <- reconcile_skills_surface(result, connection, snapshot),
         {:ok, result} <- reconcile_tools_surface(result, connection, snapshot, runtime) do
      {:ok, result}
    end
  end

  defp reconcile_models_surface(result, connection, snapshot) do
    if Map.has_key?(snapshot.errors, :models) do
      {:ok, result}
    else
      with {:ok, provider} <- reconcile_provider(connection, snapshot) do
        {:ok,
         result
         |> put_in([:artifacts, "provider_id"], provider.id)
         |> put_in([:counts, "models"], length(snapshot.models))
         |> put_surface_revision(:models, snapshot)}
      end
    end
  end

  defp reconcile_skills_surface(result, connection, snapshot) do
    if Map.has_key?(snapshot.errors, :skills) do
      {:ok, result}
    else
      with {:ok, skills} <- reconcile_skills(connection, snapshot.skills) do
        ids = Map.new(skills, &{marker(&1.config_overrides, "external_id"), &1.id})

        {:ok,
         result
         |> put_in([:artifacts, "skill_ids"], ids)
         |> put_in([:counts, "skills"], length(snapshot.skills))
         |> put_surface_revision(:skills, snapshot)}
      end
    end
  end

  defp reconcile_tools_surface(result, connection, snapshot, runtime) do
    if Map.has_key?(snapshot.errors, :mcp_tools) do
      {:ok, result}
    else
      with {:ok, mcp} <- reconcile_mcp_config(connection, snapshot, runtime) do
        {:ok,
         result
         |> put_in([:artifacts, "mcp_id"], mcp.id)
         |> put_in([:counts, "tools"], length(snapshot.mcp_tools))
         |> put_surface_revision(:mcp_tools, snapshot)}
      end
    end
  end

  defp put_surface_revision(result, surface, snapshot) do
    case Map.fetch(snapshot.surface_revisions, surface) do
      {:ok, revision} -> put_in(result, [:revisions, Atom.to_string(surface)], revision)
      :error -> result
    end
  end

  defp finalize_sync(connection, reconciliation, now) do
    errors = reconciliation.errors
    success? = map_size(errors) == 0
    surface_errors = sanitize_surface_errors(errors, connection.credential)

    metadata =
      Map.merge(connection.metadata || %{}, %{
        "surface_errors" => surface_errors,
        "surface_revisions" => reconciliation.revisions
      })

    source_revision =
      if map_size(reconciliation.revisions) == 0,
        do: connection.source_revision,
        else: Snapshot.revision(reconciliation.revisions)

    attrs = %{
      artifacts: reconciliation.artifacts,
      counts: reconciliation.counts,
      unavailable: unavailable_surfaces(errors),
      status: if(success?, do: "ready", else: "degraded"),
      stale: not success?,
      last_error: if(success?, do: nil, else: format_errors(errors, connection.credential)),
      source_revision: source_revision,
      metadata: metadata
    }

    attrs =
      if success?,
        do: Map.merge(attrs, %{last_success_at: now, last_synced_at: now}),
        else: attrs

    Connection.update(connection, attrs)
  end

  defp persist_failure(connection, reason) do
    Connection.update(connection, %{
      unavailable: ~w(models skills tools),
      status: "degraded",
      stale: true,
      last_error: format_error(reason, connection.credential),
      metadata:
        Map.put(
          connection.metadata || %{},
          "surface_errors",
          %{"snapshot" => format_error(reason, connection.credential)}
        )
    })
  end

  defp reconstruct_artifacts(connection_id) do
    provider = find_provider(connection_id, "openai-compatible")
    mcp = find_mcp(connection_id, "mcp")

    %{
      "skill_ids" =>
        Map.new(owned_skills(connection_id), &{marker(&1.config_overrides, "external_id"), &1.id})
    }
    |> maybe_put("provider_id", id_of(provider))
    |> maybe_put("mcp_id", id_of(mcp))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unavailable_surfaces(errors) do
    for {surface, public} <- [models: "models", skills: "skills", mcp_tools: "tools"],
        Map.has_key?(errors, surface),
        do: public
  end

  defp sanitize_surface_errors(errors, credential) do
    Map.new(errors, fn {surface, reason} ->
      {surface |> public_surface() |> to_string(), format_error(reason, credential)}
    end)
  end

  defp public_surface(:mcp_tools), do: :tools
  defp public_surface(surface), do: surface

  defp format_errors(errors, credential) do
    errors
    |> unavailable_surfaces()
    |> Enum.map_join(", ", fn surface ->
      internal = if surface == "tools", do: :mcp_tools, else: String.to_existing_atom(surface)
      "#{surface}: #{format_error(Map.fetch!(errors, internal), credential)}"
    end)
    |> truncate_error()
  end

  defp format_error(reason, credential) do
    message = inspect(reason)

    message =
      if is_binary(credential) and credential != "",
        do: String.replace(message, credential, "[REDACTED]"),
        else: message

    truncate_error(message)
  end

  defp truncate_error(message) when byte_size(message) <= @max_error_length, do: message

  defp truncate_error(message) do
    message
    |> binary_part(0, @max_error_length)
    |> :unicode.characters_to_binary()
    |> case do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> valid
      {:error, valid, _rest} -> valid
    end
  end

  defp reconcile_provider(connection, %Snapshot{providers: [capability], models: models}) do
    provider = find_provider(connection.id, capability.external_id)
    source_name = available_provider_name(connection, provider)
    available = models != []

    config =
      marker_map(capability, available)
      |> Map.put("source_name", source_name)
      |> Map.put("source_contents_available", available)
      |> Map.put("available_models", Enum.map(models, & &1.metadata))
      |> Map.put(
        "backplane_models",
        merge_capability_cache(
          marker(provider && provider.config, "backplane_models"),
          Enum.map(models, &capability_cache(&1, &1.enabled_by_source))
        )
      )

    attrs = %{
      name: source_name,
      type: "openai",
      base_url: connection.endpoint <> "/v1",
      api_key_encrypted: connection.credential,
      enabled: true,
      config: config
    }

    case provider do
      nil ->
        Providers.create(attrs)

      provider ->
        attrs = %{
          attrs
          | name: reconciled_name(provider.name, provider.config, attrs.name),
            config: Map.merge(provider.config || %{}, config)
        }

        Providers.update(provider.id, Map.delete(attrs, :enabled))
    end
  end

  defp reconcile_provider(_connection, _snapshot), do: {:error, :missing_provider_capability}

  defp reconcile_skills(connection, capabilities) do
    existing =
      Map.new(owned_skills(connection.id), &{marker(&1.config_overrides, "external_id"), &1})

    imported =
      capabilities
      |> Enum.reduce_while({:ok, []}, fn capability, {:ok, imported} ->
        available = skill_importable?(capability)
        metadata = capability.metadata

        attrs = %{
          name: capability.name,
          description: metadata["description"],
          system_prompt_fragment: metadata["content"],
          enabled: available,
          config_overrides:
            capability
            |> marker_map(available)
            |> Map.put("source_contents_available", skill_content_available?(capability))
        }

        result =
          case existing[capability.external_id] do
            nil ->
              Skills.create(attrs)

            skill ->
              attrs = %{
                attrs
                | name: reconciled_name(skill.name, skill.config_overrides, attrs.name),
                  config_overrides:
                    Map.merge(skill.config_overrides || %{}, attrs.config_overrides)
              }

              Skills.update(skill, Map.delete(attrs, :enabled))
          end

        case result do
          {:ok, skill} ->
            {:cont, {:ok, [skill | imported]}}

          {:error, reason} ->
            {:halt, {:error, {:skill_import_failed, capability.external_id, reason}}}
        end
      end)

    with {:ok, current} <- imported,
         {:ok, stale} <- mark_disappeared_skills(existing, capabilities) do
      {:ok, Enum.reverse(current) ++ stale}
    end
  end

  defp mark_disappeared_skills(existing, capabilities) do
    current_ids = MapSet.new(capabilities, & &1.external_id)

    existing
    |> Map.reject(fn {external_id, _skill} -> MapSet.member?(current_ids, external_id) end)
    |> Enum.reduce_while({:ok, []}, fn {_external_id, skill}, {:ok, stale} ->
      config = mark_disappeared(skill.config_overrides)

      case Skills.update(skill, %{config_overrides: config}) do
        {:ok, updated} -> {:cont, {:ok, [updated | stale]}}
        {:error, reason} -> {:halt, {:error, {:skill_disappearance_failed, reason}}}
      end
    end)
  end

  defp reconcile_mcp_config(
         connection,
         %Snapshot{mcp_servers: [capability], mcp_tools: tools},
         runtime
       ) do
    mcp = find_mcp(connection.id, capability.external_id)
    source_name = available_mcp_name(connection, mcp)
    available = tools != []

    config =
      marker_map(capability, available)
      |> Map.put("source_name", source_name)
      |> Map.put("source_contents_available", available)
      |> Map.put(
        "backplane_tools",
        merge_capability_cache(
          marker(mcp && mcp.config, "backplane_tools"),
          Enum.map(tools, &capability_cache(&1, &1.enabled_by_source))
        )
      )

    attrs = %{
      name: source_name,
      transport: "streamable_http",
      enabled: true,
      url: connection.endpoint <> "/mcp",
      headers: %{},
      config: config
    }

    result =
      case mcp do
        nil ->
          MCPConfigs.create(attrs)

        mcp ->
          attrs = %{
            attrs
            | name: reconciled_name(mcp.name, mcp.config, attrs.name),
              headers: mcp.headers || %{},
              config: Map.merge(mcp.config || %{}, config)
          }

          MCPConfigs.update(mcp, Map.delete(attrs, :enabled))
      end

    with {:ok, mcp} <- result,
         :ok <- reconcile_runtime_availability(runtime, mcp) do
      {:ok, mcp}
    end
  end

  defp reconcile_mcp_config(_connection, _snapshot, _runtime),
    do: {:error, :missing_mcp_server_capability}

  defp find_provider(connection_id, external_id) do
    case Providers.list() do
      {:ok, providers} ->
        Enum.find(providers, &owned?(&1.config, connection_id, "provider", external_id))

      _error ->
        nil
    end
  end

  defp owned_skills(connection_id) do
    Enum.filter(Skills.list(), &owned?(&1.config_overrides, connection_id, "skill"))
  end

  defp find_mcp(connection_id, external_id) do
    Enum.find(MCPConfigs.list(), &owned?(&1.config, connection_id, "mcp_server", external_id))
  end

  defp set_providers_available(connection_id, available) do
    providers =
      case Providers.list() do
        {:ok, listed} -> Enum.filter(listed, &owned?(&1.config, connection_id, "provider"))
        _error -> []
      end

    Enum.reduce_while(providers, :ok, fn provider, :ok ->
      config =
        provider.config
        |> put_effective_availability(available)
        |> update_nested_availability("backplane_models", available)

      case Providers.update(provider.id, %{config: config}) do
        {:ok, _provider} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:provider_availability_failed, reason}}}
      end
    end)
  end

  defp set_skills_available(connection_id, available) do
    connection_id
    |> owned_skills()
    |> Enum.reduce_while(:ok, fn skill, :ok ->
      config = put_effective_availability(skill.config_overrides, available)

      case Skills.update(skill, %{config_overrides: config}) do
        {:ok, _skill} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:skill_availability_failed, reason}}}
      end
    end)
  end

  defp set_mcps_available(connection_id, available, runtime) do
    MCPConfigs.list()
    |> Enum.filter(&owned?(&1.config, connection_id, "mcp_server"))
    |> Enum.reduce_while(:ok, fn mcp, :ok ->
      config =
        mcp.config
        |> put_effective_availability(available)
        |> update_nested_availability("backplane_tools", available)

      with {:ok, updated} <- MCPConfigs.update(mcp, %{config: config}),
           :ok <- reconcile_runtime_availability(runtime, updated) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:mcp_availability_failed, reason}}}
      end
    end)
  end

  defp update_nested_availability(config, key, available) do
    case Map.get(config, key) do
      capabilities when is_list(capabilities) ->
        Map.put(config, key, Enum.map(capabilities, &put_effective_availability(&1, available)))

      _missing ->
        config
    end
  end

  defp put_effective_availability(markers, requested) do
    effective = requested and restorable?(markers)
    Map.put(markers || %{}, "backplane_available", effective)
  end

  defp restorable?(markers) do
    marker(markers, "source_available") != false and
      marker(markers, "source_contents_available") != false and
      get_in(markers, ["source_metadata", "content_available"]) != false
  end

  defp reconcile_runtime_availability(
         runtime,
         %{enabled: true, config: %{"backplane_available" => true}} = mcp
       ) do
    protect(fn -> runtime.restart(mcp) end) |> normalize_runtime_result()
  end

  defp reconcile_runtime_availability(runtime, %{name: name}) do
    case protect(fn -> runtime.stop(name) end) do
      {:error, :not_found} -> :ok
      result -> normalize_runtime_result(result)
    end
  end

  defp owned?(markers, connection_id, kind, external_id \\ nil)

  defp owned?(markers, connection_id, kind, external_id) when is_map(markers) do
    marker(markers, "managed_by") == "backplane" and
      marker(markers, "source") == "backplane" and
      marker(markers, "backplane_source_id") == connection_id and
      marker(markers, "kind") == kind and
      (is_nil(external_id) or marker(markers, "external_id") == external_id)
  end

  defp owned?(_markers, _connection_id, _kind, _external_id), do: false

  defp marker_map(capability, available) do
    %{
      "managed_by" => "backplane",
      "source" => "backplane",
      "backplane_source_id" => capability.connection_id,
      "connection_id" => capability.connection_id,
      "external_id" => capability.external_id,
      "external_revision" => capability.external_revision,
      "kind" => capability.kind,
      "backplane_available" => available,
      "source_available" => capability.enabled_by_source,
      "source_name" => capability.name,
      "source_metadata" => capability.metadata
    }
  end

  defp capability_cache(capability, available), do: marker_map(capability, available)

  defp merge_capability_cache(existing, current) do
    existing = if is_list(existing), do: existing, else: []
    current_ids = MapSet.new(current, &marker(&1, "external_id"))

    stale =
      existing
      |> Enum.reject(&MapSet.member?(current_ids, marker(&1, "external_id")))
      |> Enum.map(&mark_disappeared/1)

    Enum.sort_by(current ++ stale, &marker(&1, "external_id"))
  end

  defp mark_disappeared(markers) do
    markers
    |> Map.put("source_available", false)
    |> Map.put("backplane_available", false)
  end

  defp skill_importable?(capability) do
    capability.enabled_by_source and skill_content_available?(capability)
  end

  defp skill_content_available?(capability),
    do:
      Map.get(capability.metadata, "content_available", is_binary(capability.metadata["content"]))

  defp marker(markers, key), do: Map.get(markers || %{}, key)

  defp artifact_name(connection), do: "backplane-" <> connection.name

  defp available_provider_name(connection, current) do
    names =
      case Providers.list() do
        {:ok, providers} ->
          providers |> Enum.reject(&(&1.id == id_of(current))) |> Enum.map(& &1.name)

        _error ->
          []
      end

    available_name(connection, names)
  end

  defp available_mcp_name(connection, current) do
    names =
      MCPConfigs.list()
      |> Enum.reject(&(&1.id == id_of(current)))
      |> Enum.map(& &1.name)

    available_name(connection, names)
  end

  defp available_name(connection, occupied) do
    preferred = artifact_name(connection)

    if preferred in occupied,
      do: preferred <> "-" <> String.slice(connection.id, 0, 8),
      else: preferred
  end

  defp id_of(nil), do: nil
  defp id_of(record), do: record.id

  defp reconciled_name(local_name, markers, source_name) do
    if local_name == marker(markers, "source_name"), do: source_name, else: local_name
  end

  defp now(opts) do
    opts
    |> Keyword.get(:now, &DateTime.utc_now/0)
    |> then(fn callback -> if is_function(callback, 0), do: callback.(), else: callback end)
    |> case do
      %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
      value when is_binary(value) -> value
    end
  end

  defp lock_retries(opts) do
    case Keyword.get(opts, :lock_retries, 10) do
      retries when is_integer(retries) and retries >= 0 and retries <= 100 -> {:ok, retries}
      _invalid -> {:error, :invalid_lock_retries}
    end
  end

  defp normalize_runtime_result(:ok), do: :ok
  defp normalize_runtime_result({:ok, _pid}), do: :ok

  defp normalize_runtime_result({:error, reason}),
    do: {:error, {:runtime_reconcile_failed, reason}}

  defp normalize_runtime_result(other), do: {:error, {:invalid_runtime_result, other}}

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
