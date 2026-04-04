defmodule Synapsis.Workspace.PathResolver do
  @moduledoc """
  Parses workspace paths and derives scope, project_id, session_id, and
  default visibility from path conventions.

  Path conventions:
    /shared/**                          → global scope, visibility: global_shared
    /projects/:project_id/**            → project scope, visibility: project_shared
    /projects/:project_id/sessions/:sid/** → session scope, visibility: private
  """

  @type scope :: :global | :project | :session
  @type resolved :: %{
          scope: scope(),
          project_id: String.t() | nil,
          session_id: String.t() | nil,
          default_visibility: atom(),
          default_lifecycle: atom(),
          segments: [String.t()]
        }

  @doc """
  Resolve a path into its scope and associated IDs.

  ## Examples

      iex> PathResolver.resolve("/shared/notes/idea.md")
      {:ok, %{scope: :global, project_id: nil, session_id: nil, ...}}

      iex> PathResolver.resolve("/projects/abc/plans/auth.md")
      {:ok, %{scope: :project, project_id: "abc", session_id: nil, ...}}

      iex> PathResolver.resolve("/global/soul.md")
      {:ok, %{scope: :global, project_id: nil, session_id: nil, ...}}
  """
  @spec resolve(String.t()) :: {:ok, resolved()} | {:error, String.t()}
  def resolve(path) when is_binary(path) do
    path = normalize_path(path)
    segments = path |> String.trim_leading("/") |> String.split("/", trim: true)

    case segments do
      ["shared" | rest] ->
        {:ok,
         %{
           scope: :global,
           project_id: nil,
           session_id: nil,
           default_visibility: :global_shared,
           default_lifecycle: :shared,
           segments: rest
         }}

      ["global" | rest] ->
        {:ok,
         %{
           scope: :global,
           project_id: nil,
           session_id: nil,
           default_visibility: :global_shared,
           default_lifecycle: :shared,
           segments: rest
         }}

      ["projects", project_id, "sessions", session_id | rest] ->
        # WS-8.3: all session paths default to :scratch
        lifecycle = :scratch

        {:ok,
         %{
           scope: :session,
           project_id: project_id,
           session_id: session_id,
           default_visibility: :private,
           default_lifecycle: lifecycle,
           segments: rest
         }}

      ["projects", project_id | rest] ->
        {:ok,
         %{
           scope: :project,
           project_id: project_id,
           session_id: nil,
           default_visibility: :project_shared,
           default_lifecycle: :shared,
           segments: rest
         }}

      [] ->
        {:error, "empty path"}

      _ ->
        {:error, "path must start with /shared/, /global/, or /projects/"}
    end
  end

  @doc """
  Derive the document kind from the path segments.
  """
  @spec derive_kind([String.t()]) :: atom()
  def derive_kind(segments) do
    case segments do
      ["board.yaml"] -> :board
      ["plans" | _] -> :plan
      ["design" | _] -> :design_doc
      ["logs", "devlog.md"] -> :devlog
      ["repos", _repo_id, "config.yaml"] -> :repo_config
      ["attachments" | _] -> :attachment
      ["handoffs" | _] -> :handoff
      ["scratch" | _] -> :session_scratch
      _ -> :document
    end
  end

  @doc """
  Normalize a path: ensure leading /, collapse double slashes, remove trailing slash.
  """
  @spec normalize_path(String.t()) :: String.t()
  def normalize_path(path) do
    path
    |> String.replace(~r|/+|, "/")
    |> String.trim_trailing("/")
    |> then(fn
      "" -> "/"
      "/" <> _ = p -> p
      p -> "/" <> p
    end)
  end

  @doc """
  Get the parent directory of a path.
  """
  @spec parent(String.t()) :: String.t()
  def parent(path) do
    path
    |> normalize_path()
    |> String.split("/")
    |> Enum.drop(-1)
    |> Enum.join("/")
    |> then(fn
      "" -> "/"
      p -> p
    end)
  end
end
