defmodule Synapsis.Tool.RepoLink do
  @moduledoc "Link a git repository to the project by cloning it bare and registering in DB."
  use Synapsis.Tool

  @impl true
  def name, do: "repo_link"

  @impl true
  def description,
    do:
      "Clone a git repository bare and link it to the current project. " <>
        "Registers the repo in the database with its remotes."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def side_effects, do: [:repo_linked]

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "Lowercase alphanumeric name for the repo (e.g. my-service)"
        },
        "urls" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "List of remote URLs (at least one required)"
        },
        "primary_url" => %{
          "type" => "string",
          "description" =>
            "Primary URL for initial clone (defaults to first URL if not specified)"
        },
        "default_branch" => %{
          "type" => "string",
          "description" => "Default branch name (defaults to main)"
        }
      },
      "required" => ["name", "urls"]
    }
  end

  @impl true
  def execute(input, context) do
    project_id = Map.get(context, :project_id)

    case project_id do
      nil ->
        {:error, "project_id is required in context"}

      project_id ->
        name = Map.get(input, "name")
        urls = Map.get(input, "urls", [])
        primary_url = Map.get(input, "primary_url") || List.first(urls)
        default_branch = Map.get(input, "default_branch", "main")

        repo_id = Ecto.UUID.generate()
        bare_path = Path.expand("~/.synapsis/repos/#{repo_id}/bare.git")

        with :ok <- Synapsis.Git.RepoOps.clone_bare(primary_url, bare_path),
             {:ok, repo} <-
               Synapsis.Repos.create(project_id, %{
                 name: name,
                 bare_path: bare_path,
                 default_branch: default_branch
               }),
             :ok <- add_additional_remotes(repo, urls, primary_url) do
          {:ok, Jason.encode!(%{repo_id: repo.id, name: name, bare_path: bare_path})}
        end
    end
  end

  defp add_additional_remotes(repo, urls, primary_url) do
    other_urls = Enum.reject(urls, &(&1 == primary_url))

    Enum.reduce_while(other_urls, :ok, fn url, :ok ->
      remote_name = "remote-#{:erlang.phash2(url)}"

      case Synapsis.Repos.add_remote(repo.id, %{name: remote_name, url: url}) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
