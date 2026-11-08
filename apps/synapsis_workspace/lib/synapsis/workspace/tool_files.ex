defmodule Synapsis.Workspace.ToolFiles do
  @moduledoc """
  Authorized Workspace domain operations for native file tools.

  Paths are logical Workspace paths; native run IDs are never domain IDs. Every
  target is authorized before dispatch. File-backed operations use the bounded
  store entrypoint and publish only after content and metadata persistence.
  Existing domain projections remain readable and cannot be shadowed by writes.
  """
  alias Synapsis.Filesystem.{DirectoryList, Local, TextRead}
  alias Synapsis.Workspace
  alias Synapsis.Workspace.{Permissions, Projection}

  @read ~w(file_read list_dir grep glob)a
  @max_entries 4_096
  @max_bytes 10 * 1_024 * 1_024
  @max_output 262_144

  def authorize(identity, action, args) do
    with true <- is_map(identity) and identity[:role] in [:global, :agent, :session, :user],
         :ok <- Local.validate(action, args) do
      args = default_path(identity, action, args)
      paths = paths(action, args)

      Enum.reduce_while(paths, :ok, fn path, :ok ->
        check = if action in @read, do: :read, else: :write

        with :ok <- logical_path(path, check),
             :allowed <- Permissions.check(identity, path, check),
             :ok <- domain_path(path, check),
             {:ok, _, _} <-
               Local.resolve(Synapsis.WorkspaceDocuments.root(), String.trim_leading(path, "/")) do
          {:cont, :ok}
        else
          :denied -> {:halt, {:error, :permission_denied}}
          error -> {:halt, error}
        end
      end)
    else
      false -> {:error, :invalid_context}
      error -> error
    end
  end

  @doc "Reads ordinary files or immutable projections with source text paging."
  def read_text(identity, args, opts \\ []) do
    with :ok <- authorize_text(identity, :read, args),
         true <-
           Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:deadline, :prefix, :max_bytes, :model_budget] == [] do
      case Projection.find_projected(args["path"]) do
        {:ok, resource} ->
          TextRead.page(
            resource.content || "",
            Map.delete(args, "path"),
            Keyword.take(opts, [:prefix, :max_bytes, :model_budget])
          )

        {:error, :not_found} ->
          Workspace.text_files(:read, args, author(identity), opts)
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Reads an immutable projection first, otherwise captured source file bytes."
  def read_file(identity, args, opts \\ [], root \\ Synapsis.WorkspaceDocuments.root()) do
    with :ok <- authorize_source(identity, :read, args, root),
         true <-
           Keyword.keyword?(opts) and
             Keyword.keys(opts) --
               [
                 :node_executable,
                 :helper_path,
                 :observer_pid,
                 :deadline,
                 :prefix,
                 :max_bytes,
                 :model_budget,
                 :model_has_vision,
                 :auto_resize_images,
                 :decode_mode,
                 :windows_encoding
               ] == [] do
      case Projection.find_projected(args["path"]) do
        {:ok, resource} ->
          TextRead.page(
            resource.content || "",
            Map.drop(args, ["path", "optional"]),
            Keyword.take(opts, [:prefix, :max_bytes, :model_budget])
          )

        {:error, :not_found} ->
          Workspace.read_file(args["path"], Map.delete(args, "path"), opts, root)
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Lists direct physical and projected names together under the original Workspace scope."
  def list_directory(identity, args, opts \\ [], root \\ Synapsis.WorkspaceDocuments.root()) do
    with :ok <- authorize_source(identity, :ls, args, root),
         true <-
           Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :model_budget] == [],
         args = default_path(identity, :ls, args),
         page_args = Map.delete(args, "path"),
         page_opts = Keyword.take(opts, [:model_budget]),
         :ok <- DirectoryList.validate(page_args, page_opts) do
      Workspace.with_directory_entries(
        args["path"],
        Keyword.take(opts, [:deadline]),
        fn physical, scope ->
          with :ok <- Local.check_scope(scope.io),
               :ok <- directory_capture_status(physical),
               {:ok, projected} <- projected_index(identity, args["path"], 1),
               :ok <- Local.check_scope(scope.io),
               {:ok, entries} <- directory_entries(identity, args["path"], physical, projected),
               :ok <- Local.check_scope(scope.io),
               {:ok, result} <- DirectoryList.page(entries, page_args, page_opts),
               :ok <- Local.check_scope(scope.io) do
            {:ok, result}
          end
        end,
        root
      )
    else
      false -> {:error, :invalid_input}
      :denied -> {:error, :permission_denied}
      error -> error
    end
  end

  defp directory_capture_status({:ok, _entries}), do: :ok
  defp directory_capture_status({:error, :not_found}), do: :ok
  defp directory_capture_status(error), do: error

  defp directory_entries(identity, path, physical, projected) do
    projected = Enum.filter(projected, &(Permissions.check(identity, &1.path, :read) == :allowed))

    with {:ok, ordinary} <- directory_ordinary(path, physical, projected),
         entries =
           (projected ++ ordinary)
           |> Enum.filter(&(Permissions.check(identity, &1.path, :read) == :allowed))
           |> Enum.uniq_by(& &1.path),
         true <- length(entries) <= @max_entries do
      {:ok,
       Enum.map(entries, fn entry ->
         %{name: Path.basename(entry.path), is_directory: entry.type == "directory"}
       end)}
    else
      false -> {:error, :scan_limit}
      error -> error
    end
  end

  defp directory_ordinary(path, {:ok, physical}, projected) do
    if Enum.any?(projected, &(&1.path == path)) do
      {:error, :not_directory}
    else
      {:ok,
       Enum.map(physical, fn entry ->
         %{
           path: Path.join(path, entry.name),
           type: if(entry.is_directory, do: "directory", else: "file")
         }
       end)}
    end
  end

  defp directory_ordinary(path, {:error, :not_found} = missing, projected) do
    cond do
      Enum.any?(projected, &(&1.path == path)) -> {:error, :not_directory}
      projected != [] -> {:ok, []}
      true -> missing
    end
  end

  defp directory_ordinary(_path, error, _projected), do: error

  @doc "Writes source text through the coordinated Workspace domain."
  def write_text(identity, args, opts \\ [], root \\ Synapsis.WorkspaceDocuments.root()) do
    with :ok <- authorize_source(identity, :write, args, root) do
      Workspace.text_files(:write, args, author(identity), opts, root)
    end
  end

  @doc "Applies source edits together against the original file snapshot."
  def edit_text(identity, args, opts \\ [], root \\ Synapsis.WorkspaceDocuments.root()) do
    with :ok <- authorize_source(identity, :edit, args, root) do
      Workspace.text_files(:edit, args, author(identity), opts, root)
    end
  end

  @doc "Authorizes canonical source arguments against one explicitly captured root."
  def authorize_source(identity, :read, args, root) do
    with true <- is_map(args) and not is_struct(args),
         true <- not Map.has_key?(args, "optional") or is_boolean(args["optional"]) do
      authorize_text(identity, :read, Map.delete(args, "optional"), root)
    else
      false -> {:error, :invalid_input}
    end
  end

  def authorize_source(identity, action, args, root) when action in [:write, :edit],
    do: authorize_text(identity, action, args, root)

  def authorize_source(identity, :ls, args, root) do
    with true <- is_map(identity) and identity[:role] in [:global, :agent, :session, :user],
         true <- is_map(args) and not is_struct(args),
         args = default_path(identity, :ls, args),
         true <- is_binary(args["path"]) and String.valid?(args["path"]),
         :ok <- DirectoryList.validate(Map.delete(args, "path"), []),
         :ok <- logical_path(args["path"], :read),
         :allowed <- Permissions.check(identity, args["path"], :read),
         :ok <- domain_path(args["path"], :read),
         {:ok, _, _} <- Local.resolve(root, String.trim_leading(args["path"], "/")) do
      :ok
    else
      false -> {:error, :invalid_input}
      :denied -> {:error, :permission_denied}
      error -> error
    end
  end

  def authorize_source(_identity, _action, _args, _root), do: {:error, :invalid_input}

  defp authorize_text(identity, action, args, root \\ Synapsis.WorkspaceDocuments.root()) do
    with true <- is_map(identity) and identity[:role] in [:global, :agent, :session, :user],
         true <- text_args?(action, args),
         check = if(action == :read, do: :read, else: :write),
         :ok <- logical_path(args["path"], check),
         :allowed <- Permissions.check(identity, args["path"], check),
         :ok <- domain_path(args["path"], check),
         {:ok, _, _} <-
           Local.resolve(
             root,
             String.trim_leading(args["path"], "/")
           ) do
      :ok
    else
      false -> {:error, :invalid_input}
      :denied -> {:error, :permission_denied}
      error -> error
    end
  end

  defp text_args?(action, args) when is_map(args) and not is_struct(args) do
    is_binary(args["path"]) and
      case action do
        :read ->
          Map.keys(args) -- ["path", "offset", "cursor", "limit"] == [] and
            Enum.all?(Map.delete(args, "path"), fn
              {"offset", n} -> is_integer(n) and n >= 1 and n <= 9_007_199_254_740_991
              {"cursor", n} -> is_integer(n) and n >= 0 and n <= 9_007_199_254_740_991
              {"limit", n} -> is_number(n)
            end)

        :write ->
          Enum.sort(Map.keys(args)) == ["content", "path"] and source_text?(args["content"])

        :edit ->
          Enum.sort(Map.keys(args)) == ["edits", "path"] and is_list(args["edits"]) and
            length(args["edits"]) in 1..200 and
            Enum.all?(args["edits"], fn edit ->
              is_map(edit) and not is_struct(edit) and
                Enum.sort(Map.keys(edit)) == ["newText", "oldText"] and
                source_text?(edit["oldText"]) and source_text?(edit["newText"])
            end)
      end
  end

  defp text_args?(_, _), do: false

  defp source_text?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= @max_bytes

  def perform(identity, action, args) do
    with :ok <- authorize(identity, action, args) do
      args = default_path(identity, action, args)

      case action do
        :file_read ->
          case Projection.find_projected(args["path"]) do
            {:ok, resource} -> Local.page_content(resource.content || "", resource.path, args)
            {:error, :not_found} -> Workspace.tool_files(action, args, author(identity))
          end

        action when action in [:list_dir, :glob, :grep] ->
          Local.enumerate(fn -> enumerate(identity, action, args) end)

        _ ->
          Workspace.tool_files(action, args, author(identity))
      end
    end
  end

  defp enumerate(identity, action, args) do
    depth = if action == :list_dir, do: Map.get(args, "depth", 1), else: 10

    with {:ok, ordinary} <- ordinary_index(args["path"], depth),
         {:ok, projected} <- projected_index(identity, args["path"], depth),
         entries =
           (projected ++ ordinary)
           |> Enum.filter(&(Permissions.check(identity, &1.path, :read) == :allowed))
           |> Enum.uniq_by(& &1.path)
           |> Enum.sort_by(& &1.path),
         true <- length(entries) <= @max_entries do
      if action != :grep and Enum.any?(entries, &(&1.path == args["path"])) do
        {:error, :not_directory}
      else
        enumerate_result(entries, action, args)
      end
    else
      false -> {:error, :scan_limit}
      error -> error
    end
  end

  defp ordinary_index(path, depth) do
    case Workspace.tool_file_index(path, depth) do
      {:error, :not_found} -> {:ok, []}
      result -> result
    end
  end

  defp projected_index(identity, prefix, depth) do
    resources =
      prefix
      |> projection_prefixes()
      |> Enum.flat_map(&Projection.list_projected(&1, limit: @max_entries + 1))

    if length(resources) <= @max_entries do
      entries =
        resources
        |> Enum.filter(fn resource ->
          within_prefix?(resource.path, prefix) and
            Permissions.check(identity, resource.path, :read) == :allowed
        end)
        |> Enum.flat_map(&projection_entries(&1, prefix, depth))

      {:ok, entries}
    else
      {:error, :scan_limit}
    end
  end

  defp projection_prefixes("/shared"), do: ["/shared/skills", "/shared/memory"]

  defp projection_prefixes(prefix) do
    case String.split(prefix, "/", trim: true) do
      ["agents", agent] -> ["/agents/#{agent}/memory", "/agents/#{agent}/sessions"]
      _ -> [prefix]
    end
  end

  defp within_prefix?(path, prefix),
    do: path == prefix or String.starts_with?(path, prefix <> "/")

  defp projection_entries(resource, prefix, depth) do
    if resource.path == prefix do
      [%{path: resource.path, type: "file", content: resource.content || ""}]
    else
      segments = resource.path |> Path.relative_to(prefix) |> Path.split()

      segments
      |> Enum.take(depth)
      |> Enum.with_index(1)
      |> Enum.map(fn {_segment, count} ->
        path = Path.join([prefix | Enum.take(segments, count)])

        if count == length(segments),
          do: %{path: path, type: "file", content: resource.content || ""},
          else: %{path: path, type: "directory"}
      end)
    end
  end

  defp enumerate_result(entries, :list_dir, args),
    do: page(Enum.map(entries, &Map.take(&1, [:path, :type])), args, :entries)

  defp enumerate_result(entries, :glob, args) do
    paths = Enum.map(entries, &Path.relative_to(&1.path, args["path"]))

    with {:ok, matches} <- Local.glob_paths(paths, args["pattern"]) do
      page(Enum.map(matches, &Path.join(args["path"], &1)), args, :paths)
    end
  end

  defp enumerate_result(entries, :grep, args) do
    with {:ok, []} <- Local.search_content("", args["path"], args["pattern"]),
         {:ok, files} <- search_files(entries, args) do
      Enum.reduce_while(files, {:ok, [], 0}, fn file, {:ok, matches, bytes} ->
        with {:ok, result} <- search_file(file, args["pattern"]),
             true <- bytes + result.bytes <= @max_bytes,
             true <- length(matches) + length(result.matches) <= @max_entries do
          {:cont, {:ok, matches ++ result.matches, bytes + result.bytes}}
        else
          false -> {:halt, {:error, :scan_limit}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, matches, _} -> page(matches, args, :matches)
        error -> error
      end
    end
  end

  defp search_files(entries, args) do
    files = Enum.filter(entries, &(&1.type == "file"))

    if include = args["include"] do
      paths = Enum.map(files, & &1.path)

      with {:ok, matches} <- Local.glob_paths(paths, include),
           {:ok, basenames} <- Local.glob_paths(Enum.map(paths, &Path.basename/1), include) do
        {:ok, Enum.filter(files, &(&1.path in matches or Path.basename(&1.path) in basenames))}
      end
    else
      {:ok, files}
    end
  end

  defp search_file(%{content: content, path: path}, pattern) do
    with {:ok, matches} <- Local.search_content(content, path, pattern),
         do: {:ok, %{matches: matches, bytes: byte_size(content)}}
  end

  defp search_file(%{path: path}, pattern), do: Workspace.tool_file_search(path, pattern)

  defp page(values, args, key) do
    offset = Map.get(args, "offset", 0)
    selected = Enum.slice(values, offset, Map.get(args, "limit", 200))
    truncated = offset + length(selected) < length(values)

    result = %{
      key => selected,
      :truncated => truncated,
      :next_offset => if(truncated, do: offset + length(selected))
    }

    if byte_size(Jason.encode!(result)) <= @max_output,
      do: {:ok, result},
      else: {:error, :output_limit}
  end

  defp author(identity),
    do: identity[:agent_id] || if(identity.role == :user, do: "user", else: "system")

  defp paths(:file_move, args), do: [args["source"], args["destination"]]
  defp paths(:multi_edit, args), do: Enum.map(args["edits"], & &1["path"])
  defp paths(_, args), do: [args["path"]]

  defp default_path(identity, :ls, %{"path" => ""} = args),
    do: default_path(identity, :ls, Map.delete(args, "path"))

  defp default_path(identity, action, args) when action in [:grep, :glob, :ls] do
    path =
      case identity do
        %{role: :session, agent_id: agent, session_id: session}
        when is_binary(agent) and is_binary(session) ->
          "/agents/#{agent}/sessions/#{session}"

        %{role: :agent, agent_id: agent} when is_binary(agent) ->
          "/agents/#{agent}"

        _ ->
          "/shared"
      end

    Map.put_new(args, "path", path)
  end

  defp default_path(_, _, args), do: args

  defp logical_path(path, action) when is_binary(path) do
    segments = String.split(path, "/")

    cond do
      not String.starts_with?(path, "/") or String.contains?(path, ["\\", "\0"]) or
          Enum.any?(tl(segments), &(&1 in ["", ".", ".."])) ->
        {:error, :unsafe_path}

      action == :write ->
        case Workspace.validate_path(path) do
          :ok -> :ok
          _ -> {:error, :unsafe_path}
        end

      true ->
        :ok
    end
  end

  defp logical_path(_, _), do: {:error, :invalid_input}

  defp domain_path(_path, :read), do: :ok

  defp domain_path(path, :write) do
    if Regex.match?(
         ~r{^/(?:shared|agents/[^/]+)/(?:skills|memory)/|^/agents/[^/]+/sessions/[^/]+/todo\.md$},
         path
       ),
       do: {:error, :domain_path},
       else: :ok
  end
end
