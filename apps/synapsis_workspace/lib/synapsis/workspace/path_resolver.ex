defmodule Synapsis.Workspace.PathResolver do
  @moduledoc """
  Parses workspace paths and derives scope, agent_id, session_id, and
  default visibility from path conventions.

  Path conventions:
    /shared/**                              → global scope, visibility: global_shared
    /global/**                              → global scope, visibility: global_shared
    /agents/:agent_id/**                    → agent scope, visibility: agent_shared
    /agents/:agent_id/sessions/:sid/**      → session scope, visibility: private
  """

  @type scope :: :global | :agent | :session
  @type resolved :: %{
          scope: scope(),
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          default_visibility: atom(),
          default_lifecycle: atom(),
          segments: [String.t()]
        }

  @doc """
  Resolve a path into its scope and associated IDs.

  ## Examples

      iex> PathResolver.resolve("/shared/notes/idea.md")
      {:ok, %{scope: :global, agent_id: nil, session_id: nil, ...}}

      iex> PathResolver.resolve("/agents/main/plans/auth.md")
      {:ok, %{scope: :agent, agent_id: "main", session_id: nil, ...}}

      iex> PathResolver.resolve("/global/soul.md")
      {:ok, %{scope: :global, agent_id: nil, session_id: nil, ...}}
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
           agent_id: nil,
           session_id: nil,
           default_visibility: :global_shared,
           default_lifecycle: :shared,
           segments: rest
         }}

      ["global" | rest] ->
        {:ok,
         %{
           scope: :global,
           agent_id: nil,
           session_id: nil,
           default_visibility: :global_shared,
           default_lifecycle: :shared,
           segments: rest
         }}

      ["agents", agent_id, "sessions", session_id | rest] ->
        {:ok,
         %{
           scope: :session,
           agent_id: agent_id,
           session_id: session_id,
           default_visibility: :private,
           default_lifecycle: :scratch,
           segments: rest
         }}

      ["agents", agent_id | rest] ->
        {:ok,
         %{
           scope: :agent,
           agent_id: agent_id,
           session_id: nil,
           default_visibility: :agent_shared,
           default_lifecycle: :shared,
           segments: rest
         }}

      [] ->
        {:error, "empty path"}

      _ ->
        {:error, "path must start with /shared/, /global/, or /agents/"}
    end
  end

  @doc """
  Derive the document kind from the path segments.
  """
  @spec derive_kind([String.t()]) :: atom()
  def derive_kind(segments) do
    case segments do
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
