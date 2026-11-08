defmodule Synapsis.Workspace.DiffArtifacts do
  @moduledoc """
  Bounded, immutable Diffs artifact bytes, separate from permanent Workspace media.

  Descriptors contain relative paths. Callers retain the original canonical root
  and read bound privately. Publication syncs a same-directory temporary file and
  creates a no-replace hard link; it is not a transaction with metadata storage.
  Filesystem deadlines are checked between phases and cannot interrupt a blocked
  OS call. Ancestors and artifact entries must be real directories/regular files,
  never symlinks. Cleanup removes only the fixed artifact files and owned temps.
  """

  @max_bytes 32 * 1024 * 1024
  @formats %{"png" => "image/png", "pdf" => "application/pdf"}
  @files ~w(viewer.html.gz preview.png preview.pdf)

  @doc "Reads a renderer's bounded, hash-checked HTML receipt under its staging root."
  def read_staged(receipt, opts \\ [])

  def read_staged(receipt, opts) when is_map(receipt) and is_list(opts) do
    with true <- receipt["mimeType"] == "text/html; charset=utf-8",
         {:ok, settings} <- settings(Keyword.get(opts, :staging_root), opts),
         {:ok, path} <- relative_path(settings.root, receipt["path"]),
         {:ok, bytes} <- verified_read(path, receipt, settings) do
      {:ok, %{bytes: bytes, descriptor: receipt}}
    else
      false -> {:error, :invalid_receipt}
      error -> error
    end
  end

  def read_staged(_, _), do: {:error, :invalid_receipt}

  def put_viewer(root, id, html, opts \\ []) do
    with {:ok, settings} <- settings(root, opts),
         :ok <- valid_id(id),
         true <- is_binary(html) and byte_size(html) > 0,
         :ok <- size(html, settings.max_bytes),
         :ok <- active(settings),
         gzip = :zlib.gzip(html),
         :ok <- size(gzip, settings.max_bytes),
         descriptor =
           descriptor(id, "viewer", "html", "text/html; charset=utf-8", "viewer.html.gz", gzip),
         :ok <- publish(settings, id, "viewer.html.gz", gzip) do
      {:ok, Map.merge(descriptor, %{"encoding" => "gzip", "decodedBytes" => byte_size(html)})}
    else
      false -> {:error, :invalid_html}
      error -> error
    end
  end

  def put_file(root, id, format, receipt, opts \\ []) do
    with {:ok, settings} <- settings(root, opts),
         :ok <- valid_id(id),
         true <- is_map_key(@formats, format),
         true <- is_map(receipt),
         true <- receipt["mimeType"] == @formats[format],
         {:ok, staging} <- settings(Keyword.get(opts, :staging_root), opts),
         {:ok, path} <- relative_path(staging.root, receipt["path"]),
         {:ok, bytes} <- verified_read(path, receipt, staging),
         :ok <- file_type(bytes, format),
         name = "preview.#{format}",
         :ok <- publish(settings, id, name, bytes) do
      {:ok, descriptor(id, "file", format, @formats[format], name, bytes)}
    else
      false -> {:error, :invalid_file}
      error -> error
    end
  end

  def read(descriptor, opts \\ []) do
    with {:ok, settings} <- settings(Keyword.get(opts, :root), opts),
         :ok <- validate_descriptor(descriptor, settings),
         {:ok, path} <- relative_path(settings.root, descriptor["path"]),
         {:ok, stored} <- verified_read(path, descriptor, settings),
         {:ok, bytes} <- decode(stored, descriptor, settings),
         :ok <- active(settings) do
      {:ok, %{bytes: bytes, descriptor: descriptor}}
    end
  end

  def file_path(root, id, format) when is_binary(root) and is_map_key(@formats, format) do
    case valid_id(id) do
      :ok -> Path.join([root, id, "preview.#{format}"])
      error -> error
    end
  end

  def file_path(_, _, _), do: {:error, :invalid_path}

  def remove(root, id, opts \\ []) do
    with {:ok, settings} <- settings(root, opts),
         :ok <- valid_id(id),
         :ok <- directories(settings.root, false, settings),
         directory = Path.join(settings.root, id) do
      case File.lstat(directory) do
        {:error, :enoent} -> :ok
        {:ok, %{type: :directory}} -> remove_directory(directory, settings)
        {:ok, _} -> {:error, :invalid_path}
        error -> error
      end
    else
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @doc "Lists only source-shaped artifact directories; caller decides age and registration."
  def list_orphans(root, opts \\ []) do
    with {:ok, settings} <- settings(root, opts) do
      case directories(settings.root, false, settings) do
        :ok -> list_directories(settings)
        {:error, :enoent} -> {:ok, []}
        error -> error
      end
    end
  end

  defp list_directories(settings) do
    with {:ok, names} <- File.ls(settings.root),
         true <- length(names) <= 16_384 do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, found} ->
        with :ok <- active(settings) do
          case {valid_id(name), File.lstat(Path.join(settings.root, name), time: :posix)} do
            {:ok, {:ok, %{type: :directory, mtime: time}}} ->
              {:cont, {:ok, [%{public_id: name, modified_at: time * 1000} | found]}}

            {_, {:error, :enoent}} ->
              {:cont, {:ok, found}}

            {_, {:error, reason}} ->
              {:halt, {:error, reason}}

            _ ->
              {:cont, {:ok, found}}
          end
        else
          error -> {:halt, error}
        end
      end)
    else
      false -> {:error, :scan_limit}
      error -> error
    end
  end

  defp remove_directory(directory, settings) do
    with :ok <- directories(directory, false, settings),
         {:ok, names} <- File.ls(directory),
         true <- length(names) <= 16,
         {:ok, entries} <- removal_entries(directory, names, settings),
         true <-
           Enum.reduce(entries, 0, fn {_path, stat}, n -> n + stat.size end) <=
             settings.max_bytes * 2 do
      result =
        Enum.reduce_while(entries, :ok, fn {path, stat}, :ok ->
          with :ok <- active(settings),
               {:ok, current} <- File.lstat(path),
               true <- same_file?(stat, current),
               :ok <- File.rm(path) do
            {:cont, :ok}
          else
            false -> {:halt, {:error, :artifact_changed}}
            error -> {:halt, error}
          end
        end)

      with :ok <- result, :ok <- active(settings), do: File.rmdir(directory)
    else
      false -> {:error, :invalid_artifact_directory}
      error -> error
    end
  end

  defp removal_entries(directory, names, settings) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, entries} ->
      path = Path.join(directory, name)

      with :ok <- active(settings),
           true <- name in @files or Regex.match?(~r/\A\.diffs-[a-f0-9]{32}\.tmp\z/, name),
           {:ok, %{type: :regular} = stat} <- File.lstat(path),
           true <- stat.size <= settings.max_bytes do
        {:cont, {:ok, [{path, stat} | entries]}}
      else
        _ -> {:halt, {:error, :invalid_artifact_directory}}
      end
    end)
  end

  defp publish(settings, id, name, bytes) do
    with :ok <- active(settings),
         :ok <- directories(settings.root, true, settings),
         directory = Path.join(settings.root, id),
         :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- directories(directory, false, settings) do
      temporary =
        Path.join(
          directory,
          ".diffs-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}.tmp"
        )

      path = Path.join(directory, name)

      result =
        with :ok <- write_temporary(temporary, bytes, settings),
             :ok <- directories(directory, false, settings),
             :ok <- active(settings),
             :ok <- File.ln(temporary, path),
             :ok <- active(settings),
             do: :ok

      removed = File.rm(temporary)

      case {result, removed} do
        {:ok, :ok} -> :ok
        {:ok, error} -> error
        {error, _} -> error
      end
    end
  end

  defp write_temporary(path, bytes, settings) do
    with {:ok, file} <- File.open(path, [:write, :binary, :raw, :exclusive]) do
      result =
        with :ok <- active(settings),
             :ok <- :file.change_mode(path, 0o600),
             :ok <- :file.write(file, bytes),
             :ok <- active(settings),
             :ok <- :file.sync(file),
             do: active(settings)

      closed = File.close(file)
      with :ok <- result, :ok <- closed, do: :ok
    end
  end

  defp verified_read(path, receipt, settings) do
    with true <-
           is_integer(receipt["bytes"]) and receipt["bytes"] > 0 and
             receipt["bytes"] <= settings.max_bytes,
         true <- valid_hash?(receipt["sha256"]),
         :ok <- directories(Path.dirname(path), false, settings),
         :ok <- active(settings),
         {:ok, %{type: :regular} = original} <- File.lstat(path),
         true <- original.size == receipt["bytes"],
         {:ok, file} <- File.open(path, [:read, :raw, :binary]) do
      result =
        with :ok <- active(settings),
             {:ok, bytes} <- :file.read(file, settings.max_bytes + 1),
             :ok <- size(bytes, settings.max_bytes),
             {:ok, current} <- File.lstat(path),
             true <- same_file?(original, current),
             true <- byte_size(bytes) == receipt["bytes"] and hash(bytes) == receipt["sha256"],
             :ok <- active(settings),
             do: {:ok, bytes}

      closed = File.close(file)

      case {result, closed} do
        {{:ok, _} = ok, :ok} -> ok
        {false, _} -> {:error, :hash_mismatch}
        {:eof, _} -> {:error, :invalid_file}
        {{:error, _} = error, _} -> error
        {_, error} -> error
      end
    else
      false -> {:error, :invalid_receipt}
      {:ok, _} -> {:error, :invalid_path}
      error -> error
    end
  end

  defp decode(stored, %{"kind" => "viewer", "decodedBytes" => expected}, settings) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31)

      with {:ok, chunks} <- inflate(stream, stored, [], 0, settings),
           :ok <- :zlib.inflateEnd(stream),
           bytes = IO.iodata_to_binary(Enum.reverse(chunks)),
           true <- byte_size(bytes) == expected do
        {:ok, bytes}
      else
        false -> {:error, :decoded_size_mismatch}
        error -> error
      end
    catch
      :error, _ -> {:error, :invalid_gzip}
    after
      :zlib.close(stream)
    end
  end

  defp decode(stored, descriptor, _settings) do
    with :ok <- file_type(stored, descriptor["format"]), do: {:ok, stored}
  end

  defp inflate(stream, input, chunks, count, settings) do
    with :ok <- active(settings) do
      case :zlib.safeInflate(stream, input) do
        {status, output} when status in [:continue, :finished] ->
          count = count + IO.iodata_length(output)

          cond do
            count > settings.max_bytes -> {:error, :too_large}
            status == :finished -> {:ok, [output | chunks]}
            true -> inflate(stream, [], [output | chunks], count, settings)
          end

        _ ->
          {:error, :invalid_gzip}
      end
    end
  end

  defp validate_descriptor(descriptor, settings) when is_map(descriptor) do
    id = descriptor["artifactId"]
    kind = descriptor["kind"]
    format = descriptor["format"]

    {name, mime} =
      if kind == "viewer",
        do: {"viewer.html.gz", "text/html; charset=utf-8"},
        else:
          {Map.get(%{"png" => "preview.png", "pdf" => "preview.pdf"}, format), @formats[format]}

    with :ok <- valid_id(id),
         true <- descriptor["version"] == 1 and kind in ~w(viewer file) and is_binary(name),
         true <-
           descriptor["path"] == Path.join(id, name) and not is_nil(mime) and
             descriptor["mimeType"] == mime,
         true <-
           if(kind == "viewer",
             do:
               format == "html" and descriptor["encoding"] == "gzip" and
                 is_integer(descriptor["decodedBytes"]) and
                 descriptor["decodedBytes"] in 1..settings.max_bytes,
             else: format in ~w(png pdf)
           ) do
      :ok
    else
      _ -> {:error, :invalid_descriptor}
    end
  end

  defp validate_descriptor(_, _), do: {:error, :invalid_descriptor}

  defp descriptor(id, kind, format, mime, name, bytes) do
    %{
      "version" => 1,
      "kind" => kind,
      "artifactId" => id,
      "format" => format,
      "mimeType" => mime,
      "path" => Path.join(id, name),
      "bytes" => byte_size(bytes),
      "sha256" => hash(bytes)
    }
  end

  defp file_type(
         <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, _::binary>>,
         "png"
       )
       when width > 0 and height > 0,
       do: :ok

  defp file_type(<<"%PDF-", _::binary>> = bytes, "pdf") do
    if Regex.match?(~r/%%EOF[\x09\x0A\x0D\x20]*\z/, bytes),
      do: :ok,
      else: {:error, :invalid_file_type}
  end

  defp file_type(_, _), do: {:error, :invalid_file_type}

  defp settings(root, opts) when is_list(opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    deadline = Keyword.get(opts, :deadline, System.monotonic_time(:millisecond) + 30_000)

    if is_binary(root) and String.valid?(root) and not String.contains?(root, <<0>>) and
         Path.type(root) == :absolute and Path.expand(root) == root and
         is_integer(max_bytes) and max_bytes in 1..@max_bytes and is_integer(deadline) do
      {:ok, %{root: root, max_bytes: max_bytes, deadline: deadline}}
    else
      {:error, :invalid_options}
    end
  end

  defp settings(_, _), do: {:error, :invalid_options}

  defp relative_path(root, relative) when is_binary(relative) do
    if relative != "" and Path.type(relative) == :relative and
         not String.contains?(relative, <<0>>) and
         Enum.all?(String.split(relative, "/"), &(&1 not in ["", ".", ".."])) do
      {:ok, Path.join(root, relative)}
    else
      {:error, :invalid_path}
    end
  end

  defp relative_path(_, _), do: {:error, :invalid_path}

  defp directories(path, create?, settings) do
    Path.split(path)
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, parent} ->
      current = if parent == "", do: part, else: Path.join(parent, part)

      with :ok <- active(settings), :ok <- directory(current, create?) do
        {:cont, {:ok, current}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp directory(path, create?) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} when create? ->
        case File.mkdir(path) do
          :ok -> directory(path, false)
          {:error, :eexist} -> directory(path, false)
          error -> error
        end

      {:ok, _} ->
        {:error, :invalid_path}

      error ->
        error
    end
  end

  defp same_file?(a, b),
    do:
      b.type == :regular and a.inode == b.inode and a.major_device == b.major_device and
        a.minor_device == b.minor_device and a.size == b.size and a.mtime == b.mtime

  defp valid_id(id) when is_binary(id),
    do: if(Regex.match?(~r/\A[a-f0-9]{20}\z/, id), do: :ok, else: {:error, :invalid_artifact_id})

  defp valid_id(_), do: {:error, :invalid_artifact_id}
  defp valid_hash?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp hash(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp size(bytes, max_bytes),
    do: if(byte_size(bytes) <= max_bytes, do: :ok, else: {:error, :too_large})

  defp active(settings),
    do:
      if(System.monotonic_time(:millisecond) < settings.deadline,
        do: :ok,
        else: {:error, :timeout}
      )
end
