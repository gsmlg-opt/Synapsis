defmodule Synapsis.Sessions do
  @moduledoc "Public API for session management."

  # Worker lives in synapsis_agent (compiled after synapsis_core)
  # DebugStore lives in synapsis_server (compiled after synapsis_core)
  @compile {:no_warn_undefined, [Synapsis.Session.Worker, SynapsisServer.DebugStore]}

  alias Synapsis.{Repo, Session, Message}
  import Ecto.Query

  @transient_statuses ~w(streaming tool_executing)
  @stale_transient_status_after_seconds 120

  def create(agent_name \\ "main", opts \\ %{}) do
    agent = opts[:agent] || agent_name || "main"
    agent_config = Synapsis.Agent.Resolver.resolve(agent)
    config = %{}
    provider = opts[:provider] || agent_config.provider || default_provider(config, agent)
    model = opts[:model] || agent_config.model || default_model(config, provider, agent)

    attrs = %{
      provider: provider,
      model: model,
      agent: agent,
      title: opts[:title],
      config: config,
      debug: opts[:debug] || false
    }

    with {:ok, session} <- %Session{} |> Session.changeset(attrs) |> Repo.insert(),
         {:ok, _permission} <- apply_agent_permission(session, agent),
         {:ok, _pid} <- Synapsis.Session.DynamicSupervisor.start_session(session.id) do
      {:ok, session}
    end
  end

  def get(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> {:ok, Repo.preload(session, [:messages])}
    end
  end

  def recover_stale_transient_status(%Session{} = session, opts \\ []) do
    after_seconds = Keyword.get(opts, :after_seconds, @stale_transient_status_after_seconds)

    if stale_transient_status?(session, after_seconds) do
      session
      |> Session.changeset(stale_transient_recovery_attrs(session))
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          restart_session_worker(updated.id)
          {:ok, Repo.preload(updated, [:messages])}

        {:error, _changeset} ->
          {:ok, session}
      end
    else
      {:ok, session}
    end
  end

  def recover_unsupported_provider_model(%Session{} = session) do
    {provider, model} = recovered_provider_model(session)

    if provider == session.provider and model == session.model do
      {:ok, session}
    else
      session
      |> Session.changeset(%{provider: provider, model: model})
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          restart_session_worker(updated.id)
          {:ok, Repo.preload(updated, [:messages])}

        {:error, _changeset} ->
          {:ok, session}
      end
    end
  end

  def list(agent_name, opts \\ []) do
    list_by_agent(agent_name, opts)
  end

  def list_by_agent(agent_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    query =
      from(s in Session,
        where: s.agent == ^agent_name,
        order_by: [desc: s.updated_at],
        limit: ^limit
      )

    {:ok, Repo.all(query)}
  end

  def count_by_agent_names(agent_names) when is_list(agent_names) do
    from(s in Session,
      where: s.agent in ^agent_names,
      group_by: s.agent,
      select: {s.agent, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    agent = Keyword.get(opts, :agent)

    query =
      from(s in Session,
        order_by: [desc: s.updated_at],
        limit: ^limit
      )

    query = if agent, do: where(query, [s], s.agent == ^agent), else: query

    Repo.all(query)
  end

  def delete(session_id) do
    # Delete from DB first, then stop the session process.
    # Stopping the session first can disrupt pooled DB connections in test sandbox mode.
    result =
      case Repo.get(Session, session_id) do
        nil -> {:error, :not_found}
        session -> Repo.delete(session)
      end

    Synapsis.Session.DynamicSupervisor.stop_session(session_id)

    if Code.ensure_loaded?(SynapsisServer.DebugStore) and
         Process.whereis(SynapsisServer.DebugStore) != nil do
      SynapsisServer.DebugStore.clear_entries(session_id)
    end

    result
  end

  def update_title(session_id, title) when is_binary(title) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> session |> Ecto.Changeset.change(title: title) |> Repo.update()
    end
  end

  def update_debug(session_id, enabled) when is_boolean(enabled) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Ecto.Changeset.change(debug: enabled)
        |> Repo.update()
        |> tap(fn
          {:ok, _} ->
            unless enabled do
              if Code.ensure_loaded?(SynapsisServer.DebugStore) and
                   Process.whereis(SynapsisServer.DebugStore) != nil do
                SynapsisServer.DebugStore.clear_entries(session_id)
              end
            end

          _ ->
            :ok
        end)
    end
  end

  def send_message(session_id, %{content: content, images: images}) when is_list(images) do
    image_parts =
      images
      |> Enum.map(&Synapsis.Image.encode_file/1)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, img} ->
        %Synapsis.Part.Image{
          media_type: img.media_type,
          data: img.data,
          path: nil
        }
      end)

    ensure_session_running(session_id)
    Synapsis.Session.Worker.send_message(session_id, content, image_parts)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end

  def send_message(session_id, %{content: content}) do
    send_message(session_id, content)
  end

  def send_message(session_id, content) when is_binary(content) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.send_message(session_id, content)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end

  def cancel(session_id) do
    Synapsis.Session.Worker.cancel(session_id)
  end

  def retry(session_id) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.retry(session_id)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end

  def switch_agent(session_id, agent_name) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.switch_agent(session_id, agent_name)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end

  def switch_model(session_id, provider_name, model) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.switch_model(session_id, provider_name, model)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end

  def switch_mode(session_id, mode_name) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.switch_mode(session_id, mode_name)
  catch
    :exit, reason -> {:error, exit_reason(reason)}
  end

  def approve_tool(session_id, tool_use_id) do
    Synapsis.Session.Worker.approve_tool(session_id, tool_use_id)
  end

  def deny_tool(session_id, tool_use_id) do
    Synapsis.Session.Worker.deny_tool(session_id, tool_use_id)
  end

  def get_messages(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], asc: m.inserted_at)

    query =
      if limit do
        query |> limit(^limit)
      else
        query
      end

    Repo.all(query)
  end

  def fork(session_id, opts \\ []) do
    case Synapsis.Session.Fork.fork(session_id, opts) do
      {:ok, new_session} ->
        {:ok, _pid} = Synapsis.Session.DynamicSupervisor.start_session(new_session.id)
        {:ok, new_session}

      error ->
        error
    end
  end

  def export(session_id) do
    Synapsis.Session.Sharing.export(session_id)
  end

  def export_to_file(session_id, path) do
    Synapsis.Session.Sharing.export_to_file(session_id, path)
  end

  def compact(session_id) do
    case get(session_id) do
      {:ok, session} ->
        failure_context = Synapsis.PromptBuilder.build_failure_context(session_id)

        failure_log_tokens =
          if failure_context, do: Synapsis.ContextWindow.estimate_tokens(failure_context), else: 0

        Synapsis.Session.Compactor.maybe_compact(session_id, session.model,
          extra_tokens: failure_log_tokens
        )

      error ->
        error
    end
  end

  def ensure_running(session_id), do: ensure_session_running(session_id)

  defp ensure_session_running(session_id) do
    case Registry.lookup(Synapsis.Session.Registry, session_id) do
      [{_pid, _}] ->
        :ok

      [] ->
        case Synapsis.Session.DynamicSupervisor.start_session(session_id) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          error -> error
        end
    end
  end

  defp restart_session_worker(session_id) do
    Synapsis.Session.DynamicSupervisor.stop_session(session_id)
    ensure_session_running(session_id)
  end

  defp apply_agent_permission(%Session{} = session, agent_name) do
    agent_name
    |> Synapsis.Agent.Resolver.resolve()
    |> Map.get(:permission_mode)
    |> Synapsis.Tool.Permission.config_for_mode()
    |> then(&Synapsis.Tool.Permission.update_config(session.id, &1))
  end

  defp default_provider(config, agent) do
    agent_config = agent_config(config, agent)
    providers = config["providers"] || %{}

    cond do
      present?(agent_config["provider"]) ->
        agent_config["provider"]

      Map.has_key?(providers, "anthropic") ->
        "anthropic"

      Map.has_key?(providers, "openai") ->
        "openai"

      Map.has_key?(providers, "google") ->
        "google"

      Synapsis.Providers.env_configured?("anthropic") ->
        "anthropic"

      Synapsis.Providers.env_configured?("openai") ->
        "openai"

      Synapsis.Providers.env_configured?("google") ->
        "google"

      provider = first_enabled_provider_name() ->
        provider

      true ->
        "anthropic"
    end
  end

  defp default_model(config, provider, agent) do
    agent_config = agent_config(config, agent)

    cond do
      present?(agent_config["model"]) ->
        agent_config["model"]

      model = first_enabled_provider_model(provider) ->
        model

      model = Synapsis.Providers.env_default_model(provider) ->
        model

      true ->
        Synapsis.Providers.default_model(provider)
    end
  end

  defp agent_config(config, agent) do
    agents = config["agents"] || %{}
    agent_name = to_string(agent || "main")

    base =
      if agent_name == "main" do
        Map.get(agents, "default", %{})
      else
        %{}
      end

    exact = Map.get(agents, agent_name, %{})

    Map.merge(base, exact, fn _key, base_value, exact_value ->
      if blank?(exact_value), do: base_value, else: exact_value
    end)
  end

  defp first_enabled_provider_name do
    case Synapsis.Providers.list(enabled: true) do
      {:ok, providers} -> Enum.find_value(providers, &provider_name/1)
      _ -> nil
    end
  end

  defp provider_name(%{name: name}) when is_binary(name) do
    if present?(name), do: name
  end

  defp provider_name(_provider), do: nil

  defp first_enabled_provider_model(provider) when provider in [nil, ""], do: nil

  defp first_enabled_provider_model(provider) do
    case Synapsis.Providers.get_by_name(provider) do
      {:ok, provider_config} ->
        provider_config
        |> Synapsis.Providers.enabled_models()
        |> Enum.find(&present?/1)

      {:error, _} ->
        nil
    end
  end

  defp stale_transient_recovery_attrs(session) do
    {provider, model} = recovered_provider_model(session)

    %{
      status: "idle",
      provider: provider,
      model: model
    }
  end

  defp recovered_provider_model(session) do
    cond do
      model = env_recovery_model(session.provider, session.model) ->
        {session.provider, model}

      provider_model_supported?(session.provider, session.model) ->
        {session.provider, session.model}

      provider_configured?(session.provider) ->
        {session.provider,
         supported_model(session.config, session.provider, session.agent, session.model)}

      true ->
        provider = default_provider(session.config || %{}, session.agent)
        {provider, supported_model(session.config, provider, session.agent, session.model)}
    end
  end

  defp supported_model(config, provider, agent, fallback_model) do
    model = default_model(config || %{}, provider, agent)

    cond do
      model_supported?(provider, model) ->
        model

      model_supported?(provider, fallback_model) ->
        fallback_model

      fallback = first_enabled_provider_model(provider) ->
        fallback

      true ->
        model || fallback_model
    end
  end

  defp provider_model_supported?(provider, model) do
    provider_configured?(provider) and model_supported?(provider, model)
  end

  defp provider_configured?(provider) when provider in [nil, ""], do: false

  defp provider_configured?(provider) do
    case Synapsis.Providers.get_by_name(provider) do
      {:ok, %{enabled: true}} -> true
      _ -> Synapsis.Providers.env_configured?(provider)
    end
  end

  defp model_supported?(_provider, model) when model in [nil, ""], do: false

  defp model_supported?(provider, model) do
    case Synapsis.Providers.get_by_name(provider) do
      {:ok, %{enabled: true} = provider_config} ->
        case Synapsis.Providers.enabled_models(provider_config) do
          [] -> true
          models -> model in models
        end

      _ ->
        Synapsis.Providers.env_configured?(provider)
    end
  end

  defp env_recovery_model(provider, model) do
    env_model = Synapsis.Providers.env_default_model(provider)

    cond do
      blank?(env_model) ->
        nil

      blank?(model) ->
        env_model

      model == Synapsis.Providers.default_model(provider) ->
        env_model

      true ->
        nil
    end
  end

  defp stale_transient_status?(%Session{status: status, updated_at: updated_at}, after_seconds)
       when status in @transient_statuses do
    stale_updated_at?(updated_at, after_seconds)
  end

  defp stale_transient_status?(_session, _after_seconds), do: false

  defp stale_updated_at?(nil, _after_seconds), do: true

  defp stale_updated_at?(%DateTime{} = updated_at, after_seconds) do
    DateTime.diff(DateTime.utc_now(), updated_at, :second) >= after_seconds
  end

  defp blank?(value), do: value in [nil, ""]
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp exit_reason({:timeout, _}), do: :worker_timeout
  defp exit_reason({:noproc, _}), do: :worker_not_running
  defp exit_reason(_), do: :worker_unavailable
end
