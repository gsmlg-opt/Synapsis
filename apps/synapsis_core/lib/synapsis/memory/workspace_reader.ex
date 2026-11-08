defmodule Synapsis.Memory.WorkspaceReader do
  @moduledoc """
  Bounded, read-only access to workspace `MEMORY.md` and `memory/**/*.md`.

  Markdown needs no front matter. Search is lexical, with real one-based line
  citations. No directories or files are created. The trusted root must be an
  absolute path. Symlinks and hardlinks are rejected; identity and ancestry are
  checked around reads, without claiming atomic openat/no-follow protection
  against hostile concurrent renames.

  Limits are 128 scanned entries, 64 KiB per file and JSON response, 120 lines
  and 12,000 UTF-16 code units per read page (matching OpenClaw), 20 search
  results and 2 KiB per snippet. Pages fit complete lines. An oversized first
  line is explicitly marked partial, with no line continuation that would skip
  its remainder. An isolated worker has a bounded heap and a one-second total
  deadline, shortened by `:deadline`.
  """

  @max_file 65_536
  @max_output 65_536
  @max_entries 128
  @max_chars 12_000

  def list(root, opts \\ []) do
    with :ok <- options(opts, [:deadline]) do
      bounded(root, opts, fn root ->
        with {:ok, files} <- files(root), do: output(%{status: "ok", files: files})
      end)
    end
  end

  def read(root, path, opts \\ []) do
    with :ok <- options(opts, [:from, :lines, :deadline]),
         true <- valid_path?(path),
         from = Keyword.get(opts, :from, 1),
         count = Keyword.get(opts, :lines, 120),
         true <- is_integer(from) and from > 0 and is_integer(count) and count in 1..120 do
      bounded(root, opts, fn root ->
        with {:ok, content} <- read_file(root, path) do
          lines = lines(content)
          selected = Enum.slice(lines, from - 1, count)
          {excerpt, included, partial} = fit_lines(selected)
          last = from + included - 1
          truncated = partial or length(lines) > last

          output(%{
            status: "ok",
            path: path,
            from: from,
            to: last,
            content: excerpt,
            truncated: truncated,
            next_from: if(truncated and not partial, do: last + 1),
            partial_line: partial,
            notice:
              if(partial,
                do:
                  "Excerpt stops within a source line. Read the source file to retrieve the full line."
              )
          })
        end
      end)
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  def search(root, query, opts \\ []) do
    with :ok <- options(opts, [:limit, :deadline]),
         true <- is_binary(query) and String.valid?(query) and byte_size(query) in 1..2_048,
         limit = Keyword.get(opts, :limit, 5),
         true <- is_integer(limit) and limit in 1..20 do
      bounded(root, opts, fn root ->
        with {:ok, files} <- files(root),
             {:ok, results} <- matches(root, files, String.downcase(query), limit) do
          output(%{status: "ok", ranking: "lexical", results: results})
        end
      end)
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  defp options(opts, allowed) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, _} -> key in allowed end) and
         length(opts) == length(Keyword.keys(opts) |> Enum.uniq()),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp valid_path?(path) when is_binary(path) do
    String.valid?(path) and byte_size(path) in 1..4_096 and
      not String.contains?(path, ["\0", "\\"]) and Path.type(path) == :relative and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])) and
      (path == "MEMORY.md" or
         (String.starts_with?(path, "memory/") and String.ends_with?(path, ".md")))
  end

  defp valid_path?(_), do: false

  defp bounded(root, opts, fun) do
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + 1_000)

    if is_binary(root) and String.valid?(root) and not String.contains?(root, "\0") and
         Path.type(root) == :absolute and is_integer(deadline) do
      timeout = min(1_000, max(0, deadline - now))

      if timeout == 0 do
        {:error, :timeout}
      else
        owner = self()
        reply = make_ref()

        {pid, monitor} =
          spawn_monitor(fn ->
            guard(owner, reply, timeout, fn ->
              with {:ok, _} <- ancestry(root, :unavailable), do: fun.(root)
            end)
          end)

        receive do
          {^reply, result} ->
            receive do: ({:DOWN, ^monitor, :process, ^pid, _} -> result)

          {:DOWN, ^monitor, :process, ^pid, _} ->
            {:error, :worker_limit}
        end
      end
    else
      {:error, :invalid_input}
    end
  end

  # The guardian owns timeout and owner monitoring; the linked filesystem worker
  # cannot outlive it, including when that worker is suspended.
  defp guard(owner, reply, timeout, fun) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    result_ref = make_ref()
    guardian = self()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn -> send(guardian, {result_ref, fun.()}) end,
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

  defp files(root) do
    with {:ok, canonical} <- optional_file(root, "MEMORY.md"),
         {:ok, nested, _count} <- walk(root, "memory", length(canonical) + 1) do
      {:ok, Enum.sort_by(canonical ++ nested, & &1.path)}
    end
  end

  defp optional_file(root, path) do
    case leaf(Path.join(root, path)) do
      {:ok, stat} -> {:ok, [%{path: path, size: stat.size}]}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp walk(root, relative, count) do
    directory = Path.join(root, relative)

    with {:ok, ancestors} <- ancestry(directory, :not_found),
         {:ok, names} <- File.ls(directory),
         true <- count + length(names) <= @max_entries,
         {:ok, ^ancestors} <- ancestry(directory, :not_found) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, [], count + length(names)}, fn name, {:ok, files, scanned} ->
        path = Path.join(relative, name)

        result =
          case File.lstat(Path.join(root, path), time: :posix) do
            {:ok, %{type: :directory}} ->
              walk(root, path, scanned)

            {:ok, %{type: :regular}} ->
              if String.ends_with?(name, ".md"),
                do: optional_file(root, path),
                else: {:ok, []}

            {:ok, _} ->
              {:error, :unsafe_path}

            {:error, _} ->
              {:error, :unavailable}
          end

        case result do
          {:ok, children, next} -> {:cont, {:ok, files ++ children, next}}
          {:ok, children} -> {:cont, {:ok, files ++ children, scanned}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      false -> {:error, :scan_limit}
      {:error, :not_found} -> {:ok, [], count}
      {:error, _} = error -> error
      {:ok, _} -> {:error, :unsafe_path}
    end
  end

  defp matches(root, files, query, limit) do
    Enum.reduce_while(files, {:ok, []}, fn %{path: path}, {:ok, results} ->
      case read_file(root, path) do
        {:ok, content} ->
          found =
            content
            |> lines()
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} -> String.contains?(String.downcase(line), query) end)
            |> Enum.take(limit)
            |> Enum.map(fn {line, number} ->
              %{path: path, from: number, to: number, snippet: snippet(line, query)}
            end)

          {:cont, {:ok, Enum.take(results ++ found, limit)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp read_file(root, relative) do
    path = Path.join(root, relative)

    with {:ok, ancestors} <- ancestry(Path.dirname(path), :not_found),
         {:ok, stat} <- leaf(path),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(io, time: :posix),
             true <- same_file?(stat, File.Stat.from_record(info)),
             {:ok, ^ancestors} <- ancestry(Path.dirname(path), :not_found),
             {:ok, current} <- leaf(path),
             true <- same_file?(stat, current),
             {:ok, content} <- file_content(io),
             true <- byte_size(content) <= @max_file,
             true <- String.valid?(content),
             {:ok, after_info} <- :file.read_file_info(io, time: :posix),
             true <- same_file?(stat, File.Stat.from_record(after_info)),
             {:ok, ^ancestors} <- ancestry(Path.dirname(path), :not_found),
             {:ok, final} <- leaf(path),
             true <- same_file?(stat, final) do
          {:ok, content}
        else
          false -> {:error, :unsafe_path}
          {:ok, _} -> {:error, :unsafe_path}
          {:error, _} = error -> error
        end
      after
        File.close(io)
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp file_content(io) do
    case :file.read(io, @max_file + 1) do
      :eof -> {:ok, ""}
      result -> result
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

  defp lines(""), do: []

  defp lines(content) do
    parts = String.split(content, "\n")
    {complete, [last]} = Enum.split(parts, -1)
    complete = Enum.map(complete, &(&1 <> "\n"))
    if last == "", do: complete, else: complete ++ [last]
  end

  defp fit_lines(lines) do
    {selected, _chars, partial} =
      Enum.reduce_while(lines, {[], 0, false}, fn line, {selected, chars, _partial} ->
        utf16 = :unicode.characters_to_binary(line, :utf8, {:utf16, :big})
        units = div(byte_size(utf16), 2)

        cond do
          chars + units <= @max_chars ->
            {:cont, {[line | selected], chars + units, false}}

          selected == [] ->
            {:halt, {[truncate_chars(utf16)], @max_chars, true}}

          true ->
            {:halt, {selected, chars, false}}
        end
      end)

    {selected |> Enum.reverse() |> Enum.join(), length(selected), partial}
  end

  defp truncate_chars(utf16) do
    prefix = binary_part(utf16, 0, @max_chars * 2)

    case :unicode.characters_to_binary(prefix, {:utf16, :big}, :utf8) do
      text when is_binary(text) -> text
      {:incomplete, text, _surrogate} -> text
    end
  end

  defp snippet(line, query) do
    {offset, _} = :binary.match(String.downcase(line), query)
    original_offset = original_offset(line, offset, 0)
    context = min(128, 2_048 - byte_size(query))
    start = max(0, original_offset - context)

    line
    |> binary_part(start, byte_size(line) - start)
    |> valid_start()
    |> truncate(2_048)
  end

  # Downcasing can change byte lengths (for example dotted capital I), so map
  # the match offset back to the original text before selecting its context.
  defp original_offset(_text, remaining, offset) when remaining <= 0, do: offset

  defp original_offset(text, remaining, offset) do
    {point, rest} = String.next_codepoint(text)
    lowered_size = byte_size(String.downcase(point))

    if remaining < lowered_size,
      do: offset,
      else: original_offset(rest, remaining - lowered_size, offset + byte_size(point))
  end

  defp valid_start(text) do
    if String.valid?(text), do: text, else: valid_start(binary_part(text, 1, byte_size(text) - 1))
  end

  defp truncate(text, size) when byte_size(text) <= size, do: text

  defp truncate(text, size) do
    prefix = binary_part(text, 0, size)
    if String.valid?(prefix), do: prefix, else: truncate(text, size - 1)
  end

  defp output(result) do
    case Jason.encode(result) do
      {:ok, json} when byte_size(json) <= @max_output -> {:ok, result}
      _ -> {:error, :output_limit}
    end
  end
end
