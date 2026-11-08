defmodule Synapsis.Filesystem.SnapshotMatcher do
  @moduledoc false

  @snapshot_key {__MODULE__, :snapshot}

  # This exported OTP compiler is marked doc-false. Keep its version-dependent
  # representation here, accepting known shapes explicitly rather than guessing
  # wildcard syntax or silently dropping unsupported literal prefixes.
  def literal_prefix(pattern) do
    case :filelib.compile_wildcard(String.to_charlist(pattern)) do
      {:compiled_wildcard, {{:exists, base}, prefix_length}}
      when is_list(base) and is_integer(prefix_length) and prefix_length >= 0 ->
        literal_base(base, :exact)

      {:compiled_wildcard, {[base | suffix], prefix_length}}
      when is_list(base) and is_list(suffix) and suffix != [] and
             is_integer(prefix_length) and prefix_length >= 0 ->
        literal_base(base, :wildcard)

      _ ->
        {:error, :unsupported_wildcard}
    end
  catch
    :error, {:badpattern, _} -> {:error, :invalid_pattern}
    :error, :undef -> {:error, :unsupported_wildcard}
  end

  defp literal_base(base, kind) do
    if Enum.all?(base, fn codepoint ->
         is_integer(codepoint) and codepoint >= 0 and codepoint <= 0x10FFFF and
           codepoint not in 0xD800..0xDFFF
       end) do
      case :unicode.characters_to_binary(base) do
        path when is_binary(path) -> {:ok, relative(path), kind}
        _ -> {:error, :unsupported_wildcard}
      end
    else
      {:error, :unsupported_wildcard}
    end
  end

  # filelib's callback module has no state argument. This temporary immutable
  # snapshot is matching data only: callbacks have no reader or I/O capability.
  def match(snapshot, pattern) do
    absent = make_ref()
    previous = Process.get(@snapshot_key, absent)
    Process.put(@snapshot_key, snapshot)

    try do
      paths = :filelib.wildcard(String.to_charlist(pattern), ~c".", __MODULE__)
      {:ok, Enum.map(paths, &relative/1)}
    catch
      :error, {:badpattern, _} -> {:error, :invalid_pattern}
    after
      if previous == absent,
        do: Process.delete(@snapshot_key),
        else: Process.put(@snapshot_key, previous)
    end
  end

  def read_file_info(path), do: read_link_info(path)

  def read_link_info(path) do
    case Map.fetch(Process.get(@snapshot_key).stats, relative(path)) do
      {:ok, stat} -> {:ok, stat}
      :error -> {:error, :enoent}
    end
  end

  def list_dir(path) do
    snapshot = Process.get(@snapshot_key)
    path = relative(path)

    case Map.fetch(snapshot.directories, path) do
      {:ok, names} ->
        {:ok,
         for(name <- names, not String.starts_with?(name, "."), do: String.to_charlist(name))}

      :error ->
        {:error, if(Map.has_key?(snapshot.stats, path), do: :enotdir, else: :enoent)}
    end
  end

  defp relative(path),
    do: Path.relative_to(Path.expand("/" <> IO.chardata_to_string(path)), "/")
end
