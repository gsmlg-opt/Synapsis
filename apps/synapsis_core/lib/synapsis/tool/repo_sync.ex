defmodule Synapsis.Tool.RepoSync do
  @moduledoc "Fetch all remotes for a linked repository."
  use Synapsis.Tool

  @impl true
  def name, do: "repo_sync"

  @impl true
  def description,
    do: "Fetch all remotes for a linked repository, updating local tracking references."

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :workflow

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "repo_id" => %{
          "type" => "string",
          "description" => "The repository ID to sync"
        }
      },
      "required" => ["repo_id"]
    }
  end

  @impl true
  def execute(input, _context) do
    repo_id = Map.get(input, "repo_id")

    case Synapsis.Repos.get(repo_id) do
      nil ->
        {:error, "Repository #{repo_id} not found"}

      repo ->
        case Synapsis.Git.RepoOps.fetch_all(repo.bare_path) do
          :ok ->
            {:ok, Jason.encode!(%{repo_id: repo.id, status: "synced"})}

          {:error, reason} ->
            {:error, "Fetch failed: #{reason}"}
        end
    end
  end
end
