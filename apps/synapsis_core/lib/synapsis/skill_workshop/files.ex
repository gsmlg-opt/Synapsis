defmodule Synapsis.SkillWorkshop.Files do
  @moduledoc false

  alias Synapsis.Filesystem.Local

  @chunk 65_536
  @identity [:type, :inode, :major_device, :minor_device, :links, :size, :mtime, :ctime]

  # Every path belongs to the one admitted private-root lease. Child paths are
  # resolved here without attempting to acquire a second, differently keyed lease.
  def check(ctx) do
    with :ok <- Local.check_scope(ctx.opts), do: ctx.assert_live.()
  end

  def resolve(ctx, relative) when is_binary(relative) do
    path = Path.expand(relative, ctx.scope.root)

    if inside?(ctx.scope.root, path) do
      with :ok <- check(ctx),
           {:ok, ^path, _} <- Local.resolve(ctx.scope.config_root, path) do
        {:ok, path}
      end
    else
      {:error, :unsafe_path}
    end
  end

  def resolve(_, _), do: {:error, :invalid_path}

  # Classify the entry itself after guarding its parent; do not follow a link in
  # order to discover that it should be skipped by a snapshot or visible listing.
  def stat(ctx, relative) do
    absolute = Path.expand(relative, ctx.scope.root)

    with true <- inside?(ctx.scope.root, absolute),
         :ok <- check(ctx),
         {:ok, parent, _} <- Local.resolve(ctx.scope.config_root, Path.dirname(absolute)),
         {:ok, %{type: :directory}} <- File.lstat(parent, time: :posix),
         :ok <- check(ctx) do
      File.lstat(absolute, time: :posix)
    else
      false -> {:error, :unsafe_path}
      {:ok, _} -> {:error, :not_directory}
      error -> error
    end
  end

  def exists(ctx, relative) do
    case stat(ctx, relative) do
      {:ok, %{type: type}} when type in [:regular, :directory] -> {:ok, true}
      {:ok, _} -> {:error, :not_regular}
      {:error, :enoent} -> {:ok, false}
      error -> error
    end
  end

  def entries(ctx, relative) do
    case resolve(ctx, relative) do
      {:ok, path} ->
        case File.lstat(path, time: :posix) do
          {:error, :enoent} -> {:ok, []}
          {:ok, %{type: :directory} = before} -> entries_at(ctx, relative, path, before)
          {:ok, _} -> {:error, :not_directory}
          error -> error
        end

      error ->
        error
    end
  end

  defp entries_at(ctx, relative, path, before) do
    with :ok <- check(ctx),
         {:ok, names} <- File.ls(path),
         {:ok, after_stat} <- File.lstat(path, time: :posix),
         true <- identity(before) == identity(after_stat) do
      reduce(names, [], fn name, acc ->
        with {:ok, entry} <- stat(ctx, Path.join(relative, name)) do
          {:ok, [{name, entry} | acc]}
        end
      end)
    else
      false -> {:error, :conflict}
      error -> error
    end
  end

  def visible(ctx, relative, policy \\ :list) do
    with {:ok, files} <- walk_visible(ctx, relative, "", policy) do
      {:ok, Enum.reverse(files)}
    end
  end

  defp walk_visible(ctx, base, prefix, policy) do
    with {:ok, entries} <- entries(ctx, Path.join(base, prefix)) do
      reduce(entries, [], fn {name, stat}, acc ->
        relative = Path.join(prefix, name)

        cond do
          String.starts_with?(name, ".") ->
            {:ok, acc}

          stat.type == :directory ->
            with {:ok, nested} <- walk_visible(ctx, base, relative, policy),
                 do: {:ok, nested ++ acc}

          stat.type == :regular ->
            {:ok, [relative | acc]}

          policy == :list ->
            {:ok, acc}

          true ->
            {:error, :not_regular}
        end
      end)
    end
  end

  def metadata(ctx, base) do
    with {:ok, files} <- visible(ctx, base),
         :ok <- check(ctx),
         {:ok, facts} <-
           Local.precise_metadata(
             ctx.scope.config_root,
             ctx.scope.relative_root,
             Enum.map(files, &Path.join(base, &1)),
             files,
             ctx.opts
           ),
         :ok <- check(ctx) do
      names = facts["names"]

      sorted =
        if "SKILL.md" in names, do: ["SKILL.md" | List.delete(names, "SKILL.md")], else: names

      {:ok,
       %{
         "files" => sorted,
         "sizeBytes" => facts["sizeBytes"],
         "updatedAtMs" => facts["updatedAtMs"]
       }}
    end
  end

  def sort_names(ctx, []) do
    with :ok <- check(ctx), do: {:ok, []}
  end

  def sort_names(ctx, names) do
    with :ok <- check(ctx),
         {:ok, facts} <-
           Local.precise_metadata(
             ctx.scope.config_root,
             ctx.scope.relative_root,
             [],
             names,
             ctx.opts
           ),
         :ok <- check(ctx),
         do: {:ok, facts["names"]}
  end

  def read(ctx, relative, maximum) do
    with {:ok, path} <- resolve(ctx, relative),
         {:ok, %{type: :regular, links: 1} = before} <- File.lstat(path, time: :posix),
         true <- before.size <= maximum,
         :ok <- check(ctx),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      result =
        try do
          with :ok <- descriptor(io, before),
               {:ok, bytes} <- read_chunks(ctx, io, maximum, [], 0),
               :ok <- descriptor(io, before),
               {:ok, ^path} <- resolve(ctx, relative),
               {:ok, after_stat} <- File.lstat(path, time: :posix),
               true <- identity(before) == identity(after_stat) do
            {:ok, bytes}
          else
            false -> {:error, :conflict}
            error -> error
          end
        after
          File.close(io)
        end

      result
    else
      false -> {:error, :too_large}
      {:ok, _} -> {:error, :not_regular}
      error -> error
    end
  end

  defp read_chunks(ctx, io, maximum, chunks, total) do
    with :ok <- check(ctx) do
      case :file.read(io, min(@chunk, max(1, maximum - total + 1))) do
        :eof ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {:ok, data} when total + byte_size(data) <= maximum ->
          read_chunks(ctx, io, maximum, [data | chunks], total + byte_size(data))

        {:ok, _} ->
          {:error, :too_large}

        error ->
          error
      end
    end
  end

  @doc false
  def content_tree(ctx, base) do
    # Directory/file evidence belongs only to this acquisition. The durable
    # revision encodes content, so stat times, modes and empty directories never
    # affect equality between independently captured catalogs.
    with {:ok, before} <- tree_manifest(ctx, base, ""),
         true <- match?(%{type: :regular}, Map.get(before, "SKILL.md")),
         initial = :crypto.hash_init(:sha256),
         initial = :crypto.hash_update(initial, <<"synapsis-workshop-tree-v1", 0>>),
         files =
           before
           |> Enum.filter(fn {_path, stat} -> stat.type == :regular end)
           |> Enum.sort_by(&elem(&1, 0)),
         {:ok, captured} <-
           reduce(files, %{hash: initial, content: nil, document_digest: nil}, fn {path, stat},
                                                                                  acc ->
             hash_tree_file(ctx, base, path, stat, acc)
           end),
         {:ok, ^before} <- tree_manifest(ctx, base, ""),
         :ok <- check(ctx) do
      {:ok,
       %{
         content: captured.content,
         revision: digest(:crypto.hash_final(captured.hash)),
         document_digest: captured.document_digest
       }}
    else
      false -> {:error, :missing_skill_file}
      {:ok, _} -> {:error, :conflict}
      error -> error
    end
  end

  defp tree_manifest(ctx, base, prefix) do
    relative = if prefix == "", do: base, else: Path.join(base, prefix)

    with {:ok, %{type: :directory} = directory} <- stat(ctx, relative),
         {:ok, children} <- entries(ctx, relative) do
      reduce(children, %{prefix => identity(directory)}, fn {name, stat}, acc ->
        path = if prefix == "", do: name, else: Path.join(prefix, name)

        cond do
          not String.valid?(path) ->
            {:error, :invalid_path}

          stat.type == :symlink ->
            {:ok, acc}

          stat.type == :directory ->
            with {:ok, nested} <- tree_manifest(ctx, base, path),
                 do: {:ok, Map.merge(acc, nested)}

          stat.type == :regular and stat.links == 1 and stat.size >= 0 and
              stat.size <= 0xFFFFFFFFFFFFFFFF ->
            {:ok, Map.put(acc, path, identity(stat))}

          true ->
            {:error, :not_regular}
        end
      end)
    else
      {:ok, _} -> {:error, :not_directory}
      error -> error
    end
  end

  defp hash_tree_file(ctx, base, path, expected, acc) do
    relative = Path.join(base, path)
    path_size = byte_size(path)

    framed =
      <<path_size::unsigned-big-integer-size(64), path::binary,
        expected.size::unsigned-big-integer-size(64)>>

    hash = :crypto.hash_update(acc.hash, framed)

    if path == "SKILL.md" do
      with {:ok, bytes} <- read(ctx, relative, 1_024 * 1_024),
           true <- byte_size(bytes) == expected.size,
           {:ok, after_stat} <- stat(ctx, relative),
           true <- identity(after_stat) == expected do
        {:ok,
         %{
           acc
           | hash: :crypto.hash_update(hash, bytes),
             content: bytes,
             document_digest: digest(:crypto.hash(:sha256, bytes))
         }}
      else
        false -> {:error, :conflict}
        error -> error
      end
    else
      with {:ok, hash} <- stream_tree_file(ctx, relative, expected, hash) do
        {:ok, %{acc | hash: hash}}
      end
    end
  end

  defp stream_tree_file(ctx, relative, expected, hash) do
    with {:ok, path} <- resolve(ctx, relative),
         {:ok, %{type: :regular, links: 1} = before} <- File.lstat(path, time: :posix),
         true <- identity(before) == expected,
         :ok <- check(ctx),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with :ok <- descriptor(io, before),
             {:ok, hash} <- hash_tree_chunks(ctx, io, hash, before.size, 0),
             :ok <- descriptor(io, before),
             {:ok, ^path} <- resolve(ctx, relative),
             {:ok, after_stat} <- File.lstat(path, time: :posix),
             true <- identity(after_stat) == expected do
          {:ok, hash}
        else
          false -> {:error, :conflict}
          error -> error
        end
      after
        File.close(io)
      end
    else
      false -> {:error, :conflict}
      {:ok, _} -> {:error, :not_regular}
      error -> error
    end
  end

  defp hash_tree_chunks(ctx, io, hash, expected_size, total) do
    with :ok <- check(ctx) do
      case :file.read(io, @chunk) do
        :eof when total == expected_size ->
          {:ok, hash}

        {:ok, chunk} when total + byte_size(chunk) <= expected_size ->
          hash_tree_chunks(
            ctx,
            io,
            :crypto.hash_update(hash, chunk),
            expected_size,
            total + byte_size(chunk)
          )

        :eof ->
          {:error, :conflict}

        {:ok, _} ->
          {:error, :conflict}

        error ->
          error
      end
    end
  end

  defp digest(hash), do: "sha256:" <> Base.encode16(hash, case: :lower)

  def mkdir(ctx, relative) do
    with {:ok, absolute} <- resolve(ctx, relative) do
      mkdir_absolute(ctx, absolute)
    end
  end

  defp mkdir_absolute(ctx, absolute) do
    case File.lstat(absolute, time: :posix) do
      {:ok, %{type: :directory}} ->
        check(ctx)

      {:error, :enoent} ->
        with :ok <- mkdir_parent(ctx, Path.dirname(absolute)),
             {:ok, ^absolute, _} <- Local.resolve(ctx.scope.config_root, absolute),
             :ok <- check(ctx),
             :ok <- File.mkdir(absolute) do
          :ok
        end

      {:ok, _} ->
        {:error, :not_directory}

      error ->
        error
    end
  end

  defp mkdir_parent(ctx, path) do
    # The missing agents/UUID parents are still covered by the admitted private
    # root's physical ancestry; never create outside the configured root.
    if inside?(ctx.scope.config_root, path) do
      with :ok <- check(ctx),
           {:ok, ^path, _} <- Local.resolve(ctx.scope.config_root, path) do
        mkdir_absolute(ctx, path)
      end
    else
      {:error, :unsafe_path}
    end
  end

  def write(ctx, relative, bytes) when is_binary(bytes) do
    temporary = Path.join(Path.dirname(relative), ".write-" <> Ecto.UUID.generate())

    result =
      with :ok <- mkdir(ctx, Path.dirname(relative)),
           {:ok, expected} <- target_identity(ctx, relative),
           :ok <- exclusive_write(ctx, temporary, bytes),
           {:ok, ^expected} <- target_identity(ctx, relative),
           :ok <- rename(ctx, temporary, relative),
           {:ok, ^bytes} <- read(ctx, relative, byte_size(bytes)) do
        :ok
      end

    cleanup(ctx, temporary)
    result
  end

  defp exclusive_write(ctx, relative, bytes) do
    with {:ok, path} <- resolve(ctx, relative),
         :ok <- check(ctx),
         {:ok, io} <- File.open(path, [:write, :binary, :raw, :exclusive]) do
      try do
        with :ok <- write_chunks(ctx, io, bytes), do: :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  defp write_chunks(_ctx, _io, <<>>), do: :ok

  defp write_chunks(ctx, io, bytes) do
    count = min(@chunk, byte_size(bytes))
    <<chunk::binary-size(count), rest::binary>> = bytes

    with :ok <- check(ctx), :ok <- :file.write(io, chunk), do: write_chunks(ctx, io, rest)
  end

  def rename(ctx, source, destination) do
    with {:ok, from} <- resolve(ctx, source),
         {:ok, to} <- resolve(ctx, destination),
         :ok <- check(ctx),
         do: File.rename(from, to)
  end

  def remove(ctx, relative) do
    with {:ok, path} <- resolve(ctx, relative),
         {:ok, %{type: :regular, links: 1}} <- File.lstat(path, time: :posix),
         :ok <- check(ctx),
         do: File.rm(path)
  end

  def remove_tree(ctx, relative) do
    case stat(ctx, relative) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        with {:ok, entries} <- entries(ctx, relative),
             {:ok, _} <-
               reduce(entries, nil, fn {name, _}, _ ->
                 with :ok <- remove_tree(ctx, Path.join(relative, name)), do: {:ok, nil}
               end),
             {:ok, path} <- resolve(ctx, relative),
             :ok <- check(ctx),
             do: File.rmdir(path)

      {:ok, _} ->
        # Removal acts on the entry, including links, after resolving its parent.
        with :ok <- check(ctx),
             {:ok, parent} <- resolve(ctx, Path.dirname(relative)),
             :ok <- check(ctx),
             do: File.rm(Path.join(parent, Path.basename(relative)))

      error ->
        error
    end
  end

  # Only callers' UUID-named ignored staging paths are passed to cleanup. Scope
  # loss is not bypassed even for cleanup, and cleanup never replaces an outcome.
  def cleanup(ctx, relative), do: remove_tree(ctx, relative)

  def copy_tree(ctx, source, destination) do
    with {:ok, %{type: :directory} = before} <- stat(ctx, source),
         :ok <- mkdir(ctx, destination),
         {:ok, entries} <- entries(ctx, source),
         {:ok, _} <-
           reduce(entries, nil, fn {name, stat}, _ ->
             from = Path.join(source, name)
             to = Path.join(destination, name)

             result =
               case stat.type do
                 :directory -> copy_tree(ctx, from, to)
                 :regular -> copy_file(ctx, from, to)
                 :symlink -> :ok
                 _ -> {:error, :not_regular}
               end

             with :ok <- result, do: {:ok, nil}
           end),
         :ok <- copy_mode(ctx, destination, before.mode),
         do: :ok
  end

  defp copy_file(ctx, source, destination) do
    with {:ok, from} <- resolve(ctx, source),
         {:ok, %{type: :regular, links: 1} = before} <- File.lstat(from, time: :posix),
         {:ok, to} <- resolve(ctx, destination),
         :ok <- check(ctx),
         {:ok, input} <- File.open(from, [:read, :binary, :raw]) do
      try do
        with :ok <- descriptor(input, before),
             :ok <- copy_into(ctx, input, to),
             :ok <- descriptor(input, before),
             {:ok, ^from} <- resolve(ctx, source),
             {:ok, after_stat} <- File.lstat(from, time: :posix),
             true <- identity(before) == identity(after_stat),
             :ok <- copy_mode(ctx, destination, before.mode) do
          :ok
        else
          false -> {:error, :conflict}
          error -> error
        end
      after
        File.close(input)
      end
    else
      {:ok, _} -> {:error, :not_regular}
      error -> error
    end
  end

  defp copy_mode(ctx, relative, source_mode) do
    mode = Bitwise.band(source_mode, 0o7777)

    with {:ok, path} <- resolve(ctx, relative),
         {:ok, before} <- File.lstat(path, time: :posix),
         true <- before.type in [:regular, :directory] and before.links >= 1,
         :ok <- check(ctx),
         :ok <- File.chmod(path, mode),
         {:ok, ^path} <- resolve(ctx, relative),
         {:ok, after_stat} <- File.lstat(path, time: :posix),
         true <-
           Map.take(before, [:type, :inode, :major_device, :minor_device, :links, :size]) ==
             Map.take(after_stat, [:type, :inode, :major_device, :minor_device, :links, :size]),
         true <- Bitwise.band(after_stat.mode, 0o7777) == mode do
      :ok
    else
      false -> {:error, :conflict}
      error -> error
    end
  end

  defp copy_into(ctx, input, destination) do
    with :ok <- check(ctx),
         {:ok, output} <- File.open(destination, [:write, :binary, :raw, :exclusive]) do
      try do
        with :ok <- copy_chunks(ctx, input, output), do: :file.sync(output)
      after
        File.close(output)
      end
    end
  end

  defp copy_chunks(ctx, input, output) do
    with :ok <- check(ctx) do
      case :file.read(input, @chunk) do
        :eof ->
          :ok

        {:ok, chunk} ->
          with :ok <- check(ctx),
               :ok <- :file.write(output, chunk),
               do: copy_chunks(ctx, input, output)

        error ->
          error
      end
    end
  end

  defp target_identity(ctx, relative) do
    case stat(ctx, relative) do
      {:error, :enoent} -> {:ok, :missing}
      {:ok, %{type: :regular, links: 1} = stat} -> {:ok, identity(stat)}
      {:ok, _} -> {:error, :not_regular}
      error -> error
    end
  end

  defp descriptor(io, before) do
    with {:ok, record} <- :file.read_file_info(io, time: :posix),
         true <- identity(File.Stat.from_record(record)) == identity(before) do
      :ok
    else
      false -> {:error, :conflict}
      error -> error
    end
  end

  defp identity(stat), do: Map.take(stat, @identity)
  defp inside?(root, path), do: List.starts_with?(Path.split(path), Path.split(root))

  defp reduce(items, initial, fun) do
    Enum.reduce_while(items, {:ok, initial}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, value} -> {:cont, {:ok, value}}
        error -> {:halt, error}
      end
    end)
  end
end
