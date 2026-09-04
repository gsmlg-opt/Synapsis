defmodule Synapsis.Backplane.Sync do
  @moduledoc "Synchronizes one Backplane connection into existing capability stores."

  alias Synapsis.Backplane.{Client, Connection}
  alias Synapsis.{MCPConfigs, Providers, Skills}

  @surfaces ~w(models skills tools)
  @max_error_length 500

  def status(connection_id) do
    with {:ok, connection} <- Connection.get(connection_id) do
      {:ok, Connection.redacted(connection)}
    end
  end

  def run(connection_id, opts \\ []) when is_binary(connection_id) do
    with {:ok, connection} <- Connection.get(connection_id) do
      client = Keyword.get(opts, :client, Client)
      client_opts = Keyword.get(opts, :client_opts, [])
      mcp_runtime = Keyword.get(opts, :mcp_runtime, Synapsis.MCP)

      results = %{
        "models" => protect(fn -> client.fetch_models(connection, client_opts) end),
        "skills" => fetch_skills(client, connection, client_opts),
        "tools" => protect(fn -> client.list_tools(connection, client_opts) end)
      }

      {artifacts, counts, errors} = import_surfaces(connection, results, mcp_runtime)

      attrs = %{
        artifacts: artifacts,
        counts: counts,
        unavailable: Enum.filter(@surfaces, &Map.has_key?(errors, &1)),
        status: if(map_size(errors) == 0, do: "ready", else: "degraded"),
        last_error: format_errors(errors, connection.credential),
        last_synced_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      Connection.update(connection, attrs)
    end
  end

  defp fetch_skills(client, connection, opts) do
    with {:ok, skills} when is_list(skills) <-
           protect(fn -> client.list_skills(connection, opts) end) do
      Enum.reduce_while(skills, {:ok, []}, fn skill, {:ok, details} ->
        case Map.get(skill, "slug") do
          slug when is_binary(slug) ->
            case protect(fn -> client.fetch_skill(connection, slug, opts) end) do
              {:ok, detail} when is_map(detail) -> {:cont, {:ok, [detail | details]}}
              {:error, reason} -> {:halt, {:error, {:skill_detail, slug, reason}}}
              other -> {:halt, {:error, {:invalid_skill_detail, slug, other}}}
            end

          _invalid ->
            {:halt, {:error, :invalid_skill_list}}
        end
      end)
      |> case do
        {:ok, details} -> {:ok, Enum.reverse(details)}
        error -> error
      end
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_skills_response, other}}
    end
  end

  defp import_surfaces(connection, results, mcp_runtime) do
    artifacts = connection.artifacts || %{}
    counts = connection.counts || %{}

    Enum.reduce(@surfaces, {artifacts, counts, %{}}, fn surface, {artifacts, counts, errors} ->
      case import_surface(surface, results[surface], connection, artifacts, mcp_runtime) do
        {:ok, updated_artifacts, count} ->
          {updated_artifacts, Map.put(counts, surface, count), errors}

        {:error, reason} ->
          {artifacts, counts, Map.put(errors, surface, reason)}

        {:error, reason, updated_artifacts} ->
          {updated_artifacts, counts, Map.put(errors, surface, reason)}
      end
    end)
  end

  defp import_surface("models", {:ok, models}, connection, artifacts, _mcp_runtime)
       when is_list(models) do
    available? = models != []

    attrs = %{
      name: artifact_name(connection),
      type: "openai",
      base_url: connection.base_url <> "/v1",
      enabled: true,
      api_key_encrypted: connection.credential,
      config: %{
        "available_models" => models,
        "backplane_available" => available?,
        "backplane_source_id" => connection.id,
        "managed_by" => "backplane"
      }
    }

    with {:ok, provider} <- upsert_provider(artifacts["provider_id"], attrs) do
      {:ok, Map.put(artifacts, "provider_id", provider.id), length(models)}
    end
  end

  defp import_surface("skills", {:ok, skills}, connection, artifacts, _mcp_runtime)
       when is_list(skills) do
    existing_ids = Map.get(artifacts, "skill_ids", %{})

    imported =
      Enum.reduce_while(skills, {:ok, existing_ids}, fn detail, {:ok, ids} ->
        slug = detail["slug"]

        attrs = %{
          name: detail["name"] || slug,
          description: detail["description"],
          system_prompt_fragment: detail["content"] || detail["description"] || "",
          enabled: true,
          config_overrides: %{
            "backplane_available" => true,
            "backplane_source_id" => connection.id,
            "backplane_slug" => slug,
            "managed_by" => "backplane"
          }
        }

        case upsert_skill(ids[slug], attrs) do
          {:ok, skill} -> {:cont, {:ok, Map.put(ids, slug, skill.id)}}
          {:error, reason} -> {:halt, {:error, {slug, reason}}}
        end
      end)

    current_slugs = MapSet.new(skills, & &1["slug"])

    with {:ok, ids} <- imported,
         {:ok, ids} <- disable_stale_skills(ids, current_slugs, connection.id) do
      {:ok, Map.put(artifacts, "skill_ids", ids), length(skills)}
    end
  end

  defp import_surface("tools", {:ok, tools}, connection, artifacts, mcp_runtime)
       when is_list(tools) do
    available? = tools != []

    attrs = %{
      name: artifact_name(connection),
      transport: "streamable_http",
      enabled: true,
      url: connection.base_url <> "/mcp",
      headers: %{},
      config: %{
        "backplane_available" => available?,
        "backplane_source_id" => connection.id,
        "managed_by" => "backplane"
      }
    }

    with {:ok, config} <- upsert_mcp(artifacts["mcp_id"], attrs) do
      updated_artifacts = Map.put(artifacts, "mcp_id", config.id)

      case reconcile_mcp(mcp_runtime, config) do
        :ok -> {:ok, updated_artifacts, length(tools)}
        {:ok, _pid} -> {:ok, updated_artifacts, length(tools)}
        {:error, reason} -> {:error, {:runtime_reconcile_failed, reason}, updated_artifacts}
      end
    end
  end

  defp import_surface(_surface, {:error, reason}, _connection, _artifacts, _mcp_runtime),
    do: {:error, reason}

  defp import_surface(_surface, other, _connection, _artifacts, _mcp_runtime),
    do: {:error, {:invalid_response, other}}

  defp disable_stale_skills(ids, current_slugs, source_id) do
    ids
    |> Enum.reject(fn {slug, _id} -> MapSet.member?(current_slugs, slug) end)
    |> Enum.reduce_while({:ok, ids}, fn {slug, id}, {:ok, retained} ->
      case Skills.get(id) do
        nil ->
          {:cont, {:ok, retained}}

        %{config_overrides: %{"backplane_source_id" => ^source_id}} = skill ->
          config_overrides =
            Map.put(skill.config_overrides || %{}, "backplane_available", false)

          case Skills.update(skill, %{config_overrides: config_overrides}) do
            {:ok, _disabled} -> {:cont, {:ok, retained}}
            {:error, reason} -> {:halt, {:error, {slug, reason}}}
          end

        _not_owned ->
          {:halt, {:error, {slug, :artifact_ownership_lost}}}
      end
    end)
  end

  defp reconcile_mcp(
         mcp_runtime,
         %{enabled: true, config: %{"backplane_available" => true}} = config
       ),
    do: protect(fn -> mcp_runtime.restart(config) end)

  defp reconcile_mcp(mcp_runtime, %{name: name}) do
    case protect(fn -> mcp_runtime.stop(name) end) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end

  defp upsert_provider(nil, attrs), do: Providers.create(attrs)

  defp upsert_provider(id, attrs) do
    case Providers.get(id) do
      {:ok, provider} ->
        config = Map.merge(provider.config || %{}, attrs.config)
        attrs = attrs |> Map.delete(:enabled) |> Map.put(:config, config)
        Providers.update(id, attrs)

      {:error, :not_found} ->
        Providers.create(Map.put(attrs, :id, id))
    end
  end

  defp upsert_skill(nil, attrs), do: Skills.create(attrs)

  defp upsert_skill(id, attrs) do
    case Skills.get(id) do
      nil -> Skills.create(Map.put(attrs, :id, id))
      skill -> Skills.update(skill, Map.delete(attrs, :enabled))
    end
  end

  defp upsert_mcp(nil, attrs), do: MCPConfigs.create(attrs)

  defp upsert_mcp(id, attrs) do
    case MCPConfigs.get(id) do
      nil -> MCPConfigs.create(Map.put(attrs, :id, id))
      config -> MCPConfigs.update(config, Map.delete(attrs, :enabled))
    end
  end

  defp artifact_name(connection), do: "backplane-" <> connection.name

  defp format_errors(errors, _credential) when map_size(errors) == 0, do: nil

  defp format_errors(errors, credential) do
    message =
      errors
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(", ", fn {surface, reason} -> "#{surface}: #{inspect(reason)}" end)

    message =
      if is_binary(credential) and credential != "",
        do: String.replace(message, credential, "[REDACTED]"),
        else: message

    String.slice(message, 0, @max_error_length)
  end

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
