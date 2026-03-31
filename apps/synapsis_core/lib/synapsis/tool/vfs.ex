defmodule Synapsis.Tool.VFS do
  @moduledoc """
  Virtual filesystem router for `@synapsis/` prefix.

  When a path starts with `@synapsis/`, the VFS router strips the prefix and
  delegates to workspace operations instead of the real filesystem.

  Uses `Synapsis.WorkspaceDocuments` (synapsis_data) for direct DB operations,
  and optionally `Synapsis.Workspace` (synapsis_workspace) when available for
  higher-level operations like write validation and domain path rejection.

  ## Path Mapping

      @synapsis/projects/myapp/plans/auth.md → /projects/myapp/plans/auth.md
      @synapsis/shared/notes/ideas.md        → /shared/notes/ideas.md

  ## Cross-Boundary Rules

  - Moving between real filesystem and `@synapsis/` is rejected
  - Search results from workspace are `@synapsis/`-prefixed for LLM chaining
  """

  @prefix "@synapsis/"

  @doc "Returns true if the path is a virtual workspace path."
  @spec virtual?(String.t()) :: boolean()
  def virtual?(path) when is_binary(path), do: String.starts_with?(path, @prefix)
  def virtual?(_), do: false

  @doc "Strips the `@synapsis/` prefix and returns the workspace path."
  @spec strip_prefix(String.t()) :: String.t()
  def strip_prefix(@prefix <> rest), do: "/" <> rest
  def strip_prefix(path), do: path

  @doc "Adds the `@synapsis/` prefix to a workspace path for LLM output."
  @spec add_prefix(String.t()) :: String.t()
  def add_prefix("/" <> rest), do: @prefix <> rest
  def add_prefix(path), do: @prefix <> path

  @doc "Read a virtual file via workspace."
  @spec read(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def read(path, opts \\ []) do
    ws_path = strip_prefix(path)

    case workspace_call(:read, [ws_path]) do
      {:ok, resource} ->
        content = extract_content(resource)
        content = apply_offset_limit(content, opts[:offset], opts[:limit])
        {:ok, content}

      {:error, :not_found} ->
        {:error, "Workspace document not found"}

      nil ->
        # Fallback to direct DB query
        case Synapsis.WorkspaceDocuments.get_by_path(ws_path) do
          nil -> {:error, "Workspace document not found"}
          doc -> {:ok, apply_offset_limit(doc.content_body || "", opts[:offset], opts[:limit])}
        end
    end
  end

  @doc "Write content to a virtual file via workspace."
  @spec write(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def write(path, content, opts \\ %{}) do
    ws_path = strip_prefix(path)

    case workspace_call(:write, [ws_path, content, opts]) do
      {:ok, _resource} ->
        {:ok, "Written to #{path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _reason} ->
        {:error, "Failed to write workspace document"}

      nil ->
        {:error, "Workspace module not available — cannot write virtual files"}
    end
  end

  @doc "Delete a virtual file via workspace."
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(path) do
    ws_path = strip_prefix(path)

    case workspace_call(:delete, [ws_path]) do
      :ok -> :ok
      {:error, :not_found} -> {:error, "Workspace document not found"}
      {:error, _reason} -> {:error, "Failed to delete workspace document"}
      nil -> {:error, "Workspace module not available — cannot delete virtual files"}
    end
  end

  @doc "Move/rename a virtual file. Cross-boundary moves are rejected."
  @spec move(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def move(source, destination) do
    cond do
      virtual?(source) and not virtual?(destination) ->
        {:error, "Cannot move from workspace to real filesystem"}

      not virtual?(source) and virtual?(destination) ->
        {:error, "Cannot move from real filesystem to workspace"}

      virtual?(source) and virtual?(destination) ->
        ws_from = strip_prefix(source)
        ws_to = strip_prefix(destination)

        case workspace_call(:move, [ws_from, ws_to]) do
          {:ok, _resource} -> {:ok, "Moved #{source} to #{destination}"}
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, _reason} -> {:error, "Failed to move workspace document"}
          nil -> {:error, "Workspace module not available"}
        end

      true ->
        {:error, "Invalid move operation"}
    end
  end

  @doc "List a virtual directory via workspace."
  @spec list_dir(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def list_dir(path, opts \\ []) do
    ws_path = strip_prefix(path)
    depth = opts[:depth] || 1

    case workspace_call(:list, [ws_path, [depth: depth]]) do
      {:ok, resources} ->
        entries =
          resources
          |> Enum.map(fn r ->
            display_path = add_prefix(extract_path(r))
            kind = extract_kind(r)
            "#{display_path} [#{kind}]"
          end)
          |> Enum.join("\n")

        {:ok, entries}

      nil ->
        # Fallback: direct DB listing
        prefix = if String.ends_with?(ws_path, "/"), do: ws_path, else: ws_path <> "/"
        docs = Synapsis.WorkspaceDocuments.list_by_prefix(prefix, depth: depth)

        entries =
          docs
          |> Enum.map(fn doc ->
            display_path = add_prefix(doc.path)
            "#{display_path} [#{doc.kind}]"
          end)
          |> Enum.join("\n")

        {:ok, entries}
    end
  end

  @doc """
  Grep workspace documents using PostgreSQL regex.
  Returns results with `@synapsis/` prefixed paths.
  """
  @spec grep(String.t(), String.t() | nil) :: {:ok, String.t()}
  def grep(pattern, path) do
    ws_path = if path, do: strip_prefix(path), else: nil

    query_opts =
      if ws_path do
        [path_prefix: ws_path]
      else
        []
      end

    results = Synapsis.WorkspaceDocuments.grep(pattern, query_opts)

    output =
      results
      |> Enum.map(fn %{path: p, line: line, content: content} ->
        "#{add_prefix(p)}:#{line}:#{content}"
      end)
      |> Enum.join("\n")

    if output == "" do
      {:ok, "No matches found."}
    else
      {:ok, output}
    end
  end

  @doc """
  Glob workspace documents using SQL LIKE pattern matching.
  Returns results with `@synapsis/` prefixed paths.
  """
  @spec glob(String.t(), String.t() | nil) :: {:ok, String.t()}
  def glob(pattern, path) do
    ws_path = if path, do: strip_prefix(path), else: nil

    query_opts =
      if ws_path do
        [path_prefix: ws_path]
      else
        []
      end

    results = Synapsis.WorkspaceDocuments.glob(pattern, query_opts)

    output =
      results
      |> Enum.map(fn %{path: p} -> add_prefix(p) end)
      |> Enum.join("\n")

    if output == "" do
      {:ok, "No matches found."}
    else
      {:ok, output}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Optionally call Synapsis.Workspace if available (avoids circular dep)
  defp workspace_call(fun, args) do
    mod = Synapsis.Workspace

    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      nil
    end
  end

  defp extract_content(%{content: c}) when is_binary(c), do: c
  defp extract_content(%{content_body: c}) when is_binary(c), do: c
  defp extract_content(_), do: ""

  defp extract_path(%{path: p}), do: p
  defp extract_kind(%{kind: k}) when is_atom(k), do: Atom.to_string(k)
  defp extract_kind(%{kind: k}) when is_binary(k), do: k
  defp extract_kind(_), do: "document"

  defp apply_offset_limit(content, nil, nil), do: content

  defp apply_offset_limit(content, offset, limit) do
    lines = String.split(content, "\n")
    lines = if offset && offset > 0, do: Enum.drop(lines, offset), else: lines
    lines = if limit && limit > 0, do: Enum.take(lines, limit), else: lines
    Enum.join(lines, "\n")
  end
end
