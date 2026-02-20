defmodule Synapsis.Sessions do
  @moduledoc "Public API for session management."

  alias Synapsis.{Repo, Project, Session, Message}
  import Ecto.Query

  def create(project_path, opts \\ %{}) do
    project = ensure_project(project_path)
    config = Synapsis.Config.resolve(project_path)

    provider = opts[:provider] || default_provider(config)
    model = opts[:model] || default_model(config, provider)
    agent = opts[:agent] || "build"

    attrs = %{
      project_id: project.id,
      provider: provider,
      model: model,
      agent: agent,
      title: opts[:title],
      config: config
    }

    with {:ok, session} <- %Session{} |> Session.changeset(attrs) |> Repo.insert(),
         {:ok, _pid} <- Synapsis.Session.DynamicSupervisor.start_session(session.id) do
      {:ok, Repo.preload(session, :project)}
    end
  end

  def get(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> {:ok, Repo.preload(session, [:project, :messages])}
    end
  end

  def list(project_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    query =
      from(s in Session,
        join: p in Project,
        on: s.project_id == p.id,
        where: p.path == ^project_path,
        order_by: [desc: s.updated_at],
        limit: ^limit,
        preload: [:project]
      )

    {:ok, Repo.all(query)}
  end

  def list_by_project(project_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(s in Session,
        where: s.project_id == ^project_id,
        order_by: [desc: s.updated_at],
        limit: ^limit,
        preload: [:project]
      )

    Repo.all(query)
  end

  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    query =
      from(s in Session,
        order_by: [desc: s.updated_at],
        limit: ^limit,
        preload: [:project]
      )

    Repo.all(query)
  end

  def delete(session_id) do
    Synapsis.Session.DynamicSupervisor.stop_session(session_id)

    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> Repo.delete(session)
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
  end

  def send_message(session_id, %{content: content}) do
    send_message(session_id, content)
  end

  def send_message(session_id, content) when is_binary(content) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.send_message(session_id, content)
  end

  def cancel(session_id) do
    Synapsis.Session.Worker.cancel(session_id)
  end

  def retry(session_id) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.retry(session_id)
  end

  def switch_agent(session_id, agent_name) do
    ensure_session_running(session_id)
    Synapsis.Session.Worker.switch_agent(session_id, agent_name)
  end

  def approve_tool(session_id, tool_use_id) do
    Synapsis.Session.Worker.approve_tool(session_id, tool_use_id)
  end

  def deny_tool(session_id, tool_use_id) do
    Synapsis.Session.Worker.deny_tool(session_id, tool_use_id)
  end

  def get_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
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

  defp ensure_project(project_path) do
    slug = Project.slug_from_path(project_path)

    case Repo.get_by(Project, path: project_path) do
      nil ->
        {:ok, project} =
          %Project{}
          |> Project.changeset(%{path: project_path, slug: slug})
          |> Repo.insert()

        project

      project ->
        project
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

  defp default_provider(config) do
    providers = config["providers"] || %{}

    cond do
      Map.has_key?(providers, "anthropic") -> "anthropic"
      Map.has_key?(providers, "openai") -> "openai"
      Map.has_key?(providers, "google") -> "google"
      System.get_env("ANTHROPIC_API_KEY") -> "anthropic"
      System.get_env("OPENAI_API_KEY") -> "openai"
      System.get_env("GOOGLE_API_KEY") -> "google"
      true -> "anthropic"
    end
  end

  defp default_model(_config, "anthropic"), do: "claude-sonnet-4-20250514"
  defp default_model(_config, "openai"), do: "gpt-4o"
  defp default_model(_config, "google"), do: "gemini-2.0-flash"
  defp default_model(_config, _), do: "claude-sonnet-4-20250514"
end
