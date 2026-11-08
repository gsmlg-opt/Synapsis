defmodule Synapsis.Workspace.FileDocuments do
  @moduledoc """
  File-backed workspace document store.

  Documents are stored as files on disk under the workspace root. The document's
  `:path` field is the relative path from the workspace root. Metadata (kind,
  visibility, lifecycle, etc.) is stored in a JSON sidecar at
  `<workspace_root>/.synapsis/meta/<encoded_path>.json`.

  This is the file-system replacement for the DB-backed `WorkspaceDocuments`
  context. The existing Ecto context still works until the C4 cutover.
  """

  alias Synapsis.Filesystem.Local

  @meta_dir ".synapsis/meta"
  @default_format "markdown"

  @tool_meta_fields ~w(id path kind visibility lifecycle content_format metadata created_by updated_by agent_id session_id version inserted_at updated_at)a

  @doc "Prepares actual file bytes without acquiring or inspecting metadata sidecars."
  def read_file(root, logical_path, args, opts \\ []) when is_binary(logical_path) do
    Local.read_file(root, String.trim_leading(logical_path, "/"), args, opts)
  end

  @doc "Runs a store callback under all content and legacy sidecar keys."
  def with_paths(root, paths, io_opts, callback) do
    physical_paths =
      paths
      |> Enum.flat_map(fn path ->
        [String.trim_leading(path, "/"), Path.relative_to(meta_path(root, path), root)]
      end)
      |> Enum.uniq()

    Local.with_paths(root, physical_paths, io_opts, callback)
  end

  @doc "Captures direct names and keeps the original directory scope through the callback."
  def with_directory_entries(root, logical_path, io_opts, callback)
      when is_binary(logical_path) and is_function(callback, 2) do
    physical_path = String.trim_leading(logical_path, "/")

    Local.with_paths(root, [physical_path], io_opts, fn io ->
      entries = Local.directory_entries(root, physical_path, io)

      with :ok <- Local.check_scope(io) do
        callback.(entries, io)
      end
    end)
  end

  def with_directory_entries(_root, _logical_path, _io_opts, _callback),
    do: {:error, :invalid_input}

  @doc """
  Persists only the generated handoff document and its metadata, without
  publication. The Workspace handoff domain owns authorization and the overall
  deadline. No caller-supplied path or document content is accepted here.
  """
  def put_handoff(root, %Synapsis.AgentMessage{type: "handoff"} = message, opts) do
    agent = message.from_agent_id

    with true <-
           is_binary(agent) and byte_size(agent) in 1..256 and
             Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, agent),
         {:ok, ref} <- Ecto.UUID.cast(message.ref),
         true <- ref == message.ref,
         true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :lease] == [],
         true <-
           is_integer(opts[:deadline]) and opts[:deadline] > System.monotonic_time(:millisecond),
         path = "/agents/#{agent}/handoffs/#{ref}.json",
         content =
           Jason.encode!(%{
             ref: ref,
             from: agent,
             to: message.to_agent_id,
             payload: message.payload,
             created_at: message.inserted_at
           }),
         true <- byte_size(content) <= 65_536 do
      with_paths(root, [path], opts, fn io ->
        with {:ok, metadata} <- tool_read_meta(root, path, io),
             true <- metadata == %{},
             :ok <- new_handoff_path(root, path, io) do
          case Local.perform(
                 root,
                 :file_write,
                 %{"path" => String.trim_leading(path, "/"), "content" => content},
                 io
               ) do
            {:ok, _} ->
              case tool_save_meta(root, path, metadata, agent, io) do
                {:ok, change} ->
                  {:ok, %{change | action: :created}}

                {:error, _} ->
                  {:error,
                   {:unknown_outcome,
                    %{
                      artifact_content_status: "persisted",
                      artifact_metadata_status: "unconfirmed"
                    }}}
              end

            error ->
              error
          end
        else
          false -> {:error, :invalid_input}
          error -> error
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def put_handoff(_root, _message, _opts), do: {:error, :invalid_input}

  defp new_handoff_path(root, path, io) do
    case Local.read_binary(root, String.trim_leading(path, "/"), io) do
      {:error, :not_found} -> :ok
      {:ok, _, _} -> {:error, :conflict}
      error -> error
    end
  end

  @doc "Indexes bounded ordinary files before the domain merges projections and pages."
  def tool_index(root, path, depth, io_opts \\ []) do
    with {:ok, entries} <-
           Local.index(root, String.trim_leading(path, "/"), depth, io_opts) do
      {:ok, Enum.map(entries, &logical_result/1)}
    end
  end

  @doc "Searches full bounded content while keeping physical access in the store."
  def tool_search(root, path, pattern, io_opts \\ []) do
    with {:ok, result} <-
           Local.search_file(root, String.trim_leading(path, "/"), pattern, io_opts) do
      {:ok, logical_result(result)}
    end
  end

  @doc """
  Bounded file-tool store entrypoint. Content uses the real-filesystem domain;
  metadata remains owned here. The caller owns logical authorization and domain
  projection rules. Changes are returned only after both persistence steps.
  Metadata failure retains confirmed changes alongside explicit uncertain evidence.
  """
  def tool_perform(root, action, arguments, author, io_opts \\ []) do
    with :ok <- Local.validate(action, storage_arguments(arguments)) do
      with_paths(root, operation_paths(action, arguments), io_opts, fn io ->
        with {:ok, metadata} <- tool_metadata(root, action, arguments, io) do
          case Local.perform(root, action, storage_arguments(arguments), io) do
            {:ok, result} ->
              result = logical_result(result)

              case finish_tool(root, action, result, metadata, author, io) do
                {:ok, changes} ->
                  {:ok, %{result: result, changes: changes}}

                {:error, paths, changes} ->
                  {:error, {:unknown_outcome, unconfirmed_metadata(result, paths)}, changes}
              end

            {:error, {:unknown_outcome, evidence}} ->
              evidence = logical_result(evidence)

              if action == :multi_edit do
                case finish_tool(root, action, evidence, metadata, author, io) do
                  {:ok, changes} ->
                    {:error, {:unknown_outcome, evidence}, changes}

                  {:error, paths, changes} ->
                    {:error, {:unknown_outcome, unconfirmed_metadata(evidence, paths)}, changes}
                end
              else
                {:error, {:unknown_outcome, evidence}}
              end

            error ->
              error
          end
        end
      end)
    end
  end

  @doc "Executes source text operations and confirms metadata within the same lease."
  def text_perform(root, action, arguments, author, opts \\ [])
      when action in [:read, :write, :edit] do
    path = arguments["path"]
    io_opts = Keyword.take(opts, [:lease, :deadline])

    result =
      with_paths(root, [path], io_opts, fn io ->
        effective_opts = Keyword.merge(opts, io)

        with {:ok, metadata} <- source_metadata(root, action, path, io),
             {:ok, result} <- source_operation(root, action, arguments, effective_opts) do
          finish_source(root, action, path, result, metadata, author, io)
        end
      end)

    source_outcome(root, path, result)
  end

  @doc "Projects recognized physical interruption evidence without performing effects."
  def source_outcome(root, path, {:error, {:unknown_outcome, evidence}}) when is_map(evidence) do
    evidence = project_source_files(root, path, evidence)

    evidence =
      case evidence do
        %{operation: {:unknown_outcome, operation}} when is_map(operation) ->
          Map.put(
            evidence,
            :operation,
            {:unknown_outcome, project_source_files(root, path, operation)}
          )

        _ ->
          evidence
      end

    {:error, {:unknown_outcome, evidence}}
  end

  def source_outcome(_root, _path, result), do: result

  defp project_source_files(
         _root,
         path,
         %{files: [%{path: file_path, metadata_status: status}]} = evidence
       )
       when file_path == path and status in ["persisted", "unconfirmed"],
       do: evidence

  defp project_source_files(root, path, %{files: files} = evidence) when is_list(files) do
    pinned_root = Path.expand(root)

    content_key =
      path
      |> String.trim_leading("/")
      |> Path.expand(pinned_root)
      |> Path.relative_to(pinned_root)

    metadata_key =
      root
      |> meta_path(path)
      |> Path.expand()
      |> Path.relative_to(pinned_root)

    content = Enum.find(files, &match?(%{path: ^content_key}, &1))
    metadata = Enum.find(files, &match?(%{path: ^metadata_key}, &1))

    if is_nil(content) and is_nil(metadata) do
      evidence
    else
      logical_file =
        case content do
          %{status: status}
          when status in ["created", "updated", "unchanged", "deleted", "moved"] ->
            content |> Map.take([:status, :bytes]) |> Map.put(:path, path)

          _ ->
            %{path: path, status: "unknown_outcome"}
        end

      metadata_status =
        case metadata do
          %{status: status} when status in ["created", "updated", "unchanged", "deleted"] ->
            "persisted"

          _ ->
            "unconfirmed"
        end

      Map.put(evidence, :files, [Map.put(logical_file, :metadata_status, metadata_status)])
    end
  end

  defp project_source_files(_root, _path, evidence), do: evidence

  defp source_metadata(_root, :read, _path, _io), do: {:ok, %{}}
  defp source_metadata(root, _action, path, io), do: tool_read_meta(root, path, io)

  defp source_operation(root, :read, args, opts),
    do:
      Local.read_text(
        root,
        String.trim_leading(args["path"], "/"),
        Map.delete(args, "path"),
        opts
      )

  defp source_operation(root, :write, args, opts),
    do:
      Local.write_text(
        root,
        String.trim_leading(args["path"], "/"),
        args["content"],
        Keyword.put_new(opts, :display_path, args["path"])
      )

  defp source_operation(root, :edit, args, opts),
    do:
      Local.edit_text(
        root,
        String.trim_leading(args["path"], "/"),
        args["edits"],
        Keyword.put_new(opts, :display_path, args["path"])
      )

  defp finish_source(_root, :read, _path, result, _metadata, _author, _io),
    do: {:ok, %{result: result, changes: []}}

  defp finish_source(
         _root,
         _action,
         _path,
         %{details: %{changed: false}} = result,
         _metadata,
         _author,
         _io
       ),
       do: {:ok, %{result: result, changes: []}}

  defp finish_source(root, action, path, result, metadata, author, io) do
    case tool_save_meta(root, path, metadata, author, io) do
      {:ok, change} ->
        created = action == :write and result.details.created
        change = %{change | action: if(created, do: :created, else: :updated)}
        {:ok, %{result: result, changes: [change]}}

      {:error, _} ->
        {:error, {:unknown_outcome, unconfirmed_metadata(result, [path])}, []}
    end
  end

  defp operation_paths(:file_move, args), do: [args["source"], args["destination"]]
  defp operation_paths(:multi_edit, args), do: Enum.map(args["edits"], & &1["path"])
  defp operation_paths(_action, args), do: [Map.get(args, "path", ".")]

  defp unconfirmed_metadata(result, paths) do
    result = Map.put_new(result, :reason, "metadata_persistence")

    case result do
      %{files: files} ->
        Map.put(
          result,
          :files,
          Enum.map(files, fn file ->
            if file.path in paths,
              do: Map.put(file, :metadata_status, "unconfirmed"),
              else: file
          end)
        )

      %{source: source, destination: destination} ->
        Map.put(result, :metadata_status, %{
          source: if(source in paths, do: "unconfirmed", else: "persisted"),
          destination: if(destination in paths, do: "unconfirmed", else: "persisted")
        })

      _ ->
        Map.put(result, :metadata_status, "unconfirmed")
    end
  end

  defp tool_metadata(_root, action, _args, _io)
       when action in [:file_read, :list_dir, :grep, :glob],
       do: {:ok, %{}}

  defp tool_metadata(root, action, args, io) do
    paths = operation_paths(action, args)

    paths
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, metadata} ->
      case tool_read_meta(root, path, io) do
        {:ok, meta} -> {:cont, {:ok, Map.put(metadata, logical_path(path), {path, meta})}}
        error -> {:halt, error}
      end
    end)
  end

  defp tool_read_meta(root, path, opts) do
    alias Synapsis.Filesystem.Local
    relative = Path.relative_to(meta_path(root, path), root)

    case Local.perform(root, :file_read, %{"path" => relative}, opts) do
      {:error, :not_found} ->
        {:ok, %{}}

      {:ok, %{content: content, truncated: false}} ->
        case Jason.decode(content) do
          {:ok, map} when is_map(map) ->
            known = Map.new(@tool_meta_fields, &{Atom.to_string(&1), &1})

            metadata =
              Map.new(
                for {key, value} <- map,
                    Map.has_key?(known, key),
                    do: {Map.fetch!(known, key), value}
              )

            if is_integer(Map.get(metadata, :version, 0)) and
                 is_map(Map.get(metadata, :metadata, %{})),
               do: {:ok, metadata},
               else: {:error, :invalid_metadata}

          _ ->
            {:error, :invalid_metadata}
        end

      {:ok, _} ->
        {:error, :file_limit}

      error ->
        error
    end
  end

  defp finish_tool(_root, action, _result, _metadata, _author, _io)
       when action in [:file_read, :list_dir, :grep, :glob],
       do: {:ok, []}

  defp finish_tool(_root, _action, %{status: "unchanged"}, _metadata, _author, _io), do: {:ok, []}

  defp finish_tool(root, :multi_edit, %{files: files}, metadata, author, io) do
    {changes, unconfirmed} =
      Enum.reduce(files, {[], []}, fn file, {changes, unconfirmed} ->
        if file.status == "updated" do
          {path, previous} = Map.fetch!(metadata, logical_path(file.path))

          case tool_save_meta(root, path, previous, author, io) do
            {:ok, change} -> {changes ++ [%{change | path: file.path}], unconfirmed}
            {:error, _} -> {changes, unconfirmed ++ [file.path]}
          end
        else
          {changes, unconfirmed}
        end
      end)

    if unconfirmed == [], do: {:ok, changes}, else: {:error, unconfirmed, changes}
  end

  defp finish_tool(root, :file_delete, result, metadata, _author, io) do
    {path, previous} = Map.fetch!(metadata, logical_path(result.path))

    case tool_delete_meta(root, path, io) do
      :ok ->
        {:ok, [tool_change(result.path, :deleted, previous)]}

      {:error, _} ->
        {:error, [result.path], []}
    end
  end

  defp finish_tool(root, :file_move, result, metadata, author, io) do
    {source, previous} = Map.fetch!(metadata, logical_path(result.source))
    {destination, _} = Map.fetch!(metadata, logical_path(result.destination))

    case tool_save_meta(root, destination, previous, author, io) do
      {:ok, change} ->
        change = %{change | action: :created, path: result.destination}

        case tool_delete_meta(root, source, io) do
          :ok -> {:ok, [tool_change(result.source, :deleted, previous), change]}
          {:error, _} -> {:error, [result.source], [change]}
        end

      {:error, _} ->
        {:error, [result.source, result.destination], []}
    end
  end

  defp finish_tool(root, _action, result, metadata, author, io) do
    {path, previous} = Map.fetch!(metadata, logical_path(result.path))

    case tool_save_meta(root, path, previous, author, io) do
      {:ok, change} ->
        {:ok,
         [
           %{
             change
             | path: result.path,
               action: if(result.status == "created", do: :created, else: :updated)
           }
         ]}

      {:error, _} ->
        {:error, [result.path], []}
    end
  end

  defp tool_save_meta(root, path, previous, author, opts) do
    alias Synapsis.Filesystem.Local

    with {:ok, resolved} <- Synapsis.Workspace.PathResolver.resolve(path) do
      now = DateTime.utc_now()

      metadata =
        Map.merge(previous, %{
          id: previous[:id] || path_id(path),
          path: path,
          kind: previous[:kind] || Synapsis.Workspace.PathResolver.derive_kind(resolved.segments),
          visibility: previous[:visibility] || resolved.default_visibility,
          lifecycle: previous[:lifecycle] || resolved.default_lifecycle,
          content_format: previous[:content_format] || infer_format(path),
          metadata: previous[:metadata] || %{},
          created_by: previous[:created_by] || author,
          updated_by: author,
          agent_id: resolved.agent_id,
          session_id: resolved.session_id,
          version: (previous[:version] || 0) + 1,
          inserted_at: previous[:inserted_at] || now,
          updated_at: now
        })

      args = %{
        "path" => Path.relative_to(meta_path(root, path), root),
        "content" => Jason.encode!(metadata)
      }

      case Local.perform(root, :file_write, args, opts) do
        {:ok, _} -> {:ok, tool_change(path, :updated, metadata)}
        error -> error
      end
    end
  end

  defp tool_delete_meta(root, path, io) do
    case Local.perform(
           root,
           :file_delete,
           %{
             "path" => Path.relative_to(meta_path(root, path), root)
           },
           io
         ) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp tool_change(path, action, metadata),
    do: %{
      path: path,
      action: action,
      resource_id: metadata[:id] || path_id(path),
      agent_id: metadata[:agent_id]
    }

  defp logical_path(path),
    do: Path.expand("/" <> String.trim_leading(path, "/"))

  defp storage_arguments(args),
    do:
      Map.new(args, fn
        {"edits", edits} ->
          {"edits", Enum.map(edits, &storage_arguments/1)}

        {key, path} when key in ["path", "source", "destination"] ->
          {key, String.trim_leading(path, "/")}

        entry ->
          entry
      end)

  defp logical_result(result),
    do:
      Map.new(result, fn
        {key, path} when key in [:path, :source, :destination] ->
          {key, "/" <> String.trim_leading(path, "/")}

        {:paths, paths} ->
          {:paths, Enum.map(paths, &("/" <> String.trim_leading(&1, "/")))}

        {key, entries} when key in [:entries, :files, :matches] ->
          {key, Enum.map(entries, &logical_result/1)}

        entry ->
          entry
      end)

  @type document :: %{
          id: String.t(),
          path: String.t(),
          kind: String.t(),
          visibility: String.t(),
          lifecycle: String.t(),
          content_format: String.t(),
          content_body: String.t(),
          metadata: map(),
          version: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc "Get a document by path within a workspace root."
  @spec get(String.t(), String.t(), keyword()) :: {:ok, document()} | {:error, term()}
  def get(workspace_root, path, io_opts \\ []) do
    with_paths(workspace_root, [path], io_opts, fn io ->
      with {:ok, content, _} <-
             Local.read_binary(workspace_root, String.trim_leading(path, "/"), io),
           {:ok, meta} <- read_meta(workspace_root, path, io) do
        {:ok,
         Map.merge(meta, %{
           id: meta[:id] || path_id(path),
           path: path,
           content_body: content,
           content_format: meta[:content_format] || infer_format(path)
         })}
      end
    end)
  end

  @doc "List metadata from one bounded directory snapshot."
  def list_result(workspace_root, opts \\ [], io_opts \\ []) do
    selection = %{
      pattern: Keyword.get(opts, :pattern, "**/*"),
      exclude: [@meta_dir],
      read_patterns: [@meta_dir <> "/*.json"]
    }

    with {:ok, snapshot} <- Local.directory_snapshot(workspace_root, ".", selection, io_opts) do
      documents =
        snapshot.entries
        |> Enum.filter(&(&1.type == "file"))
        |> Enum.reject(&String.starts_with?(&1.path, @meta_dir))
        |> Enum.map(fn %{path: path} ->
          sidecar = Path.relative_to(meta_path(workspace_root, path), workspace_root)
          meta = decode_meta(Map.get(snapshot.files, sidecar))

          Map.merge(meta, %{
            id: meta[:id] || path_id(path),
            path: meta[:path] || path,
            content_format: meta[:content_format] || infer_format(path)
          })
        end)

      {:ok, documents}
    end
  end

  @doc "List document metadata, raising explicitly on operational errors."
  @spec list(String.t(), keyword(), keyword()) :: [document()]
  def list(workspace_root, opts \\ [], io_opts \\ []) do
    case list_result(workspace_root, opts, io_opts) do
      {:ok, documents} -> documents
      {:error, reason} -> raise "workspace document list failed: #{inspect(reason)}"
    end
  end

  @doc "Write document bytes and metadata under their complete pair of keys."
  @spec put(String.t(), map(), keyword()) :: {:ok, document()} | {:error, term()}
  def put(workspace_root, attrs, io_opts \\ []) do
    path = attrs[:path] || attrs["path"]

    if is_nil(path) do
      {:error, :missing_path}
    else
      with_paths(workspace_root, [path], io_opts, fn io ->
        content = attrs[:content_body] || attrs["content_body"] || ""

        with {:ok, existing_meta} <- read_meta(workspace_root, path, io),
             {:ok, _} <-
               Local.write_binary(
                 workspace_root,
                 String.trim_leading(path, "/"),
                 IO.iodata_to_binary(content),
                 io
               ) do
          now = DateTime.utc_now()

          meta =
            Map.merge(existing_meta, %{
              id: attrs[:id] || attrs["id"] || existing_meta[:id] || path_id(path),
              path: path,
              kind: attrs[:kind] || attrs["kind"] || existing_meta[:kind] || "document",
              visibility:
                attrs[:visibility] || attrs["visibility"] || existing_meta[:visibility] ||
                  "private",
              lifecycle:
                attrs[:lifecycle] || attrs["lifecycle"] || existing_meta[:lifecycle] || "draft",
              content_format:
                attrs[:content_format] || attrs["content_format"] ||
                  existing_meta[:content_format] || infer_format(path),
              metadata: attrs[:metadata] || attrs["metadata"] || existing_meta[:metadata] || %{},
              # Persist ownership fields so they survive the meta round-trip
              # (update_changeset requires created_by/updated_by).
              created_by: attrs[:created_by] || attrs["created_by"] || existing_meta[:created_by],
              updated_by:
                attrs[:updated_by] || attrs["updated_by"] || existing_meta[:updated_by] ||
                  attrs[:created_by] || attrs["created_by"],
              agent_id: attrs[:agent_id] || attrs["agent_id"] || existing_meta[:agent_id],
              session_id: attrs[:session_id] || attrs["session_id"] || existing_meta[:session_id],
              version: (existing_meta[:version] || 0) + 1,
              inserted_at: existing_meta[:inserted_at] || now,
              updated_at: now
            })

          with :ok <- write_meta(workspace_root, path, meta, io) do
            {:ok, Map.put(meta, :content_body, content)}
          end
        end
      end)
    end
  end

  @doc "Delete content and metadata; only ordinary absence is idempotent."
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(workspace_root, path, io_opts \\ []) do
    with_paths(workspace_root, [path], io_opts, fn io ->
      with :ok <- delete_file(workspace_root, String.trim_leading(path, "/"), io),
           :ok <- tool_delete_meta(workspace_root, path, io),
           do: :ok
    end)
  end

  defp delete_file(root, path, io) do
    case Local.perform(root, :file_delete, %{"path" => path}, io) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp read_meta(workspace_root, path, io) do
    relative = Path.relative_to(meta_path(workspace_root, path), workspace_root)

    case Local.read_binary(workspace_root, relative, io) do
      {:ok, json, _} -> {:ok, decode_meta(json)}
      {:error, :not_found} -> {:ok, %{}}
      error -> error
    end
  end

  defp decode_meta(nil), do: %{}

  defp decode_meta(json) do
    case Jason.decode(json, keys: :atoms) do
      {:ok, map} when is_map(map) ->
        map
        |> atomize_times(:inserted_at)
        |> atomize_times(:updated_at)

      _ ->
        %{}
    end
  end

  defp write_meta(workspace_root, path, meta, io) do
    relative = Path.relative_to(meta_path(workspace_root, path), workspace_root)

    serializable =
      Map.new(meta, fn
        {k, %DateTime{} = dt} -> {k, DateTime.to_iso8601(dt)}
        {k, v} -> {k, v}
      end)

    case Local.write_binary(
           workspace_root,
           relative,
           Jason.encode!(serializable, pretty: true),
           io
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # Slash-insensitive: "/a/b.md" and "a/b.md" map to the same sidecar/id so a
  # value stored by one caller is found by another regardless of leading slash.
  defp meta_path(workspace_root, path) do
    encoded = path |> String.trim_leading("/") |> String.replace("/", "__")
    Path.join([workspace_root, @meta_dir, "#{encoded}.json"])
  end

  defp path_id(path),
    do:
      :crypto.hash(:md5, String.trim_leading(path, "/"))
      |> Base.encode16(case: :lower)

  defp infer_format(path) do
    case Path.extname(path) do
      ".md" -> "markdown"
      ".json" -> "json"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      ".txt" -> "text"
      _ -> @default_format
    end
  end

  defp atomize_times(map, key) do
    case Map.get(map, key) do
      nil ->
        map

      str when is_binary(str) ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} -> Map.put(map, key, dt)
          _ -> map
        end

      _ ->
        map
    end
  end
end
