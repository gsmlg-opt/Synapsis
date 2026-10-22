defmodule Synapsis.Config.ProviderCleanup do
  @moduledoc false

  alias Synapsis.Config.Store.Server

  # Called only under Store's shared mutation lock. Keep the provider and source
  # records until dependent references are scrubbed, so a failed write is retryable.
  def delete(id) do
    with {:ok, removed} <- dependencies(id) do
      with :ok <- scrub_references(removed),
           :ok <- delete_records(:model, removed.models),
           :ok <- delete_records(:mcp, removed.mcps),
           :ok <- delete_records(:skill, removed.skills),
           :ok <- delete_records(:backplane, removed.sources),
           :ok <- delete_records(:provider, [removed.provider]) do
        {:ok, removed}
      end
    end
  end

  def dependencies(id) do
    with {:ok, provider} <- Server.get(:provider, id), do: {:ok, linked_records(provider)}
  end

  defp linked_records(provider) do
    sources =
      Enum.filter(Server.list(:backplane), fn source ->
        source["provider_id"] == provider["id"] or legacy_source?(source, provider)
      end)

    source_ids = Enum.map(sources, & &1["id"])

    %{
      provider: provider,
      sources: sources,
      models: Enum.filter(Server.list(:model), &(&1["provider_id"] == provider["id"])),
      mcps:
        Enum.filter(Server.list(:mcp), fn mcp ->
          mcp["provider_id"] == provider["id"] or
            source_id(mcp["config"]) in source_ids
        end),
      skills: Enum.filter(Server.list(:skill), &(source_id(&1["config_overrides"]) in source_ids))
    }
  end

  defp legacy_source?(%{"provider_id" => id}, _provider) when not is_nil(id), do: false

  defp legacy_source?(source, provider) do
    config = provider["config"] || %{}

    source["id"] == config["backplane_source_id"] and
      config["managed_by"] == "backplane" and config["source"] == "backplane" and
      config["kind"] == "provider"
  end

  defp source_id(config) when is_map(config), do: config["backplane_source_id"]
  defp source_id(_config), do: nil

  defp scrub_references(removed) do
    prefixes = Enum.map(removed.mcps, &("mcp:" <> &1["name"] <> ":"))
    mcp_ids = Enum.map(removed.mcps, & &1["id"])
    skill_ids = Enum.map(removed.skills, & &1["id"])

    edits =
      Enum.map(Server.list(:agent), fn agent ->
        edits = %{
          "tools" => scrub_tools(agent["tools"], prefixes),
          "config" => scrub_agent_config(agent["config"], skill_ids, mcp_ids),
          "fallback_models" => scrub_fallbacks(agent, removed.provider["name"])
        }

        edits =
          if agent["provider"] == removed.provider["name"],
            do: Map.merge(edits, %{"provider" => nil, "model" => nil}),
            else: edits

        {:agent, agent, edits}
      end) ++
        Enum.map(Server.list(:toolset), fn toolset ->
          {:toolset, toolset, %{"tool_names" => scrub_tools(toolset["tool_names"], prefixes)}}
        end) ++
        Enum.map(Server.list(:skill), fn skill ->
          {:skill, skill, %{"tool_allowlist" => scrub_tools(skill["tool_allowlist"], prefixes)}}
        end)

    Enum.reduce_while(edits, :ok, fn {type, entry, attrs}, :ok ->
      # Preserve absent optional fields as well as unrelated values.
      attrs = Map.reject(attrs, fn {key, value} -> value == entry[key] end)

      if attrs == %{} do
        {:cont, :ok}
      else
        case Server.merge_existing(type, entry["id"], attrs) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, failure(type, entry["id"], reason)}
        end
      end
    end)
  end

  defp scrub_tools(tools, prefixes) when is_list(tools),
    do: Enum.reject(tools, fn name -> Enum.any?(prefixes, &String.starts_with?(name, &1)) end)

  defp scrub_tools(tools, _prefixes), do: tools

  defp scrub_agent_config(config, skill_ids, mcp_ids) when is_map(config) do
    config |> scrub_skill_ids(skill_ids) |> scrub_mcp_selection(mcp_ids)
  end

  defp scrub_agent_config(encoded, skill_ids, mcp_ids) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, config} when is_map(config) ->
        updated = scrub_agent_config(config, skill_ids, mcp_ids)
        if updated == config, do: encoded, else: Jason.encode!(updated)

      _ ->
        encoded
    end
  end

  defp scrub_agent_config(config, _skill_ids, _mcp_ids), do: config

  defp scrub_skill_ids(config, ids) do
    case config["skill_ids"] do
      values when is_list(values) -> Map.put(config, "skill_ids", values -- ids)
      _ -> config
    end
  end

  defp scrub_mcp_selection(config, ids) do
    case config["mcp_selection"] do
      %{"sources" => sources} = policy when is_map(sources) ->
        Map.put(config, "mcp_selection", Map.put(policy, "sources", Map.drop(sources, ids)))

      _ ->
        config
    end
  end

  defp scrub_fallbacks(agent, provider_name) do
    case agent["fallback_models"] do
      value when is_binary(value) ->
        entries = String.split(value, [",", "\n"], trim: true)

        kept =
          Enum.reject(entries, fn item ->
            case String.split(String.trim(item), "/", parts: 2) do
              [provider, _model] -> provider == provider_name
              [_model] -> agent["provider"] == provider_name
            end
          end)

        if kept == entries, do: value, else: Enum.join(kept, ",")

      value ->
        value
    end
  end

  defp delete_records(type, records) do
    Enum.reduce_while(records, :ok, fn entry, :ok ->
      case Server.delete(type, entry["id"]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, failure(type, entry["id"], reason)}
      end
    end)
  end

  defp failure(type, id, reason), do: {:error, {:provider_cleanup_failed, type, id, reason}}
end
