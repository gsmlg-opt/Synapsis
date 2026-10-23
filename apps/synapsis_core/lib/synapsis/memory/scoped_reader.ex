defmodule Synapsis.Memory.ScopedReader do
  @moduledoc """
  Read-only lexical access to existing FileAdapter project records.

  Scope and root are trusted host inputs, never model arguments. Only project
  records are supported: current session records do not carry a verified project
  association. No shared/agent/session fallback or access-stat writes occur.

  Fixed limits: 128 directory entries, 64 KiB per file/output, 20 results,
  8 KiB per summary, one second and a bounded worker heap. `:deadline` may only
  shorten that deadline. Missing roots are unavailable; missing project folders
  are empty collections. Failures never become successful empty searches.

  Symlinks/hardlinks are rejected, with opened-file identity and pre/post ancestry
  checks. These checks do not provide atomic openat/no-follow traversal against
  hostile concurrent renames. Citations identify semantic records, not file lines.
  """

  @max_file 65_536
  @max_output 65_536

  def root do
    System.get_env("SYNAPSIS_MEMORY_DIR") ||
      Application.get_env(
        :synapsis_core,
        :memory_dir,
        Path.join(System.user_home!(), ".config/synapsis/memory")
      )
  end

  def valid_id?(id),
    do:
      is_binary(id) and byte_size(id) <= 128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, id)

  def search(scope, query, opts \\ []) do
    with :ok <- validate_scope(scope),
         true <- is_binary(query) and String.valid?(query) and byte_size(query) in 1..2_048,
         limit = Keyword.get(opts, :limit, 5),
         true <- is_integer(limit) and limit in 1..20 do
      bounded(
        opts,
        fn directory ->
          with {:ok, entries} <- entries(directory),
               {:ok, records} <- records(directory, entries, scope, String.downcase(query)) do
            results =
              records
              |> Enum.sort_by(& &1.memory_id)
              |> Enum.take(limit)

            output(%{status: "ok", ranking: "lexical", results: results})
          end
        end,
        scope
      )
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  def read(scope, memory_id, opts \\ []) do
    with :ok <- validate_scope(scope),
         true <- valid_id?(memory_id) do
      bounded(
        opts,
        fn directory ->
          with {:ok, record} <- read_record(directory, memory_id, scope),
               do: output(%{status: "ok", record: public_record(record)})
        end,
        scope
      )
    else
      false -> {:error, :invalid_memory_id}
      {:error, _} = error -> error
    end
  end

  defp validate_scope(%{project_id: project, session_id: session, selector: :project}) do
    if valid_id?(project) and valid_id?(session), do: :ok, else: {:error, :invalid_scope}
  end

  defp validate_scope(%{selector: selector}) when selector != :project,
    do: {:error, :unsupported_scope}

  defp validate_scope(_), do: {:error, :invalid_scope}

  defp bounded(opts, fun, scope) do
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + 1_000)
    root = Keyword.get(opts, :root, root())

    if is_integer(deadline) and is_binary(root) and Path.type(root) == :absolute do
      timeout = min(1_000, max(0, deadline - now))

      if timeout == 0 do
        {:error, :timeout}
      else
        parent = self()
        ref = make_ref()

        {pid, monitor} =
          spawn_monitor(fn ->
            guard(parent, ref, timeout, fn ->
              with {:ok, _} <- ancestry(root, :unavailable),
                   do: fun.(Path.join([root, "project", scope.project_id]))
            end)
          end)

        receive do
          {^ref, result} ->
            receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> result)

          {:DOWN, ^monitor, :process, ^pid, _} ->
            {:error, :worker_limit}
        end
      end
    else
      {:error, :invalid_input}
    end
  end

  # The isolated guardian owns cancellation and the timer even when the caller
  # dies. Its linked reader cannot survive guardian death; caller exit flags are
  # untouched. The reader's heap limit may kill it without killing the caller.
  defp guard(owner, reply, timeout, fun) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    result_ref = make_ref()
    guardian = self()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result = fun.()
          send(guardian, {result_ref, result})
        end,
        [:link, :monitor, {:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false}}]
      )

    deadline = System.monotonic_time(:millisecond) + timeout

    case await_worker(worker, monitor, owner_monitor, result_ref, deadline, nil) do
      :owner_gone -> :ok
      result -> send(owner, {reply, result})
    end
  end

  defp await_worker(worker, monitor, owner_monitor, result_ref, deadline, result) do
    receive do
      {^result_ref, value} ->
        await_worker(worker, monitor, owner_monitor, result_ref, deadline, value)

      {:DOWN, ^monitor, :process, ^worker, _} ->
        result || {:error, :worker_limit}

      {:DOWN, ^owner_monitor, :process, _, _} ->
        stop_worker(worker, monitor)
        :owner_gone

      {:EXIT, ^worker, _} ->
        await_worker(worker, monitor, owner_monitor, result_ref, deadline, result)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        stop_worker(worker, monitor)
        {:error, :timeout}
    end
  end

  defp stop_worker(worker, monitor) do
    Process.exit(worker, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^worker, _} -> :ok)
  end

  defp entries(directory) do
    with {:ok, _} <- ancestry(directory, :not_found),
         {:ok, names} <- File.ls(directory) do
      if length(names) <= 128, do: {:ok, Enum.sort(names)}, else: {:error, :scan_limit}
    else
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp records(directory, entries, scope, query) do
    entries
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case read_record(directory, Path.rootname(name, ".md"), scope) do
        {:ok, record} ->
          text = Enum.join([record.title, record.summary | record.tags], " ") |> String.downcase()
          records = if String.contains?(text, query), do: [public_record(record) | acc], else: acc
          {:cont, {:ok, records}}

        {:error, :not_found} ->
          {:cont, {:ok, acc}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp read_record(directory, id, scope) do
    with true <- valid_id?(id),
         {:ok, ancestors} <- ancestry(directory, :not_found),
         path = Path.join(directory, id <> ".md"),
         {:ok, stat} <- leaf(path),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(io, time: :posix),
             true <- same_file?(stat, File.Stat.from_record(info)),
             {:ok, ^ancestors} <- ancestry(directory, :not_found),
             {:ok, current} <- leaf(path),
             true <- same_file?(stat, current),
             {:ok, content} <- :file.read(io, @max_file + 1),
             true <- byte_size(content) <= @max_file,
             {:ok, ^ancestors} <- ancestry(directory, :not_found),
             {:ok, final} <- leaf(path),
             true <- same_file?(stat, final) do
          parse(content, id, scope)
        else
          false -> {:error, :unsafe_path}
          :eof -> {:error, :malformed_record}
          {:ok, _} -> {:error, :unsafe_path}
          {:error, _} = error -> error
        end
      after
        File.close(io)
      end
    else
      false -> {:error, :invalid_memory_id}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp ancestry(path, missing) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, acc} ->
      case File.lstat(component, time: :posix) do
        {:ok, %{type: :directory} = stat} -> {:cont, {:ok, [{component, identity(stat)} | acc]}}
        {:ok, _} -> {:halt, {:error, :unsafe_path}}
        {:error, :enoent} -> {:halt, {:error, missing}}
        {:error, _} -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp leaf(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular, links: 1, size: size} = stat} when size <= @max_file -> {:ok, stat}
      {:ok, %{type: :regular, links: 1}} -> {:error, :file_limit}
      {:ok, _} -> {:error, :unsafe_path}
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp identity(stat), do: {stat.type, stat.major_device, stat.minor_device, stat.inode}

  defp same_file?(a, b),
    do:
      identity(a) == identity(b) and a.links == b.links and a.size == b.size and
        a.mtime == b.mtime and a.ctime == b.ctime

  defp parse(content, id, scope) do
    with true <- String.valid?(content),
         ["", yaml, body] <- String.split(content, "---\n", parts: 3),
         {:ok, [pairs]} <- YamlElixir.read_all_from_string(yaml, maps_as_keywords: true),
         true <- is_list(pairs) and Enum.all?(pairs, &match?({key, _} when is_binary(key), &1)),
         keys = Enum.map(pairs, &elem(&1, 0)),
         true <- length(keys) == length(Enum.uniq(keys)),
         # Pair mode preserves duplicate keys but conflates YAML {} with [].
         # Normal mode preserves field types after the duplicate-key check.
         {:ok, [fields]} when is_map(fields) <- YamlElixir.read_all_from_string(yaml) do
      cond do
        fields["id"] !== id or fields["scope"] !== "project" or
            fields["scope_id"] !== scope.project_id ->
          {:error, :ownership_mismatch}

        not valid_archive_marker?(fields["archived_at"]) ->
          {:error, :malformed_record}

        fields["archived_at"] not in [nil, ""] ->
          {:error, :not_found}

        not valid_public?(fields) ->
          {:error, :malformed_record}

        true ->
          summary = String.trim(body)

          {:ok,
           %{
             memory_id: id,
             title: fields["title"],
             summary: summary,
             tags: Map.get(fields, "tags", []),
             citation: %{memory_id: id, scope: "project", scope_id: scope.project_id}
           }}
      end
    else
      _ -> {:error, :malformed_record}
    end
  end

  defp valid_archive_marker?(marker) when marker in [nil, ""], do: true

  defp valid_archive_marker?(marker) when is_binary(marker) do
    match?({:ok, %DateTime{}, _offset}, DateTime.from_iso8601(marker))
  end

  defp valid_archive_marker?(_), do: false

  defp public_record(record) do
    record
    |> Map.put(:truncated, byte_size(record.summary) > 8_192)
    |> Map.update!(:summary, &truncate(&1, 8_192))
  end

  defp valid_public?(fields) do
    title = fields["title"]
    tags = Map.get(fields, "tags", [])

    is_binary(title) and byte_size(title) <= 256 and is_list(tags) and length(tags) <= 20 and
      Enum.all?(tags, &(is_binary(&1) and byte_size(&1) <= 128))
  end

  defp truncate(text, size) when byte_size(text) <= size, do: text

  defp truncate(text, size) do
    prefix = binary_part(text, 0, size)
    if String.valid?(prefix), do: prefix, else: truncate(text, size - 1)
  end

  defp output(result) do
    if byte_size(Jason.encode!(result)) <= @max_output,
      do: {:ok, result},
      else: {:error, :output_limit}
  end
end
