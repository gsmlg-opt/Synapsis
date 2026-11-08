defmodule Synapsis.Filesystem.Local do
  @moduledoc """
  Bounded real-filesystem operations, independent of tool dispatch and Workspace.

  Paths pass Backplane PathGuard and reject linked ancestry and hardlinks. Reads
  verify file identity around a bounded open. This is not an OS sandbox or an
  atomic openat/no-follow guarantee against hostile concurrent renames.

  Each operation has a five-second owner-monitored worker, a 10 MiB file limit,
  4,096 scanned entries, 200 returned legacy entries/lines and 32 KiB legacy read pages.
  `read_text/4` instead uses TextRead's 2,000-line/50 KiB text-page contract. Regex
  search runs on bounded regular-file content with PCRE match limits; it never
  grants or invokes a shell. Multi-edit authorizes every path before mutation,
  then retains per-file partial results rather than claiming a transaction.
  Mutation result budgets are reserved before writes. Interrupted workers return
  unknown outcomes with the guardian's known per-file completion evidence.
  If retirement remains unconfirmed after the explicit two-second cleanup grace,
  the caller receives an unknown cleanup outcome. The same guardian retains
  ownership and monitors until actual child exits; that return is not release.

  `edit_text/4` and `write_text/4` apply ordinary source-planned file effects and
  return source text envelopes after planner retirement and persisted readback.
  Physical-path admission is shared by participating callers on this BEAM node.
  Workspace owns integrated content/metadata persistence and publication through
  the explicit scope chain. Model-tool migration remains pending; these APIs do
  not introduce a second model tool surface. Direct `list_directory/4` pages use
  source ls semantics rather than the retained legacy list limits.
  """

  alias Backplane.AgentRuntime.Codex.PathGuard
  alias Synapsis.Filesystem.Access
  alias Synapsis.Filesystem.DirectoryList
  alias Synapsis.Filesystem.ReadContent
  alias Synapsis.Filesystem.SnapshotMatcher
  alias Synapsis.Filesystem.StateFile
  alias Synapsis.Filesystem.Planner.PortSession

  @actions ~w(file_read file_write file_edit multi_edit file_delete file_move list_dir grep glob)a
  @max_file 10 * 1_024 * 1_024
  @max_page 32_768
  @max_entries 4_096
  @max_output 262_144
  @write_diff_max_bytes 1_024 * 1_024
  @cleanup_grace 2_000
  @mutations ~w(file_write file_edit multi_edit file_delete file_move)a

  @doc "Starts a dormant, single-use state operation; the caller registers its guardian before run."
  def start_state_operation(root, path, opts \\ []) do
    now = System.monotonic_time(:millisecond)

    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) -- [:deadline, :owner_pid] == [],
         true <-
           text?(root, 4_096) and Path.type(root) == :absolute and Path.expand(root) == root,
         true <- valid_value?("path", path),
         deadline when is_integer(deadline) and deadline > now <- Keyword.get(opts, :deadline),
         owner when is_pid(owner) <- Keyword.get(opts, :owner_pid, self()),
         true <- owner == self(),
         :ok <- require_explicit_nested_scope() do
      ref = make_ref()
      deadline = min(deadline, now + 5_000)
      guardian = spawn(fn -> state_guard(owner, ref, deadline, root, path) end)
      {:ok, {__MODULE__, :state_operation, guardian, ref, deadline}}
    else
      _ -> {:error, :invalid_input}
    end
  end

  @doc "Returns the actual dormant or active state-operation guardian."
  def state_operation_owner({__MODULE__, :state_operation, guardian, ref, _deadline})
      when is_pid(guardian) and is_reference(ref),
      do: guardian

  def state_operation_owner(_), do: nil

  @doc "Activates one state operation after the caller's native resource registration."
  def run_state_operation(ticket, request) do
    if state_request?(request) do
      state_call(ticket, {:run, request}, :run)
    else
      {:error, :invalid_input}
    end
  end

  @doc "Reports live ownership evidence, without retaining a store after guardian exit."
  def state_operation_status(ticket), do: state_call(ticket, :status, :status)

  @doc "Confirms exact operation closure by acknowledgement and actual normal guardian exit."
  def close_state_operation(ticket), do: state_call(ticket, :close, :close)

  defp state_request?(:read_locked), do: true
  defp state_request?({:read_locked, callback}), do: is_function(callback, 1)

  defp state_request?({:write_always, bytes}),
    do: is_binary(bytes) and byte_size(bytes) <= @max_file

  defp state_request?({:transition_locked, callback}), do: is_function(callback, 1)
  defp state_request?(_), do: false

  defp state_call({__MODULE__, :state_operation, guardian, ref, deadline}, request, kind)
       when is_pid(guardian) and is_reference(ref) and is_integer(deadline) do
    monitor = Process.monitor(guardian)
    call_ref = make_ref()
    send(guardian, {ref, :state_call, self(), call_ref, request})

    timeout =
      if kind == :run, do: remaining(deadline) + @cleanup_grace + 100, else: @cleanup_grace

    receive do
      {^ref, ^call_ref, :closed} when kind == :close ->
        receive do
          {:DOWN, ^monitor, :process, ^guardian, :normal} -> :ok
          {:DOWN, ^monitor, :process, ^guardian, reason} -> {:uncertain, {:guardian_exit, reason}}
        after
          @cleanup_grace ->
            Process.demonitor(monitor, [:flush])
            {:uncertain, :guardian_retirement_pending}
        end

      {^ref, ^call_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^guardian, _reason} ->
        if kind == :close,
          do: {:uncertain, :missing_cleanup_ack},
          else: {:error, :retired_or_unavailable}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])

        if kind == :close,
          do: {:uncertain, :cleanup_pending},
          else:
            {:error, %{reason: :cleanup_pending, publication: :unknown, cleanup_confirmed: false}}
    end
  end

  defp state_call(_, _, :close), do: {:uncertain, :invalid_ticket}
  defp state_call(_, _, _), do: {:error, :invalid_ticket}

  @doc "Selects source path names under temporary admission, without capturing file bytes."
  def prepare_target(root, source_path, operation, path_environment, opts \\ []) do
    with true <- operation in [:read, :write, :edit, :ls],
         true <- valid_value?("path", source_path),
         true <- preparation_environment?(path_environment),
         true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline] == [],
         :ok <- require_explicit_nested_scope() do
      bounded(
        opts,
        fn context ->
          with {:ok, lease} <-
                 Access.reserve(context.guardian, context.deadline, context.access_server),
               {:ok, canonical_root, _} <- resolve(root, root) do
            probes = literal_target_probes(source_path, path_environment.cwd)
            sources = if probes == [], do: [source_path], else: [source_path, "./" <> source_path]

            # Keys are a finite lock-only superset, not authority to inspect unused
            # alternatives. The literal ancestor conservatively serializes its
            # descendants during selection. No lease survives this bounded call.
            keys =
              (probes ++
                 Enum.flat_map(sources, fn source ->
                   absolute = source_absolute(source, path_environment)

                   variants =
                     if operation == :read, do: read_target_variants(absolute, true), else: []

                   [absolute | variants]
                 end))
              |> Enum.map(&preparation_key(root, canonical_root, &1))
              |> Enum.uniq()
              |> Enum.sort()

            with :ok <- Access.acquire(lease, keys) do
              context =
                Map.merge(context, %{lease: lease, root: root, canonical_root: canonical_root})

              Process.put({__MODULE__, :scope}, context)

              with {:ok, source} <- preserve_literal_target(root, source_path, probes, context),
                   requested = source_absolute(source, path_environment),
                   {:ok, absolute, relative, prefix} <-
                     select_source_target(root, requested, operation, path_environment, context),
                   :ok <- operation_current() do
                {:ok,
                 %{
                   source_path: source,
                   requested_absolute: requested,
                   absolute_path: absolute,
                   relative_path: relative,
                   source_prefix: prefix
                 }}
              end
            end
          end
        end,
        nil,
        true
      )
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp preparation_environment?(%{cwd: cwd, os_home: home, platform: platform}) do
    platform in [:linux, :darwin, :win32] and trusted_absolute?(cwd) and
      Path.expand(cwd) == cwd and
      (is_nil(home) or (trusted_absolute?(home) and Path.expand(home) == home))
  end

  defp preparation_environment?(_), do: false

  defp preparation_key(root, canonical_root, absolute) do
    absolute = Path.expand(absolute)

    if absolute == root or String.starts_with?(absolute, String.trim_trailing(root, "/") <> "/"),
      do: Path.expand(Path.relative_to(absolute, root), canonical_root),
      else: absolute
  end

  # Adapted from OpenClaw 488631c path-policy.ts, sandbox-paths.ts and
  # sessions/tools/path-utils.ts/read.ts.
  # MIT License
  # Copyright (c) 2026 OpenClaw Foundation
  #
  # Permission is hereby granted, free of charge, to any person obtaining a copy
  # of this software and associated documentation files (the "Software"), to deal
  # in the Software without restriction, including without limitation the rights
  # to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  # copies of the Software, and to permit persons to whom the Software is
  # furnished to do so, subject to the following conditions:
  #
  # The above copyright notice and this permission notice shall be included in all
  # copies or substantial portions of the Software.
  #
  # THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  # IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  # FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  # AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  # LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  # OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  # SOFTWARE.
  @doc "Checks whether literal source selection may preserve an @ path with a ./ prefix."
  def literal_target_repair_eligible?("@" <> stripped) do
    bypass =
      stripped in ["", "~"] or String.starts_with?(stripped, ["~/", "~\\"]) or
        Regex.match?(~r/^file:\/\//i, stripped) or Path.type(stripped) == :absolute or
        Regex.match?(~r/^(?:[A-Za-z]:[\\\/]|\\\\|\/\\)/, stripped)

    not bypass
  end

  def literal_target_repair_eligible?(_source), do: false

  defp literal_target_probes(source, cwd) do
    if literal_target_repair_eligible?(source) do
      ancestor = literal_target_ancestor(source)
      Enum.uniq([Path.expand("./" <> source, cwd), Path.expand("./" <> ancestor, cwd)])
    else
      []
    end
  end

  defp literal_target_ancestor(path) do
    parent = Path.dirname(path)
    if parent in [".", path], do: path, else: literal_target_ancestor(parent)
  end

  defp preserve_literal_target(root, source, probes, context) do
    Enum.reduce_while(probes, {:ok, source}, fn path, _result ->
      with {:ok, absolute, _} <- preparation_resolve(root, path, context),
           :ok <- operation_current() do
        case File.lstat(absolute) do
          {:ok, _} -> {:halt, {:ok, "./" <> source}}
          {:error, reason} when reason in [:enoent, :enotdir] -> {:cont, {:ok, source}}
          error -> {:halt, normalize(error)}
        end
      else
        {:error, reason} when reason in [:enoent, :enotdir] -> {:cont, {:ok, source}}
        error -> {:halt, error}
      end
    end)
  end

  defp source_absolute(source, environment) do
    normalized =
      case source do
        "@@" <> rest -> "./@" <> rest
        "@" <> rest -> rest
        _ -> source
      end

    expanded =
      if String.starts_with?(normalized, "file://"),
        do: source_file_url(normalized),
        else: source_home(normalized, environment)

    if Path.type(expanded) == :absolute,
      do: expanded,
      else: Path.expand(expanded, environment.cwd)
  end

  defp source_home(path, %{os_home: nil}), do: path
  defp source_home("~", %{os_home: home}), do: home
  defp source_home("~/" <> rest, %{os_home: home}), do: home <> "/" <> rest

  defp source_home("~\\" <> rest, %{os_home: home, platform: :win32}),
    do: home <> "/" <> rest

  defp source_home(path, _environment), do: path

  defp source_file_url(source) do
    uri = URI.parse(source)
    path = uri.path || ""

    if uri.scheme == "file" and String.downcase(uri.host || "") in ["", "localhost"] and
         is_nil(uri.userinfo) and is_nil(uri.port) and String.starts_with?(path, "/") and
         not Regex.match?(~r/%2f/i, path) and not Regex.match?(~r/%(?![0-9a-f]{2})/i, path) do
      decoded = URI.decode(path)
      if String.valid?(decoded), do: decoded, else: source
    else
      source
    end
  rescue
    ArgumentError -> source
  end

  defp read_target_variants(path, include_nfd) do
    name = Path.basename(path)
    parent = binary_part(path, 0, byte_size(path) - byte_size(name))
    spaced = String.replace(name, ~r/[\x{00A0}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}]/u, " ")
    screenshot = String.replace(spaced, ~r/ (?=(?:AM|PM)(?:\b|\.))/i, "\u202F")

    for spaces <- [spaced, screenshot],
        quotes <- [String.replace(spaces, ~r/[‘’]/u, "'"), String.replace(spaces, ~r/['‘]/u, "’")],
        form <- if(include_nfd, do: [:nfc, :nfd], else: [:nfc]) do
      parent <> String.normalize(quotes, form)
    end
    |> Enum.uniq()
    |> Enum.reject(&(&1 == path))
  end

  defp preparation_resolve(root, path, context) do
    key = preparation_key(context.root, context.canonical_root, path)

    with :ok <- check_targets(context, [%{absolute: key}]),
         {:ok, absolute, relative} <- preparation_guard(root, path),
         :ok <- check_targets(context, [%{absolute: absolute}]),
         :ok <- operation_current() do
      {:ok, absolute, relative}
    end
  end

  # Keep resolve/2's guards; retain missing-path causes for source fallback only.
  defp preparation_guard(root, path) do
    with true <- text?(path, 4_096),
         false <- String.contains?(path, ["\\", "\0"]),
         false <- ".." in Path.split(path),
         {:ok, canonical_root} <- PathGuard.authorize(root, root),
         {:ok, absolute} <- PathGuard.authorize(root, path),
         :ok <- ancestry(canonical_root, absolute) do
      {:ok, absolute, Path.relative_to(absolute, canonical_root)}
    else
      false ->
        {:error, :invalid_input}

      true ->
        {:error, :unsafe_path}

      {:error, %Backplane.AgentRuntime.Error{cause: reason}} when reason in [:enoent, :enotdir] ->
        {:error, reason}

      {:error, %Backplane.AgentRuntime.Error{}} ->
        {:error, :unsafe_path}

      error ->
        error
    end
  end

  defp select_source_target(root, requested, operation, _environment, context)
       when operation in [:write, :edit, :ls] do
    with {:ok, absolute, relative} <- preparation_resolve(root, requested, context),
         do: {:ok, absolute, relative, ""}
  end

  defp select_source_target(root, requested, :read, environment, context) do
    case readable_target(root, requested, context) do
      {:ok, absolute, relative} ->
        {:ok, absolute, relative, ""}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        requested
        |> read_target_variants(environment.platform != :darwin)
        |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, matches} ->
          case readable_target(root, candidate, context) do
            {:ok, absolute, relative} -> {:cont, {:ok, matches ++ [{absolute, relative}]}}
            {:error, reason} when reason in [:enoent, :enotdir] -> {:cont, {:ok, matches}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, [{absolute, relative}]} ->
            prefix =
              "[Resolved filename: #{Path.basename(requested)} -> #{Path.basename(absolute)}.]\n"

            {:ok, absolute, relative, prefix}

          {:ok, []} ->
            {:error, :not_found}

          {:ok, _matches} ->
            {:error, :ambiguous_path}

          error ->
            error
        end

      error ->
        error
    end
  end

  defp readable_target(root, path, context) do
    with {:ok, absolute, relative} <- preparation_resolve(root, path, context),
         {:ok, stat} <- File.stat(absolute),
         :ok <- operation_current() do
      cond do
        stat.type != :regular -> {:error, :not_regular}
        stat.access not in [:read, :read_write] -> {:error, :permission_denied}
        true -> {:ok, absolute, relative}
      end
    end
  end

  @doc "Runs a trusted callback under one complete, guardian-owned physical path lease."
  def with_paths(root, paths, opts, fun) when is_function(fun, 1) do
    if scope_options?(opts) and is_list(paths) and paths != [] and
         length(paths) <= @max_entries and Enum.all?(paths, &valid_value?("path", &1)) do
      scoped(root, paths, opts, fn context ->
        fun.(lease: context.lease, deadline: context.deadline)
      end)
    else
      {:error, :invalid_input}
    end
  end

  defp scope_options?(opts),
    do: Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :lease] == []

  @doc "Checks an explicit scope against its original worker, guardian and deadline."
  def check_scope(opts) do
    with true <- scope_options?(opts),
         {:ok, lease} <- Keyword.fetch(opts, :lease),
         {:ok, _context} <- scope_context(lease, opts),
         :ok <- operation_current() do
      :ok
    else
      false -> {:error, :invalid_input}
      :error -> {:error, :invalid_lease}
      error -> error
    end
  end

  @doc "Captures actual millisecond stat facts and JS locale ordering under one admitted path."
  def precise_metadata(root, admitted_path, files, names, opts \\ []) do
    scope_opts = Keyword.drop(opts, [:observer_pid])

    if scope_options?(scope_opts) and
         Keyword.keys(opts) -- [:deadline, :lease, :observer_pid] == [] and
         is_list(files) and is_list(names) and
         Enum.all?(names, &(is_binary(&1) and String.valid?(&1))) and
         (not Keyword.has_key?(opts, :observer_pid) or is_pid(opts[:observer_pid])) do
      scoped(root, [admitted_path], scope_opts, fn context ->
        Synapsis.Filesystem.PreciseMetadata.capture(
          context,
          root,
          admitted_path,
          files,
          names,
          opts
        )
      end)
    else
      {:error, :invalid_input}
    end
  end

  @doc "A bounded ordinary-file index for domain projection merging, before pagination."
  def index(root, path, depth, opts \\ []) when is_integer(depth) and depth in 1..10 do
    if scope_options?(opts) do
      scoped(root, [path], opts, fn _context ->
        with {:ok, absolute, relative} <- resolve(root, path),
             {:ok, stat} <- File.lstat(absolute) do
          if stat.type == :regular,
            do: {:ok, [%{path: relative, type: "file"}]},
            else: scan(root, path, depth)
        else
          error -> normalize(error)
        end
      end)
    else
      {:error, :invalid_input}
    end
  end

  @doc "Applies the filesystem worker budget to a domain's merged enumeration."
  def enumerate(fun) when is_function(fun, 0), do: bounded([], fun)

  @doc "Reads bounded binary bytes through the same checked, owner-monitored file reader."
  def read_binary(root, path, opts \\ []) do
    with true <-
           Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :lease, :max_bytes] == [],
         limit = Keyword.get(opts, :max_bytes, @max_file),
         true <- is_integer(limit) and limit in 1..@max_file do
      scoped(root, [path], opts, fn _context -> read(root, path, limit, false) end)
    else
      _ -> {:error, :invalid_input}
    end
  end

  @doc "Captures guarded bytes, retires capture, then prepares a source read result."
  def read_file(root, path, args, opts \\ []) do
    with true <-
           valid_value?("path", path) and read_file_args?(args) and read_file_options?(opts),
         {:ok, deadline} <- read_file_deadline(opts) do
      # This standalone capture deliberately accepts no caller lease. Normal
      # read_binary return follows actual worker/guardian retirement, releasing
      # its path admission before any decoder/classifier/codec work starts.
      case read_binary(root, path, deadline: deadline) do
        {:ok, bytes, _relative} ->
          ReadContent.prepare(
            bytes,
            Map.delete(args, "optional"),
            Keyword.put(opts, :deadline, deadline)
          )

        {:error, reason} when reason in [:not_found, :enoent, :enotdir] ->
          if args["optional"] == true do
            {:ok,
             %{
               content: [%{type: "text", text: "Optional file not found: #{path}."}],
               details: %{kind: "not_found", status: "not_found", path: path, optional: true}
             }}
          else
            {:error, reason}
          end

        error ->
          error
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp read_file_args?(args) do
    is_map(args) and not is_struct(args) and
      Map.keys(args) -- ~w(offset cursor limit optional) == [] and
      Enum.all?(args, fn
        {"offset", n} -> is_integer(n) and n >= 1 and n <= 9_007_199_254_740_991
        {"cursor", n} -> is_integer(n) and n >= 0 and n <= 9_007_199_254_740_991
        {"limit", n} -> is_number(n)
        {"optional", optional} -> is_boolean(optional)
      end)
  end

  defp read_file_options?(opts) do
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
        ] == [] and trusted_absolute?(Keyword.get(opts, :node_executable)) and
      Enum.all?(opts, &read_file_option?/1)
  end

  defp read_file_option?({name, path}) when name in [:node_executable, :helper_path],
    do: trusted_absolute?(path)

  defp read_file_option?({:observer_pid, pid}), do: is_pid(pid)
  defp read_file_option?({:deadline, deadline}), do: is_integer(deadline)
  defp read_file_option?({:prefix, prefix}), do: is_binary(prefix) and String.valid?(prefix)

  defp read_file_option?({:max_bytes, n}),
    do: is_integer(n) and n > 0 and n <= 9_007_199_254_740_991

  defp read_file_option?({:model_budget, nil}), do: true

  defp read_file_option?({:model_budget, %{maxChars: chars, maxContextChars: context} = budget}),
    do:
      not is_struct(budget) and map_size(budget) == 2 and is_number(chars) and
        is_number(context) and chars >= 0 and context >= 0

  defp read_file_option?({name, value}) when name in [:model_has_vision, :auto_resize_images],
    do: is_boolean(value)

  defp read_file_option?({:decode_mode, mode}), do: mode in [:local, :utf8]

  defp read_file_option?({:windows_encoding, encoding}),
    do:
      is_binary(encoding) and String.valid?(encoding) and String.trim(encoding) != "" and
        not String.contains?(encoding, "\0")

  defp read_file_option?(_), do: false

  defp read_file_deadline(opts) do
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + 5_000)

    if deadline > now and deadline <= now + 5_000,
      do: {:ok, deadline},
      else: {:error, :invalid_deadline}
  end

  @doc "Writes bounded binary bytes with guarded snapshot verification and readback."
  def write_binary(root, path, bytes, opts \\ []) do
    if scope_options?(opts) and valid_value?("path", path) and is_binary(bytes) and
         byte_size(bytes) <= @max_file do
      scoped(
        root,
        [path],
        opts,
        fn _context ->
          with {:ok, absolute, relative} <- resolve(root, path),
               {:ok, previous} <- existing_binary(root, path) do
            status =
              cond do
                previous == bytes -> "unchanged"
                is_nil(previous) -> "created"
                true -> "updated"
              end

            result = %{path: relative, status: status, bytes: byte_size(bytes)}

            with :ok <- result_budget(result),
                 :ok <- write(root, path, absolute, bytes, previous) do
              if status == "unchanged", do: record_file(absolute, result)
              {:ok, result}
            end
          end
        end,
        source_mutation(root, :file_write, path)
      )
    else
      {:error, :invalid_input}
    end
  end

  @doc "Captures a bounded directory index and independently selected binary files."
  def directory_snapshot(root, directory, selection, opts \\ []) do
    with true <- scope_options?(opts),
         {:ok, selection} <- snapshot_selection(selection) do
      scoped(root, [directory], opts, fn _context ->
        with {:ok, absolute, relative} <- resolve(root, directory),
             {:ok, stat} <- File.lstat(absolute, time: :posix),
             true <- stat.type == :directory,
             {:ok, snapshot} <- capture_snapshot(root, relative, stat, selection),
             {:ok, paths} <- SnapshotMatcher.match(snapshot, selection.pattern),
             {:ok, files} <- snapshot_files(root, relative, snapshot, selection.read_patterns),
             :ok <- operation_current() do
          entries =
            paths
            |> Enum.reject(&snapshot_excluded?(&1, selection.exclude))
            |> Enum.map(fn path ->
              %{path: snapshot_path(relative, path), type: snapshot.entries[path]}
            end)

          {:ok, %{entries: entries, files: files}}
        else
          false -> {:error, :not_directory}
          error -> normalize(error)
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Captures direct names and actual directory flags without opening child targets."
  def directory_entries(root, path, opts \\ []) do
    if scope_options?(opts) and valid_value?("path", path) do
      scoped(root, [path], opts, fn _context -> capture_direct_entries(root, path) end)
    else
      {:error, :invalid_input}
    end
  end

  @doc "Captures and renders a source ls page within one original bounded scope."
  def list_directory(root, path, args, opts \\ []) do
    with true <-
           Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:deadline, :lease, :model_budget] == [] and
             valid_value?("path", path),
         page_opts = Keyword.take(opts, [:model_budget]),
         :ok <- DirectoryList.validate(args, page_opts) do
      scoped(root, [path], opts, fn _context ->
        with {:ok, entries} <- capture_direct_entries(root, path),
             :ok <- operation_current(),
             {:ok, result} <- DirectoryList.page(entries, args, page_opts),
             :ok <- operation_current() do
          {:ok, result}
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Reads and pages a checked UTF-8 snapshot inside the existing bounded worker."
  def read_text(root, path, args, opts \\ []) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:deadline, :lease, :prefix, :max_bytes, :model_budget] == [] do
      scoped(root, [path], opts, fn _context ->
        with {:ok, snapshot, _relative} <- read(root, path) do
          Synapsis.Filesystem.TextRead.page(
            snapshot,
            args,
            Keyword.drop(opts, [:deadline, :lease])
          )
        end
      end)
    else
      {:error, :invalid_input}
    end
  end

  @doc "Applies one original-snapshot source edit plan to a guarded UTF-8 file."
  def edit_text(root, path, edits, opts \\ []) do
    with :ok <- planner_options_valid(opts),
         true <- valid_value?("path", path) and source_edits?(edits) do
      display_path = Keyword.get(opts, :display_path, path)

      scoped(
        root,
        [path],
        opts,
        fn context ->
          with {:ok, absolute, relative} <- resolve(root, path),
               {:ok, content, ^relative} <- read(root, path),
               {:ok, plan} <-
                 source_plan(context, opts, "edit", %{
                   "path" => display_path,
                   "content" => content,
                   "edits" => edits
                 }) do
            if plan["changed"] do
              result =
                text_result(
                  "Successfully replaced #{plan["editCount"]} block(s) in #{display_path}.",
                  Map.put(source_receipt(plan["receipt"]), :changed, true)
                )

              with :ok <- result_budget(result),
                   :ok <- persist(root, path, absolute, plan["content"], content) do
                {:ok, result}
              end
            else
              result = text_result(plan["message"], %{changed: false})
              with :ok <- result_budget(result), do: {:ok, result}
            end
          end
        end,
        source_mutation(root, :file_edit, path)
      )
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc "Writes UTF-8 bytes with source no-op/diff semantics and guarded persisted readback."
  def write_text(root, path, content, opts \\ []) do
    with :ok <- planner_options_valid(opts),
         true <- valid_value?("path", path) and valid_value?("content", content),
         true <- byte_size(content) <= @max_file do
      display_path = Keyword.get(opts, :display_path, path)

      scoped(
        root,
        [path],
        opts,
        fn context ->
          with {:ok, absolute, _relative} <- resolve(root, path),
               {:ok, previous} <- existing_binary(root, path) do
            if previous == content and byte_size(content) <= @write_diff_max_bytes do
              result =
                text_result(
                  "No changes made to #{display_path}. The file already has identical content.",
                  %{changed: false}
                )

              with :ok <- result_budget(result), do: {:ok, result}
            else
              with {:ok, receipt} <- write_receipt(context, opts, display_path, content, previous) do
                result =
                  text_result(
                    "Successfully wrote #{byte_size(content)} bytes to #{display_path}",
                    Map.merge(receipt, %{changed: true, created: is_nil(previous)})
                  )

                # Source writes over the diff threshold must persist even when the
                # bytes happen to match. Do not use the legacy write no-op clause.
                with :ok <- result_budget(result),
                     :ok <- persist(root, path, absolute, content, previous) do
                  {:ok, result}
                end
              end
            end
          end
        end,
        source_mutation(root, :file_write, path)
      )
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp planner_options_valid(opts) do
    if Keyword.keyword?(opts) and
         Keyword.keys(opts) --
           [:node_executable, :helper_path, :observer_pid, :deadline, :lease, :display_path] ==
           [] and
         trusted_absolute?(Keyword.get(opts, :node_executable)) and
         (not Keyword.has_key?(opts, :helper_path) or
            trusted_absolute?(Keyword.get(opts, :helper_path))) and
         (not Keyword.has_key?(opts, :observer_pid) or is_pid(Keyword.get(opts, :observer_pid))) and
         (not Keyword.has_key?(opts, :display_path) or
            valid_value?("path", Keyword.get(opts, :display_path))),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp trusted_absolute?(path),
    do: text?(path, 4_096) and Path.type(path) == :absolute and not String.contains?(path, "\0")

  defp source_edits?(edits) do
    is_list(edits) and length(edits) in 1..200 and
      Enum.all?(edits, fn edit ->
        is_map(edit) and not is_struct(edit) and
          Enum.sort(Map.keys(edit)) == ["newText", "oldText"] and
          Enum.all?([edit["oldText"], edit["newText"]], fn text ->
            is_binary(text) and String.valid?(text) and byte_size(text) <= @max_file
          end)
      end)
  end

  defp source_mutation(root, action, path),
    do: mutation_state(action, mutation_paths(root, [path]))

  defp text_result(message, details),
    do: %{content: [%{type: "text", text: message}], details: details}

  defp result_budget(result) do
    # The exact receipt is known before effects. Include interruption evidence's
    # existing reserve rather than accepting an unbounded planner receipt.
    if byte_size(Jason.encode!(result)) + 256 <= @max_output,
      do: :ok,
      else: {:error, :output_limit}
  end

  defp source_receipt(nil), do: %{}

  defp source_receipt(receipt) do
    Enum.reduce(
      [{"diff", :diff}, {"patch", :patch}, {"firstChangedLine", :firstChangedLine}],
      %{},
      fn
        {source, target}, fields ->
          case Map.fetch(receipt, source) do
            {:ok, value} -> Map.put(fields, target, value)
            :error -> fields
          end
      end
    )
  end

  defp write_receipt(_context, _opts, _path, content, _previous)
       when byte_size(content) > @write_diff_max_bytes,
       do: {:ok, %{}}

  defp write_receipt(context, opts, path, content, previous) do
    input = %{"path" => path, "content" => content, "created" => is_nil(previous)}

    input =
      if is_binary(previous) and byte_size(previous) <= @write_diff_max_bytes and
           String.valid?(previous),
         do: Map.put(input, "beforeText", previous),
         else: input

    with {:ok, receipt} <- source_plan(context, opts, "write_diff", input),
         do: {:ok, source_receipt(receipt)}
  end

  defp source_plan(context, opts, operation, input) do
    helper =
      Keyword.get_lazy(opts, :helper_path, fn ->
        Path.join(:code.priv_dir(:synapsis_core), "filesystem_planner/stdio.mjs")
      end)

    broker_opts = [
      node_executable: Keyword.fetch!(opts, :node_executable),
      helper_path: helper,
      owner_pid: context.guardian,
      caller_pid: self(),
      notification: {context.guardian, context.ref}
    ]

    broker_opts =
      if Keyword.has_key?(opts, :observer_pid),
        do: Keyword.put(broker_opts, :observer_pid, Keyword.fetch!(opts, :observer_pid)),
        else: broker_opts

    with :ok <- operation_current(),
         {:ok, broker} <- PortSession.start_link(broker_opts) do
      monitor = Process.monitor(broker)
      ack_ref = make_ref()
      send(context.guardian, {context.ref, :planner_register, self(), broker, ack_ref})

      planned =
        receive do
          {:planner_registered, ^ack_ref} ->
            request = %{
              "protocol" => 1,
              "id" =>
                "local:" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
              "operation" => operation,
              "input" => input
            }

            PortSession.plan(broker, request, context.deadline)
        after
          remaining(context.deadline) -> {:error, :timeout}
        end

      # A result frame cannot authorize a write until the actual Port is closed
      # and the broker has normally retired. The guardian independently observes
      # settlement and DOWN for every registered broker.
      retired = retire_planner(broker, monitor, context.deadline)

      with {:ok, envelope} <- planned,
           :ok <- retired,
           :ok <- operation_current() do
        {:ok, envelope["result"]}
      end
    end
  end

  defp retire_planner(broker, monitor, deadline) do
    status = PortSession.status(broker)

    with {:ok, ^status} <- PortSession.close(broker) do
      receive do
        {:DOWN, ^monitor, :process, ^broker, :normal} ->
          if planner_completed?(status), do: :ok, else: {:error, :planner_failed}

        {:DOWN, ^monitor, :process, ^broker, _} ->
          {:error, :planner_failed}
      after
        remaining(deadline) -> {:error, :timeout}
      end
    end
  end

  defp planner_completed?(%{
         phase: :settled,
         outcome: :completed,
         cleanup_confirmed: true,
         exit_status: 0,
         port_released: true,
         port: port
       })
       when is_port(port),
       do: Port.info(port) == nil

  defp planner_completed?(_), do: false

  @doc "Searches full guarded file content without exposing an unbounded reader."
  def search_file(root, path, pattern, opts \\ []) do
    if scope_options?(opts) do
      scoped(root, [path], opts, fn _context ->
        with {:ok, content, relative} <- read(root, path),
             {:ok, regex} <- compile_regex(pattern),
             {:ok, matches} <- matching_lines(content, regex, relative) do
          {:ok, %{matches: matches, bytes: byte_size(content)}}
        end
      end)
    else
      {:error, :invalid_input}
    end
  end

  @doc "Searches already materialized domain content under the same regex and file limits."
  def search_content(content, path, pattern) do
    with true <-
           is_binary(content) and String.valid?(content) and byte_size(content) <= @max_file,
         {:ok, regex} <- compile_regex(pattern) do
      bounded([], fn -> matching_lines(content, regex, path) end)
    else
      false -> {:error, :file_limit}
      error -> error
    end
  end

  @doc "Filters an already bounded domain index without traversing the filesystem."
  def glob_paths(paths, pattern) do
    with {:ok, regex} <- glob_regex(pattern),
         do: {:ok, Enum.filter(paths, &Regex.match?(regex, &1))}
  end

  @doc "Pages an already materialized domain projection using the same text budgets."
  def page_content(content, path, args) do
    with :ok <- validate(:file_read, Map.put(args, "path", path)),
         true <- is_binary(content) and String.valid?(content) and byte_size(content) <= @max_file do
      {:ok, page(content, path, Map.get(args, "offset", 0), Map.get(args, "limit", 200))}
    else
      false -> {:error, :file_limit}
      error -> error
    end
  end

  def perform(root, action, arguments, opts \\ []) do
    with :ok <- validate(action, arguments),
         true <- scope_options?(opts) do
      paths = action_paths(action, arguments)

      scoped(
        root,
        paths,
        opts,
        fn _context ->
          with {:ok, targets} <- targets(root, action, arguments),
               :ok <- mutation_budget(action, targets),
               {:ok, result} <- run(root, action, arguments),
               true <- byte_size(Jason.encode!(result)) <= @max_output do
            {:ok, result}
          else
            false -> {:error, :output_limit}
            error -> error
          end
        end,
        mutation_state(action, mutation_paths(root, paths))
      )
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp mutation_state(action, targets) when action in @mutations do
    %{
      status: "unknown_outcome",
      action: Atom.to_string(action),
      files:
        targets
        |> Enum.uniq_by(& &1.path)
        |> Enum.map(&%{path: &1.path, status: "unknown_outcome"})
    }
  end

  defp mutation_state(_action, _targets), do: nil

  # Pure path normalization supplies interruption evidence before the guardian is
  # started; physical authorization/resolution still happens only after reserve.
  defp mutation_paths(root, paths) do
    Enum.map(paths, fn path ->
      relative =
        if is_binary(root) and Path.type(root) == :absolute,
          do: Path.relative_to(Path.expand(path, root), root),
          else: path

      %{path: relative}
    end)
  end

  defp mutation_budget(action, targets) when action in @mutations do
    evidence_budget(mutation_state(action, targets))
  end

  defp mutation_budget(_action, _targets), do: :ok

  defp evidence_budget(nil), do: :ok

  defp evidence_budget(result) do
    # Reserve for every canonical result, interruption evidence and Workspace
    # metadata uncertainty before any mutation can run. Paths dominate this cap.
    files =
      Enum.map(
        result.files,
        &Map.merge(&1, %{
          status: String.duplicate("x", 64),
          bytes: @max_file,
          metadata_status: String.duplicate("x", 64)
        })
      )

    if byte_size(Jason.encode!(%{result | files: files})) + 256 <= @max_output,
      do: :ok,
      else: {:error, :output_limit}
  end

  @doc "Validates the domain action shape without reading content or performing effects."
  def validate(action, args) when action in @actions and is_map(args) and not is_struct(args) do
    {allowed, required} = fields(action)

    if Map.keys(args) -- allowed == [] and Enum.all?(required, &Map.has_key?(args, &1)) and
         Enum.all?(args, fn {key, value} -> valid_value?(key, value) end),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate(_, _), do: {:error, :invalid_input}

  @doc "Returns a canonical guarded path and its project-relative identity."
  def resolve(root, path) do
    with true <-
           text?(root, 4_096) and Path.type(root) == :absolute and Path.expand(root) == root,
         true <- text?(path, 4_096),
         false <- String.contains?(path, ["\\", "\0"]),
         false <- ".." in Path.split(path),
         {:ok, canonical_root} <- PathGuard.authorize(root, root),
         {:ok, absolute} <- PathGuard.authorize(root, path),
         :ok <- ancestry(canonical_root, absolute) do
      {:ok, absolute, Path.relative_to(absolute, canonical_root)}
    else
      false -> {:error, :invalid_input}
      true -> {:error, :unsafe_path}
      {:error, %Backplane.AgentRuntime.Error{}} -> {:error, :unsafe_path}
      error -> error
    end
  end

  @doc "Checks every resource touched by an action before any mutation."
  def targets(root, action, args) do
    with :ok <- validate(action, args) do
      resolve_paths(root, action_paths(action, args))
    end
  end

  defp action_paths(:file_move, args), do: [args["source"], args["destination"]]
  defp action_paths(:multi_edit, args), do: Enum.map(args["edits"], & &1["path"])
  defp action_paths(_action, args), do: [Map.get(args, "path", ".")]

  defp resolve_paths(root, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, targets} ->
      case resolve(root, path) do
        {:ok, absolute, relative} ->
          {:cont, {:ok, targets ++ [%{absolute: absolute, path: relative}]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp fields(:file_read), do: {["path", "offset", "limit"], ["path"]}
  defp fields(:file_write), do: {["path", "content"], ["path", "content"]}

  defp fields(:file_edit),
    do: {["path", "old_string", "new_string"], ["path", "old_string", "new_string"]}

  defp fields(:multi_edit), do: {["edits"], ["edits"]}
  defp fields(:file_delete), do: {["path"], ["path"]}
  defp fields(:file_move), do: {["source", "destination"], ["source", "destination"]}
  defp fields(:list_dir), do: {["path", "depth", "offset", "limit"], ["path"]}
  defp fields(:grep), do: {["path", "pattern", "include", "offset", "limit"], ["pattern"]}
  defp fields(:glob), do: {["path", "pattern", "offset", "limit"], ["pattern"]}

  defp valid_value?(key, value)
       when key in ["path", "source", "destination", "include", "pattern"],
       do: text?(value, 4_096) and not String.contains?(value, "\0")

  defp valid_value?("content", value), do: is_binary(value) and String.valid?(value)
  defp valid_value?("old_string", value), do: text?(value, @max_file)

  defp valid_value?("new_string", value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= @max_file

  defp valid_value?("offset", value), do: is_integer(value) and value in 0..100_000
  defp valid_value?("limit", value), do: is_integer(value) and value in 1..200
  defp valid_value?("depth", value), do: is_integer(value) and value in 1..10

  defp valid_value?("edits", value),
    do:
      is_list(value) and length(value) <= 200 and
        Enum.all?(value, &(validate(:file_edit, &1) == :ok))

  defp valid_value?(_, _), do: false

  defp text?(value, max),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..max

  defp ancestry(root, path) do
    relative = Path.relative_to(path, root)
    segments = if relative == ".", do: [], else: Path.split(relative)

    Enum.reduce_while([root | segments], {:ok, nil}, fn segment, {:ok, previous} ->
      current = if previous, do: Path.join(previous, segment), else: segment

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, {:error, :unsafe_path}}
        {:ok, %{type: :regular, links: links}} when links > 1 -> {:halt, {:error, :unsafe_path}}
        {:ok, _} -> {:cont, {:ok, current}}
        {:error, :enoent} -> {:cont, {:ok, current}}
        {:error, _} -> {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp run(root, :file_read, args) do
    with {:ok, content, path} <- read(root, args["path"]) do
      {:ok, page(content, path, Map.get(args, "offset", 0), Map.get(args, "limit", 200))}
    end
  end

  defp run(root, :file_write, args) do
    with true <- byte_size(args["content"]) <= @max_file,
         {:ok, absolute, relative} <- resolve(root, args["path"]),
         {:ok, previous} <- existing(root, args["path"]),
         :ok <- write(root, args["path"], absolute, args["content"], previous) do
      status =
        cond do
          previous == args["content"] -> "unchanged"
          is_nil(previous) -> "created"
          true -> "updated"
        end

      {:ok, %{status: status, path: relative, bytes: byte_size(args["content"])}}
    else
      false -> {:error, :file_limit}
      error -> error
    end
  end

  defp run(root, :file_edit, args) do
    with {:ok, content, relative} <- read(root, args["path"]),
         {:ok, edited} <- replace(content, args),
         {:ok, absolute, ^relative} <- resolve(root, args["path"]),
         :ok <- write(root, args["path"], absolute, edited, content) do
      {:ok,
       %{
         status: if(edited == content, do: "unchanged", else: "updated"),
         path: relative,
         bytes: byte_size(edited)
       }}
    end
  end

  defp run(root, :multi_edit, args) do
    with {:ok, targets} <- targets(root, :multi_edit, args) do
      files =
        Enum.zip(args["edits"], targets)
        |> Enum.group_by(fn {_edit, target} -> {target.path, target.absolute} end, fn {edit,
                                                                                       _target} ->
          edit
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {{path, absolute_key}, edits} ->
          result =
            with {:ok, content, relative} <- read(root, path),
                 {:ok, edited} <-
                   Enum.reduce_while(edits, {:ok, content}, fn edit, {:ok, current} ->
                     case replace(current, edit) do
                       {:ok, value} -> {:cont, {:ok, value}}
                       error -> {:halt, error}
                     end
                   end),
                 {:ok, absolute, ^relative} <- resolve(root, path),
                 :ok <- write(root, path, absolute, edited, content) do
              {:ok,
               %{
                 path: relative,
                 status: if(edited == content, do: "unchanged", else: "updated"),
                 bytes: byte_size(edited)
               }}
            end

          file =
            case result do
              {:ok, value} -> value
              {:error, reason} -> %{path: path, status: Atom.to_string(reason)}
            end

          record_file(absolute_key, file)
          file
        end)

      successes = Enum.count(files, &(&1.status in ["updated", "unchanged"]))

      status =
        cond do
          files == [] -> "unchanged"
          successes == length(files) -> "updated"
          successes == 0 -> "failed"
          true -> "partial"
        end

      {:ok, %{status: status, files: files}}
    end
  end

  defp run(root, :file_delete, args) do
    with {:ok, absolute, relative} <- resolve(root, args["path"]),
         {:ok, _} <- regular(absolute),
         :ok <- operation_current(),
         :ok <- normalize(File.rm(absolute)) do
      {:ok, %{status: "deleted", path: relative}}
    end
  end

  defp run(root, :file_move, args) do
    with {:ok, source, from} <- resolve(root, args["source"]),
         {:ok, destination, to} <- resolve(root, args["destination"]),
         {:ok, _} <- regular(source),
         {:ok, _} <- existing(root, args["destination"]),
         :ok <- operation_current(),
         :ok <- normalize(File.mkdir_p(Path.dirname(destination))),
         {:ok, ^destination, ^to} <- resolve(root, args["destination"]),
         :ok <- operation_current(),
         :ok <- normalize(File.rename(source, destination)) do
      {:ok,
       %{
         status: if(source == destination, do: "unchanged", else: "moved"),
         source: from,
         destination: to
       }}
    end
  end

  defp run(root, :list_dir, args) do
    with {:ok, entries} <- scan(root, args["path"], Map.get(args, "depth", 1)) do
      {:ok, paginated(entries, args, :entries)}
    end
  end

  defp run(root, :glob, args) do
    with :ok <- safe_pattern(args["pattern"]),
         {:ok, pattern} <- glob_regex(args["pattern"]),
         {:ok, _, base} <- resolve(root, Map.get(args, "path", ".")),
         {:ok, entries} <- scan(root, Map.get(args, "path", "."), 10) do
      paths =
        entries
        |> Enum.filter(&Regex.match?(pattern, Path.relative_to(&1.path, base)))
        |> Enum.map(& &1.path)

      {:ok, paginated(paths, args, :paths)}
    end
  end

  defp run(root, :grep, args) do
    with {:ok, regex} <- compile_regex(args["pattern"]),
         {:ok, include} <- optional_glob(args["include"]),
         {:ok, files} <- searchable(root, Map.get(args, "path", ".")) do
      Enum.reduce_while(files, {:ok, [], 0}, fn file, {:ok, found, bytes} ->
        if include && not Regex.match?(include, file.path) &&
             not Regex.match?(include, Path.basename(file.path)) do
          {:cont, {:ok, found, bytes}}
        else
          with {:ok, content, _} <- read(root, file.path),
               true <- bytes + byte_size(content) <= @max_file,
               {:ok, matches} <- matching_lines(content, regex, file.path) do
            {:cont, {:ok, found ++ matches, bytes + byte_size(content)}}
          else
            false -> {:halt, {:error, :scan_limit}}
            error -> {:halt, error}
          end
        end
      end)
      |> case do
        {:ok, matches, _} -> {:ok, paginated(matches, args, :matches)}
        error -> error
      end
    end
  end

  defp read(root, path, limit \\ @max_file, text? \\ true) do
    with :ok <- operation_current(),
         {:ok, absolute, relative} <- resolve(root, path),
         {:ok, before} <- regular(absolute),
         true <- before.size <= limit,
         {:ok, io} <- File.open(absolute, [:read, :binary, :raw]) do
      try do
        with {:ok, opened} <- :file.read_file_info(io),
             true <- elem(opened, 11) == before.inode,
             {:ok, content} <- read_bytes(io, limit),
             true <- byte_size(content) <= limit,
             {:ok, after_read} <- regular(absolute),
             true <- same_file?(before, after_read),
             {:ok, ^absolute, ^relative} <- resolve(root, path),
             true <- not text? or String.valid?(content) do
          {:ok, content, relative}
        else
          false -> {:error, :file_limit}
          {:ok, _} -> {:error, :conflict}
          {:error, _} = error -> error
          _ -> {:error, :unavailable}
        end
      after
        File.close(io)
      end
    else
      false -> {:error, :file_limit}
      error -> normalize(error)
    end
  end

  defp read_bytes(io, limit) do
    case :file.read(io, limit + 1) do
      :eof -> {:ok, ""}
      result -> result
    end
  end

  defp same_file?(left, right),
    do:
      Map.take(left, [:inode, :major_device, :minor_device, :size, :mtime, :ctime, :links]) ==
        Map.take(right, [:inode, :major_device, :minor_device, :size, :mtime, :ctime, :links])

  defp regular(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular, links: 1} = stat} -> {:ok, stat}
      {:ok, %{type: :symlink}} -> {:error, :unsafe_path}
      {:ok, %{type: :regular}} -> {:error, :unsafe_path}
      {:ok, _} -> {:error, :not_regular}
      error -> normalize(error)
    end
  end

  defp existing(root, path) do
    case read(root, path) do
      {:ok, content, _} -> {:ok, content}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp existing_binary(root, path) do
    case read(root, path, @max_file, false) do
      {:ok, content, _} -> {:ok, content}
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp write(_root, _path, _absolute, same, same), do: :ok

  defp write(root, path, absolute, content, previous),
    do: persist(root, path, absolute, content, previous)

  defp persist(root, path, absolute, content, previous) do
    with true <- is_binary(content) and byte_size(content) <= @max_file,
         :ok <- operation_current(),
         {:ok, ^previous} <- existing_binary(root, path),
         :ok <- operation_current(),
         :ok <- normalize(File.mkdir_p(Path.dirname(absolute))),
         {:ok, ^absolute, relative} <- resolve(root, path),
         :ok <- operation_current(),
         :ok <- normalize(File.write(absolute, content)),
         :ok <- operation_current(),
         {:ok, persisted_stat} <- regular(absolute),
         true <- persisted_stat.size == byte_size(content),
         :ok <- operation_current(),
         {:ok, ^content, ^relative} <- read(root, path, @max_file, false),
         :ok <- operation_current() do
      record_file(absolute, %{
        path: relative,
        status: if(is_nil(previous), do: "created", else: "updated"),
        bytes: byte_size(content)
      })

      :ok
    else
      false -> {:error, :file_limit}
      {:ok, _} -> {:error, :conflict}
      {:ok, _, _} -> {:error, :conflict}
      error -> error
    end
  end

  defp operation_current do
    case Process.get({__MODULE__, :deadline}) do
      nil ->
        :ok

      deadline ->
        if remaining(deadline) > 0 do
          case Process.get({__MODULE__, :scope}) do
            nil ->
              :ok

            %{lease: lease, guardian: guardian, deadline: ^deadline} ->
              with {:ok, %{owner_pid: ^guardian, deadline: ^deadline}} <- Access.check(lease, []),
                   do: :ok
          end
        else
          {:error, :timeout}
        end
    end
  end

  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))

  defp replace(content, args) do
    case :binary.match(content, args["old_string"]) do
      :nomatch ->
        {:error, :conflict}

      {offset, length} ->
        updated =
          binary_part(content, 0, offset) <>
            args["new_string"] <>
            binary_part(content, offset + length, byte_size(content) - offset - length)

        if byte_size(updated) <= @max_file, do: {:ok, updated}, else: {:error, :file_limit}
    end
  end

  defp page(content, path, offset, limit) do
    lines = source_lines(content)
    selected = Enum.slice(lines, offset, limit)

    {text, count, partial} =
      Enum.reduce_while(selected, {"", 0, false}, fn line, {text, count, _} ->
        cond do
          byte_size(text) + byte_size(line) <= @max_page ->
            {:cont, {text <> line, count + 1, false}}

          count == 0 ->
            {:halt, {utf8_prefix(line, @max_page), 1, true}}

          true ->
            {:halt, {text, count, false}}
        end
      end)

    truncated = partial or offset + count < length(lines)

    %{
      path: path,
      content: text,
      offset: offset,
      next_offset: if(truncated and not partial, do: offset + count),
      truncated: truncated,
      partial_line: partial
    }
  end

  defp source_lines(""), do: []

  defp source_lines(content) do
    pieces = String.split(content, "\n")
    last = length(pieces) - 1

    pieces
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, index} ->
      if index == last, do: if(line == "", do: [], else: [line]), else: [line <> "\n"]
    end)
  end

  defp utf8_prefix(value, bytes) do
    prefix = binary_part(value, 0, min(byte_size(value), bytes))
    if String.valid?(prefix), do: prefix, else: utf8_prefix(value, bytes - 1)
  end

  defp scan(root, path, depth) do
    with {:ok, absolute, relative} <- resolve(root, path),
         {:ok, %{type: :directory}} <- File.lstat(absolute),
         {:ok, entries, _} <- walk(root, relative, depth, 0) do
      {:ok, Enum.sort_by(entries, & &1.path)}
    else
      {:ok, _} -> {:error, :not_directory}
      error -> normalize(error)
    end
  end

  defp capture_direct_entries(root, path) do
    with :ok <- operation_current(),
         {:ok, absolute, relative} <- resolve(root, path),
         {:ok, before} <- direct_directory_stat(absolute) do
      capture_confirmed_directory(root, path, absolute, relative, before)
    else
      error -> normalize(error)
    end
  end

  defp capture_confirmed_directory(root, path, absolute, relative, before) do
    with :ok <- operation_current(),
         {:ok, names} <- File.ls(absolute),
         :ok <- operation_current(),
         {:ok, entries} <- direct_entry_stats(absolute, names),
         {:ok, ^absolute, ^relative} <- resolve(root, path),
         :ok <- operation_current(),
         {:ok, after_capture} <- File.lstat(absolute, time: :posix),
         true <- after_capture.type == :directory and same_file?(before, after_capture),
         :ok <- operation_current() do
      {:ok, entries}
    else
      false -> {:error, :conflict}
      {:ok, _, _} -> {:error, :conflict}
      # Once the requested directory exists, a missing list/child/revalidation
      # is a failed capture, not initial absence eligible for virtual fallback.
      {:error, reason} when reason in [:enoent, :not_found] -> {:error, :conflict}
      error -> normalize(error)
    end
  end

  defp direct_directory_stat(absolute) do
    case File.lstat(absolute, time: :posix) do
      {:ok, %{type: :directory} = stat} -> {:ok, stat}
      {:ok, _} -> {:error, :not_directory}
      error -> normalize(error)
    end
  end

  defp direct_entry_stats(_absolute, names) when length(names) > @max_entries,
    do: {:error, :scan_limit}

  defp direct_entry_stats(absolute, names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, entries} ->
      # A listed basename is not a child capability. lstat observes the entry
      # itself, including links; resolving it would follow/reject its target.
      with true <- is_binary(name) and String.valid?(name),
           :ok <- operation_current(),
           {:ok, stat} <- File.lstat(Path.join(absolute, name), time: :posix),
           :ok <- operation_current() do
        {:cont, {:ok, [%{name: name, is_directory: stat.type == :directory} | entries]}}
      else
        false -> {:halt, {:error, :invalid_input}}
        error -> {:halt, normalize(error)}
      end
    end)
  end

  defp snapshot_selection(selection) when is_map(selection) and not is_struct(selection) do
    pattern = Map.get(selection, :pattern, "**/*")
    exclude = Map.get(selection, :exclude, [])
    reads = Map.get(selection, :read_patterns, [])

    if Map.keys(selection) -- [:pattern, :exclude, :read_patterns] == [] and
         is_list(exclude) and is_list(reads) and
         length(exclude) + length(reads) <= @max_entries and
         Enum.all?([pattern | exclude ++ reads], fn value ->
           valid_value?("pattern", value) and safe_pattern(value) == :ok
         end) do
      {:ok,
       %{pattern: pattern, exclude: Enum.map(exclude, &snapshot_relative/1), read_patterns: reads}}
    else
      {:error, :invalid_input}
    end
  end

  defp snapshot_selection(_), do: {:error, :invalid_input}

  defp capture_snapshot(root, directory, stat, selection) do
    # Only the initial literal prefix bypasses Path.Wildcard's dot-name filter.
    # Capturing an explicit hidden sidecar path must not traverse unrelated .git.
    with {:ok, literal_paths} <-
           snapshot_literal_paths([selection.pattern | selection.read_patterns]) do
      snapshot = %{
        stats: %{"." => File.Stat.to_record(stat)},
        directories: %{},
        entries: %{"." => "directory"},
        scanned: 0
      }

      capture_directory(root, directory, ".", snapshot, literal_paths)
    end
  end

  defp snapshot_literal_paths(patterns) do
    Enum.reduce_while(
      patterns,
      {:ok, %{capture: MapSet.new(), descend: MapSet.new()}},
      fn pattern, {:ok, required} ->
        with {:ok, base, kind} <- SnapshotMatcher.literal_prefix(pattern) do
          paths =
            base
            |> Path.split()
            |> Enum.scan(fn part, prefix -> Path.join(prefix, part) end)
            |> Enum.map(&snapshot_relative/1)

          descend = if kind == :wildcard, do: paths, else: Enum.drop(paths, -1)

          {:cont,
           {:ok,
            %{
              capture: MapSet.union(required.capture, MapSet.new(paths)),
              descend: MapSet.union(required.descend, MapSet.new(descend))
            }}}
        else
          error -> {:halt, error}
        end
      end
    )
  end

  defp capture_directory(root, directory, path, snapshot, literal_paths) do
    with :ok <- operation_current(),
         {:ok, absolute, _} <- resolve(root, snapshot_path(directory, path)),
         {:ok, names} <- File.ls(absolute),
         true <- snapshot.scanned + length(names) <= @max_entries do
      snapshot = %{
        snapshot
        | scanned: snapshot.scanned + length(names),
          directories: Map.put(snapshot.directories, path, Enum.sort(names))
      }

      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, snapshot}, fn name, {:ok, current} ->
        child = snapshot_path(path, name)
        hidden? = String.starts_with?(name, ".")

        if hidden? and not MapSet.member?(literal_paths.capture, child) do
          {:cont, {:ok, current}}
        else
          with :ok <- operation_current(),
               {:ok, target, _} <- resolve(root, snapshot_path(directory, child)),
               {:ok, stat} <- File.lstat(target, time: :posix),
               true <- stat.type in [:directory, :regular] do
            current = %{
              current
              | stats: Map.put(current.stats, child, File.Stat.to_record(stat)),
                entries:
                  Map.put(
                    current.entries,
                    child,
                    if(stat.type == :directory, do: "directory", else: "file")
                  )
            }

            descend? = not hidden? or MapSet.member?(literal_paths.descend, child)

            if stat.type == :directory and descend? do
              case capture_directory(root, directory, child, current, literal_paths) do
                {:ok, captured} -> {:cont, {:ok, captured}}
                error -> {:halt, error}
              end
            else
              {:cont, {:ok, current}}
            end
          else
            false -> {:halt, {:error, :not_regular}}
            error -> {:halt, normalize(error)}
          end
        end
      end)
    else
      false -> {:error, :scan_limit}
      error -> normalize(error)
    end
  end

  defp snapshot_files(root, directory, snapshot, patterns) do
    Enum.reduce_while(patterns, {:ok, %{}, 0}, fn pattern, {:ok, files, bytes} ->
      with :ok <- operation_current(),
           {:ok, paths} <- SnapshotMatcher.match(snapshot, pattern) do
        Enum.reduce_while(paths, {:ok, files, bytes}, fn path, {:ok, selected, total} ->
          actual = snapshot_path(directory, path)

          if snapshot.entries[path] == "file" and not Map.has_key?(selected, actual) do
            with {:ok, content, ^actual} <- read(root, actual, @max_file - total, false),
                 true <- total + byte_size(content) <= @max_file do
              {:cont, {:ok, Map.put(selected, actual, content), total + byte_size(content)}}
            else
              false -> {:halt, {:error, :scan_limit}}
              error -> {:halt, error}
            end
          else
            {:cont, {:ok, selected, total}}
          end
        end)
        |> case do
          {:ok, selected, total} -> {:cont, {:ok, selected, total}}
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _} -> {:ok, files}
      error -> error
    end
  end

  defp snapshot_excluded?(path, prefixes),
    do: Enum.any?(prefixes, &(&1 == "." or path == &1 or String.starts_with?(path, &1 <> "/")))

  defp snapshot_path(".", path), do: snapshot_relative(path)
  defp snapshot_path(directory, "."), do: directory
  defp snapshot_path(directory, path), do: Path.join(directory, path)

  defp snapshot_relative(path), do: Path.relative_to(Path.expand("/" <> path), "/")

  defp walk(root, path, depth, scanned) do
    with {:ok, absolute, _} <- resolve(root, path),
         {:ok, names} <- File.ls(absolute),
         true <- scanned + length(names) <= @max_entries do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, [], scanned + length(names)}, fn name, {:ok, entries, count} ->
        child = if path == ".", do: name, else: Path.join(path, name)

        with {:ok, target, relative} <- resolve(root, child),
             {:ok, stat} <- File.lstat(target) do
          entry = %{
            path: relative,
            type: if(stat.type == :directory, do: "directory", else: "file")
          }

          if stat.type == :directory and depth > 1 do
            case walk(root, child, depth - 1, count) do
              {:ok, children, total} -> {:cont, {:ok, entries ++ [entry | children], total}}
              error -> {:halt, error}
            end
          else
            if stat.type in [:directory, :regular],
              do: {:cont, {:ok, entries ++ [entry], count}},
              else: {:halt, {:error, :not_regular}}
          end
        else
          error -> {:halt, normalize(error)}
        end
      end)
    else
      false -> {:error, :scan_limit}
      error -> normalize(error)
    end
  end

  defp searchable(root, path) do
    with {:ok, absolute, relative} <- resolve(root, path), {:ok, stat} <- File.lstat(absolute) do
      if stat.type == :regular do
        {:ok, [%{path: relative}]}
      else
        with {:ok, entries} <- scan(root, path, 10),
             do: {:ok, Enum.filter(entries, &(&1.type == "file"))}
      end
    else
      error -> normalize(error)
    end
  end

  defp paginated(values, args, key) do
    offset = Map.get(args, "offset", 0)
    selected = Enum.slice(values, offset, Map.get(args, "limit", 200))
    truncated = offset + length(selected) < length(values)

    %{
      key => selected,
      :truncated => truncated,
      :next_offset => if(truncated, do: offset + length(selected))
    }
  end

  defp compile_regex(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} -> {:ok, regex}
      _ -> {:error, :invalid_pattern}
    end
  end

  defp matching_lines(content, regex, path) do
    content
    |> source_lines()
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, matches} ->
      case :re.run(line, regex.re_pattern, [
             {:capture, :none},
             {:match_limit, 100_000},
             {:match_limit_recursion, 1_000}
           ]) do
        :match ->
          if length(matches) < @max_entries,
            do:
              {:cont,
               {:ok,
                matches ++
                  [
                    %{
                      path: path,
                      line: number,
                      text: utf8_prefix(String.trim_trailing(line, "\n"), 2_048)
                    }
                  ]}},
            else: {:halt, {:error, :scan_limit}}

        :nomatch ->
          {:cont, {:ok, matches}}

        _ ->
          {:halt, {:error, :scan_limit}}
      end
    end)
  end

  defp optional_glob(nil), do: {:ok, nil}
  defp optional_glob(pattern), do: glob_regex(pattern)

  defp safe_pattern(pattern) do
    if Path.type(pattern) == :relative and not String.contains?(pattern, ["\0", "\\"]) and
         ".." not in Path.split(pattern),
       do: :ok,
       else: {:error, :unsafe_path}
  end

  defp glob_regex(pattern) do
    Synapsis.Filesystem.Glob.compile(pattern)
  end

  defp normalize(:ok), do: :ok
  defp normalize({:error, :enoent}), do: {:error, :not_found}

  defp normalize({:error, reason}) when reason in [:eacces, :eperm],
    do: {:error, :permission_denied}

  defp normalize({:error, reason}) when reason in [:enospc, :eio, :ebusy],
    do: {:error, :io_failure}

  defp normalize(other), do: other

  defp record_file(absolute, file) do
    case Process.get({__MODULE__, :progress}) do
      {guardian, ref} ->
        context = Process.get({__MODULE__, :scope})
        file = Map.put(file, :path, Map.fetch!(context.evidence_paths, absolute))
        send(guardian, {ref, :completed_file, file})

      nil ->
        :ok
    end
  end

  defp completed_file(nil, _file), do: nil

  defp completed_file(evidence, file) do
    confirmed = ~w(created updated unchanged deleted moved)

    file =
      case Enum.find(evidence.files, &(&1.path == file.path)) do
        %{status: status} = previous
        when status in ["created", "updated", "unchanged", "deleted", "moved"] ->
          cond do
            file.status not in confirmed ->
              previous

            file.status == "unchanged" ->
              # Progress is cumulative across nested calls. A later no-op cannot
              # erase an earlier actual mutation or its last confirmed bytes.
              previous

            status == "created" and file.status == "updated" ->
              # The scope still created this file; keep the newest changed bytes.
              previous |> Map.merge(file) |> Map.put(:status, "created")

            true ->
              file
          end

        _ ->
          file
      end

    %{evidence | files: merge_files(evidence.files, [file], true)}
  end

  defp admitted_mutation(evidence, mutation, true) do
    # Initial lexical evidence was conservative, before physical resolution. The
    # first canonical admission precedes all effects, so retire its unknown aliases
    # while retaining any already confirmed canonical entries.
    confirmed =
      if evidence,
        do:
          Enum.filter(evidence.files, &(&1.status in ~w(created updated unchanged deleted moved))),
        else: []

    case {mutation, confirmed} do
      {nil, []} -> nil
      {nil, files} -> %{evidence | files: files}
      {mutation, files} -> %{mutation | files: merge_files(mutation.files, files, true)}
    end
  end

  defp admitted_mutation(nil, mutation, false), do: mutation
  defp admitted_mutation(evidence, nil, false), do: evidence

  defp admitted_mutation(evidence, mutation, false),
    do: %{evidence | files: merge_files(evidence.files, mutation.files, false)}

  defp merge_files(files, additions, replace?) do
    Enum.reduce(additions, files, fn file, current ->
      if Enum.any?(current, &(&1.path == file.path)) do
        if replace?,
          do: Enum.map(current, &if(&1.path == file.path, do: file, else: &1)),
          else: current
      else
        current ++ [file]
      end
    end)
  end

  defp register_mutation(mutation, targets, context, initial? \\ false) do
    mutation =
      if mutation do
        files =
          targets
          |> Enum.uniq_by(& &1.absolute)
          |> Enum.map(
            &%{path: Map.fetch!(context.evidence_paths, &1.absolute), status: "unknown_outcome"}
          )

        %{mutation | files: files}
      end

    {guardian, ref} = Process.get({__MODULE__, :progress})
    send(guardian, {ref, :mutation_admitted, mutation, initial?})
    :ok
  end

  defp scoped(root, paths, opts, fun, mutation \\ nil) do
    case Keyword.fetch(opts, :lease) do
      {:ok, lease} ->
        with {:ok, context} <- scope_context(lease, opts),
             {:ok, targets} <- resolve_paths(root, paths),
             :ok <- check_targets(context, targets) do
          register_mutation(mutation, targets, context)
          fun.(context)
        end

      :error ->
        # The pre-resolution fallback evidence must also fit before a guardian can
        # report it. This sizing is pure; physical resolution remains after reserve.
        with :ok <- require_explicit_nested_scope(),
             :ok <- evidence_budget(mutation) do
          bounded(
            opts,
            fn context ->
              with {:ok, lease} <-
                     Access.reserve(context.guardian, context.deadline, context.access_server),
                   {:ok, targets} <- resolve_paths(root, paths),
                   :ok <- Access.acquire(lease, target_keys(targets)) do
                context =
                  context
                  |> Map.put(:lease, lease)
                  # Relative labels are injective under this one guarded outer
                  # root; nested call roots never redefine guardian identities.
                  |> Map.put(:evidence_paths, Map.new(targets, &{&1.absolute, &1.path}))

                with :ok <- check_targets(context, targets),
                     # Reserve the complete outer set once, including the longest
                     # existing action label and existing evidence/metadata margins.
                     # Nested exact subsets cannot increase this evidence envelope.
                     :ok <- mutation_budget(:file_delete, targets) do
                  Process.put({__MODULE__, :scope}, context)
                  register_mutation(mutation, targets, context, true)
                  fun.(context)
                end
              end
            end,
            mutation,
            true
          )
        end
    end
  end

  defp require_explicit_nested_scope do
    if is_nil(Process.get({__MODULE__, :scope})),
      do: :ok,
      else: {:error, :invalid_lease}
  end

  defp scope_context(lease, opts) do
    # Access validates the opaque lease and actual sender before process-local
    # context can supply planner/progress channels. It never authorizes a bypass.
    with {:ok, %{owner_pid: guardian, worker_pid: worker, deadline: deadline}} <-
           Access.check(lease, []),
         true <- worker == self() and Keyword.get(opts, :deadline) == deadline,
         %{guardian: ^guardian, deadline: ^deadline, lease: ^lease} = context <-
           Process.get({__MODULE__, :scope}) do
      {:ok, context}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_lease}
    end
  end

  defp check_targets(context, targets) do
    with {:ok, %{owner_pid: owner, worker_pid: worker, deadline: deadline}} <-
           Access.check(context.lease, target_keys(targets)),
         true <- owner == context.guardian and worker == self() and deadline == context.deadline do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_lease}
    end
  end

  defp target_keys(targets), do: targets |> Enum.map(& &1.absolute) |> Enum.uniq() |> Enum.sort()

  defp interrupted(reason, nil), do: {:error, reason}

  defp interrupted(reason, evidence),
    do: {:error, {:unknown_outcome, Map.put(evidence, :reason, Atom.to_string(reason))}}

  # State operations use the same guardian/worker/Access ownership as bounded
  # operations, but cannot inherit unconditional worker kill: file-server rename
  # can outlive its requesting process. Every I/O dispatch has a recorded ACK gate.
  defp state_guard(owner, ref, deadline, root, path) do
    Process.flag(:trap_exit, true)

    state_guard_loop(%{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      ref: ref,
      deadline: deadline,
      root: root,
      path: path,
      phase: :dormant,
      evidence: nil,
      worker: nil,
      worker_monitor: nil,
      worker_down: false,
      worker_reason: nil,
      result: nil,
      waiter: nil,
      closers: [],
      close_requested: false,
      owner_gone: false,
      pending: %{},
      descriptors: %{},
      children: %{},
      access_monitor: nil,
      stop_reason: nil
    })
  end

  defp state_guard_loop(state) do
    state = state_settle(state)

    if state.phase == :settled and (state.close_requested or state.owner_gone) do
      Enum.each(state.closers, fn {caller, call_ref} ->
        send(caller, {state.ref, call_ref, :closed})
      end)
    else
      receive do
        {ref, :state_call, caller, call_ref, :status} when ref == state.ref ->
          send(caller, {ref, call_ref, {:ok, %{phase: state.phase, evidence: state.evidence}}})
          state_guard_loop(state)

        {ref, :state_call, caller, call_ref, {:run, request}} when ref == state.ref ->
          if caller == state.owner and state.phase == :dormant do
            state_guard_loop(state_activate(state, request, {caller, call_ref}))
          else
            send(caller, {ref, call_ref, {:error, :invalid_state_operation}})
            state_guard_loop(state)
          end

        {ref, :state_call, caller, call_ref, :close} when ref == state.ref ->
          state = %{
            state
            | close_requested: true,
              closers: [{caller, call_ref} | state.closers]
          }

          state =
            if state.phase == :dormant,
              do: %{state | phase: :settled},
              else: state_stop(state, :closed)

          state_guard_loop(state)

        {ref, :state_io_start, pid, io_ref, operation, mode} when ref == state.ref ->
          known = pid == state.worker or Map.has_key?(state.children, pid)

          allowed =
            known and
              ((state.phase == :running and remaining(state.deadline) > 0) or
                 mode in [:cleanup, :heartbeat])

          if allowed do
            pending = Map.put(state.pending, {pid, io_ref}, operation)
            send(pid, {ref, io_ref, :io_allowed})
            state_guard_loop(%{state | pending: pending})
          else
            send(pid, {ref, io_ref, {:io_denied, state.stop_reason || :timeout}})
            state_guard_loop(if mode == :forward, do: state_stop(state, :timeout), else: state)
          end

        {ref, :state_io_ack, pid, io_ref, result} when ref == state.ref ->
          case Map.pop(state.pending, {pid, io_ref}) do
            {nil, _} ->
              state_guard_loop(state)

            {operation, pending} ->
              state = state_io_observed(%{state | pending: pending}, operation, result)
              send(pid, {ref, io_ref, :io_recorded})
              state_guard_loop(state)
          end

        {ref, :state_child, worker, pid, kind, ack_ref}
        when ref == state.ref and worker == state.worker ->
          entry = %{monitor: Process.monitor(pid), kind: kind, down: false, reason: nil}
          state = %{state | children: Map.put(state.children, pid, entry)}
          send(worker, {ref, ack_ref, :child_registered})
          if state.phase == :retiring and kind == :callback, do: Process.exit(pid, :kill)
          state_guard_loop(state)

        {ref, :state_result, worker, result} when ref == state.ref and worker == state.worker ->
          state_guard_loop(%{state | result: result, evidence: elem(result, 1)})

        {ref, :state_deadline} when ref == state.ref ->
          state_guard_loop(state_stop(state, :timeout))

        {ref, :state_grace} when ref == state.ref ->
          if state.waiter do
            {caller, call_ref} = state.waiter
            send(caller, {ref, call_ref, {:error, state_unknown(state)}})
          end

          state_guard_loop(%{state | waiter: nil})

        {:DOWN, monitor, :process, pid, reason} ->
          state =
            cond do
              monitor == state.owner_monitor ->
                state_stop(%{state | owner_gone: true}, :owner_gone)

              monitor == state.access_monitor and not is_nil(monitor) ->
                state_stop(state, :unavailable)

              monitor == state.worker_monitor ->
                state = %{state | worker_down: true, worker_reason: reason}
                if reason == :normal, do: state, else: state_stop(state, :worker_limit)

              Map.get(state.descriptors, pid) == monitor ->
                %{state | descriptors: Map.delete(state.descriptors, pid)}

              Map.has_key?(state.children, pid) ->
                entry = Map.fetch!(state.children, pid)

                if entry.monitor == monitor,
                  do: %{
                    state
                    | children:
                        Map.put(state.children, pid, %{entry | down: true, reason: reason})
                  },
                  else: state

              true ->
                state
            end

          state =
            if state.phase == :dormant and state.owner_gone,
              do: %{state | phase: :settled},
              else: state

          state_guard_loop(state)

        {:EXIT, _pid, _reason} ->
          state_guard_loop(state)
      end
    end
  end

  defp state_activate(state, request, waiter) do
    access_server = Process.whereis(Access)

    if remaining(state.deadline) == 0 or not is_pid(access_server) do
      reason = if is_pid(access_server), do: :timeout, else: :unavailable
      result = {:error, %{reason: reason, publication: :not_started, cleanup_confirmed: true}}
      {caller, call_ref} = waiter
      send(caller, {state.ref, call_ref, result})
      %{state | phase: :settled, evidence: elem(result, 1)}
    else
      guardian = self()
      context = Map.take(state, [:ref, :deadline, :root, :path])
      context = Map.merge(context, %{guardian: guardian, access_server: access_server})

      {worker, monitor} =
        :erlang.spawn_opt(
          fn ->
            Process.put({__MODULE__, :deadline}, context.deadline)
            result = state_worker(context, request)
            send(guardian, {context.ref, :state_result, self(), result})
          end,
          [:link, :monitor, {:max_heap_size, %{size: 4_000_000, kill: true, error_logger: false}}]
        )

      Process.send_after(self(), {state.ref, :state_deadline}, remaining(state.deadline))

      %{
        state
        | phase: :running,
          worker: worker,
          worker_monitor: monitor,
          waiter: waiter,
          access_monitor: Process.monitor(access_server)
      }
    end
  end

  defp state_stop(%{phase: phase} = state, _reason) when phase in [:dormant, :settled], do: state
  defp state_stop(%{phase: :retiring} = state, _reason), do: state

  defp state_stop(state, reason) do
    send(state.worker, {state.ref, :state_stop, reason})

    Enum.each(state.children, fn {pid, child} ->
      if child.kind == :callback and not child.down, do: Process.exit(pid, :kill)
    end)

    Process.send_after(self(), {state.ref, :state_grace}, @cleanup_grace)
    %{state | phase: :retiring, stop_reason: reason}
  end

  defp state_settle(%{phase: phase} = state) when phase in [:dormant, :settled], do: state

  defp state_settle(state) do
    retired =
      state.worker_down and state.worker_reason == :normal and state.result != nil and
        map_size(state.pending) == 0 and map_size(state.descriptors) == 0 and
        Enum.all?(state.children, fn {_pid, child} -> child.down end)

    if retired and match?({_, %{cleanup_confirmed: true}}, state.result) do
      if state.waiter do
        {caller, call_ref} = state.waiter
        send(caller, {state.ref, call_ref, state.result})
      end

      %{state | phase: :settled, evidence: elem(state.result, 1), waiter: nil}
    else
      state
    end
  end

  defp state_unknown(state) do
    Map.merge(state.evidence || %{}, %{
      reason: state.stop_reason || :cleanup_pending,
      publication: Map.get(state.evidence || %{}, :publication, :unknown),
      cleanup_confirmed: false
    })
  end

  defp state_io_observed(state, %{operation: :open}, {:ok, descriptor}) when is_pid(descriptor) do
    %{state | descriptors: Map.put(state.descriptors, descriptor, Process.monitor(descriptor))}
  end

  defp state_io_observed(state, %{operation: {:publication, publication}}, :ok) do
    %{state | evidence: Map.put(state.evidence || %{}, :publication, publication)}
  end

  defp state_io_observed(state, _operation, _result), do: state

  defp state_worker(context, request) do
    try do
      with {:ok, lease} <-
             Access.reserve(context.guardian, context.deadline, context.access_server),
           {:ok, absolute, _relative} <-
             state_io(
               context,
               %{operation: :resolve, paths: [context.root, context.path]},
               :forward,
               fn -> resolve(context.root, context.path) end
             ),
           {:ok, ancestor} <-
             state_io(
               context,
               %{operation: :resolve_parent, paths: [Path.dirname(absolute)]},
               :forward,
               fn -> state_existing_parent(context.root, Path.dirname(absolute)) end
             ),
           :ok <- Access.acquire(lease, [ancestor]) do
        paths = StateFile.paths(absolute, ancestor)
        context = Map.merge(context, %{lease: lease, lease_key: ancestor, paths: paths})

        io = fn touched, operation, mode, fun ->
          state_io(context, %{operation: operation, paths: touched}, mode, fn ->
            state_validate_paths(context, touched, mode)
            fun.()
          end)
        end

        StateFile.run(
          %{
            paths: paths,
            max_file: @max_file,
            io: io,
            current: fn -> state_current(context) end,
            callback: fn callback, capture -> state_callback(context, callback, capture) end,
            heartbeat_start: fn -> state_start_heartbeat(context, io, paths.owner) end,
            heartbeat_stop: fn heartbeat -> state_stop_heartbeat(context, heartbeat) end
          },
          request
        )
      else
        {:error, reason} ->
          {:error, %{reason: reason, publication: :not_started, cleanup_confirmed: true}}
      end
    catch
      {:state_file, reason} ->
        {:error, %{reason: reason, publication: :not_started, cleanup_confirmed: true}}
    end
  end

  defp state_existing_parent(root, path) do
    with {:ok, ^path, _} <- resolve(root, path) do
      case File.lstat(path) do
        {:ok, %{type: :directory}} -> {:ok, path}
        {:error, :enoent} -> state_existing_parent(root, Path.dirname(path))
        _ -> {:error, :not_directory}
      end
    end
  end

  defp state_validate_paths(context, touched, mode) do
    if mode == :forward do
      case Access.check(context.lease, [context.lease_key]) do
        {:ok, %{owner_pid: owner, worker_pid: worker, deadline: deadline}}
        when owner == context.guardian and worker == self() and deadline == context.deadline ->
          :ok

        _ ->
          throw({:state_file, :invalid_lease})
      end
    end

    Enum.each(touched, fn path ->
      retained =
        path == context.lease_key or
          String.starts_with?(path, String.trim_trailing(context.lease_key, "/") <> "/")

      permitted = retained and path in context.paths.allowed

      case permitted and resolve(context.root, path) do
        {:ok, ^path, _} -> :ok
        _ -> throw({:state_file, :unsafe_path})
      end
    end)
  end

  defp state_io(context, operation, mode, fun) do
    io_ref = make_ref()
    send(context.guardian, {context.ref, :state_io_start, self(), io_ref, operation, mode})

    receive do
      {ref, ^io_ref, :io_allowed} when ref == context.ref ->
        # Even an exception is acknowledged before unwinding. An unacknowledged
        # dispatch retains ownership rather than allowing lock release on DOWN.
        outcome =
          try do
            {:returned, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        observed =
          case outcome do
            {:returned, result} -> result
            _ -> {:error, :io_exception}
          end

        send(context.guardian, {context.ref, :state_io_ack, self(), io_ref, observed})

        receive do
          {ref, ^io_ref, :io_recorded} when ref == context.ref ->
            case outcome do
              {:returned, result} -> result
              {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
            end
        end

      {ref, ^io_ref, {:io_denied, reason}} when ref == context.ref ->
        throw({:state_file, reason})
    end
  end

  defp state_current(context) do
    receive do
      {ref, :state_stop, reason} when ref == context.ref -> throw({:state_file, reason})
    after
      0 ->
        if remaining(context.deadline) == 0, do: throw({:state_file, :timeout}), else: :ok
    end
  end

  defp state_register_child(context, pid, kind) do
    ack_ref = make_ref()
    send(context.guardian, {context.ref, :state_child, self(), pid, kind, ack_ref})

    receive do
      {ref, ^ack_ref, :child_registered} when ref == context.ref -> :ok
    end
  end

  defp state_callback(context, callback, capture) do
    state_current(context)
    caller = self()
    callback_ref = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            :run ->
              result =
                try do
                  callback.(capture)
                catch
                  kind, reason -> {:error, {:callback, kind, reason}}
                end

              send(caller, {callback_ref, result})
          end
        end,
        [:monitor, {:max_heap_size, %{size: 4_000_000, kill: true, error_logger: false}}]
      )

    state_register_child(context, pid, :callback)
    send(pid, :run)

    receive do
      {^callback_ref, result} ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, :normal} -> result
          {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:callback_exit, reason}}
        end

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:callback_exit, reason}}

      {ref, :state_stop, reason} when ref == context.ref ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> {:error, reason}
        end
    end
  end

  defp state_start_heartbeat(context, io, owner_path) do
    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :run -> state_heartbeat(context, io, owner_path)
        end
      end)

    state_register_child(context, pid, :heartbeat)
    send(pid, :run)
    {pid, monitor}
  end

  defp state_heartbeat(context, io, owner_path) do
    receive do
      {ref, :stop_heartbeat} when ref == context.ref -> :ok
    after
      250 ->
        try do
          io.([owner_path], :heartbeat, :heartbeat, fn -> File.touch(owner_path) end)
        catch
          _, _ -> :ok
        end

        state_heartbeat(context, io, owner_path)
    end
  end

  defp state_stop_heartbeat(context, {pid, monitor}) do
    send(pid, {context.ref, :stop_heartbeat})

    receive do
      {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, {:heartbeat_exit, reason}}
    end
  end

  defp bounded(opts, fun, mutation \\ nil, admission? \\ false) do
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + 5_000)
    access_server = if admission?, do: Process.whereis(Access)

    cond do
      admission? and not is_pid(access_server) ->
        {:error, :unavailable}

      is_integer(deadline) and deadline > now ->
        deadline = min(deadline, now + 5_000)
        owner = self()
        ref = make_ref()

        {guardian, monitor} =
          spawn_monitor(fn -> guard(owner, ref, deadline, fun, mutation, access_server) end)

        receive do
          {^ref, :cleanup_pending, result} ->
            # Only the explicit unknown-cleanup branch can return before guardian
            # DOWN. Its guardian remains the owner until actual child retirement.
            Process.demonitor(monitor, [:flush])
            result

          {^ref, result} ->
            receive do
              {:DOWN, ^monitor, :process, ^guardian, _} -> result
            end

          {:DOWN, ^monitor, :process, ^guardian, _} ->
            interrupted(:worker_limit, mutation)
        end

      true ->
        if is_integer(deadline), do: {:error, :timeout}, else: {:error, :invalid_input}
    end
  end

  defp guard(owner, ref, deadline, fun, mutation, access_server) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    access_monitor = if is_pid(access_server), do: Process.monitor(access_server)
    guardian = self()
    result_ref = make_ref()

    if System.monotonic_time(:millisecond) < deadline do
      {worker, monitor} =
        :erlang.spawn_opt(
          fn ->
            Process.put({__MODULE__, :progress}, {guardian, result_ref})
            Process.put({__MODULE__, :deadline}, deadline)

            result =
              if System.monotonic_time(:millisecond) < deadline do
                if is_function(fun, 1),
                  do:
                    fun.(%{
                      guardian: guardian,
                      ref: result_ref,
                      deadline: deadline,
                      access_server: access_server
                    }),
                  else: fun.()
              else
                {:error, :timeout}
              end

            send(guardian, {result_ref, result})
          end,
          [
            :link,
            :monitor,
            {:max_heap_size, %{size: 4_000_000, kill: true, error_logger: false}}
          ]
        )

      state = %{
        result: nil,
        result_received: false,
        mutation: mutation,
        brokers: %{},
        worker_down: false,
        worker_reason: nil,
        access_server: access_server,
        access_monitor: access_monitor
      }

      case await(worker, monitor, owner_monitor, result_ref, deadline, state) do
        {:cleanup_pending, pending, reason} ->
          if reason != :owner_gone and Process.alive?(owner) do
            send(owner, {ref, :cleanup_pending, unknown_cleanup(reason, pending.mutation)})
          end

          # Returning unknown does not retire or transfer this operation. Keep
          # the existing guardian alive with its links/monitors until all actual
          # exits arrive, even when file IO delays the worker's pending kill.
          await_forced_retirement(worker, monitor, owner_monitor, result_ref, pending)

        :owner_gone ->
          :ok

        result ->
          if Process.alive?(owner), do: send(owner, {ref, result})
      end
    else
      send(owner, {ref, {:error, :timeout}})
    end
  end

  defp await(worker, monitor, owner_monitor, ref, deadline, state) do
    case finished(state) do
      {:done, result} ->
        if remaining(deadline) > 0, do: result, else: interrupted(:timeout, state.mutation)

      :pending ->
        receive do
          {^ref, :planner_register, ^worker, broker, ack_ref} when is_pid(broker) ->
            # Register and monitor before ACK permits the dormant broker to open
            # an OS process. Only this worker and this operation ref are admitted.
            state = register_planner(state, broker)
            send(worker, {:planner_registered, ack_ref})
            await(worker, monitor, owner_monitor, ref, deadline, state)

          {^ref, :planner_settled, broker, status} ->
            state = planner_settled(state, broker, status)
            await(worker, monitor, owner_monitor, ref, deadline, state)

          {^ref, :completed_file, file} ->
            state = %{state | mutation: completed_file(state.mutation, file)}
            await(worker, monitor, owner_monitor, ref, deadline, state)

          {^ref, :mutation_admitted, mutation, initial?} ->
            state = %{state | mutation: admitted_mutation(state.mutation, mutation, initial?)}
            await(worker, monitor, owner_monitor, ref, deadline, state)

          {^ref, value} ->
            await(worker, monitor, owner_monitor, ref, deadline, %{
              state
              | result: value,
                result_received: true
            })

          {:DOWN, ^monitor, :process, ^worker, reason} ->
            state = %{state | worker_down: true, worker_reason: reason}

            if reason == :normal and state.result_received do
              await(worker, monitor, owner_monitor, ref, deadline, state)
            else
              cleanup(worker, monitor, owner_monitor, ref, deadline, state, :worker_limit)
            end

          {:DOWN, ^owner_monitor, :process, _, _} ->
            cleanup(worker, monitor, owner_monitor, ref, deadline, state, :owner_gone)

          {:DOWN, access_monitor, :process, _, _}
          when access_monitor == state.access_monitor and not is_nil(access_monitor) ->
            # The temporary coordinator never restarts into empty state. Retire
            # this generation's work; recovery requires an explicit service restart.
            cleanup(worker, monitor, owner_monitor, ref, deadline, state, :unavailable)

          {:DOWN, broker_monitor, :process, broker, reason} ->
            state = planner_down(state, broker, broker_monitor, reason)
            await(worker, monitor, owner_monitor, ref, deadline, state)

          {:EXIT, ^worker, _} ->
            await(worker, monitor, owner_monitor, ref, deadline, state)
        after
          remaining(deadline) ->
            cleanup(worker, monitor, owner_monitor, ref, deadline, state, :timeout)
        end
    end
  end

  defp register_planner(state, broker) do
    if Map.has_key?(state.brokers, broker) do
      state
    else
      entry = %{monitor: Process.monitor(broker), status: nil, down: false, reason: nil}
      %{state | brokers: Map.put(state.brokers, broker, entry)}
    end
  end

  defp planner_settled(state, broker, status) do
    case Map.fetch(state.brokers, broker) do
      {:ok, entry} ->
        %{state | brokers: Map.put(state.brokers, broker, %{entry | status: status})}

      :error ->
        state
    end
  end

  defp planner_down(state, broker, monitor, reason) do
    case Map.fetch(state.brokers, broker) do
      {:ok, %{monitor: ^monitor} = entry} ->
        %{state | brokers: Map.put(state.brokers, broker, %{entry | down: true, reason: reason})}

      _ ->
        state
    end
  end

  defp retired?(state),
    do: state.worker_down and Enum.all?(state.brokers, fn {_pid, entry} -> entry.down end)

  defp finished(state) do
    if retired?(state) do
      clean =
        Enum.all?(state.brokers, fn {_pid, entry} ->
          entry.reason == :normal and planner_completed?(entry.status)
        end)

      result =
        cond do
          is_pid(state.access_server) and not Process.alive?(state.access_server) ->
            # Coordinator DOWN may still be queued behind the worker's result.
            # Preserve possible/confirmed mutations rather than returning a clean
            # result from a generation whose admission authority has disappeared.
            interrupted(:unavailable, state.mutation)

          clean and state.worker_reason == :normal and state.result_received ->
            state.result

          true ->
            interrupted(:worker_limit, state.mutation)
        end

      {:done, result}
    else
      :pending
    end
  end

  defp cleanup(worker, monitor, owner_monitor, ref, deadline, state, reason) do
    unless state.worker_down, do: Process.exit(worker, :kill)
    cleanup_deadline = min(System.monotonic_time(:millisecond), deadline) + @cleanup_grace
    cleanup_await(worker, monitor, owner_monitor, ref, cleanup_deadline, state, reason)
  end

  defp cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason) do
    if retired?(state) do
      cleanup_result(reason, state.mutation)
    else
      receive do
        {^ref, :planner_register, ^worker, broker, _ack_ref} when is_pid(broker) ->
          # Registration may already be queued when the worker is stopped. Track
          # its broker too; caller loss makes the broker cancel and retire.
          state = register_planner(state, broker)
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)

        {^ref, :planner_settled, broker, status} ->
          state = planner_settled(state, broker, status)
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)

        {^ref, :completed_file, file} ->
          state = %{state | mutation: completed_file(state.mutation, file)}
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)

        {^ref, :mutation_admitted, mutation, initial?} ->
          state = %{state | mutation: admitted_mutation(state.mutation, mutation, initial?)}
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)

        {^ref, _late_result} ->
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)

        {:DOWN, ^monitor, :process, ^worker, worker_reason} ->
          state = %{state | worker_down: true, worker_reason: worker_reason}
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)

        {:DOWN, ^owner_monitor, :process, _, _} ->
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, :owner_gone)

        {:DOWN, broker_monitor, :process, broker, broker_reason} ->
          state = planner_down(state, broker, broker_monitor, broker_reason)
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)

        {:EXIT, ^worker, _} ->
          cleanup_await(worker, monitor, owner_monitor, ref, deadline, state, reason)
      after
        remaining(deadline) ->
          # The broker normally retires itself after finite observed cleanup.
          # At the shared grace boundary request kill for remaining children and
          # return explicit unknown cleanup to the caller. Actual DOWN may be
          # delayed by IO; the existing guardian retains ownership asynchronously.
          unless state.worker_down, do: Process.exit(worker, :kill)

          Enum.each(state.brokers, fn {broker, entry} ->
            unless entry.down, do: Process.exit(broker, :kill)
          end)

          {:cleanup_pending, state, reason}
      end
    end
  end

  defp await_forced_retirement(worker, monitor, owner_monitor, ref, state) do
    if retired?(state) do
      :ok
    else
      receive do
        {^ref, :planner_register, ^worker, broker, _ack_ref} when is_pid(broker) ->
          # A registration sent before the worker's kill can still be queued.
          # Monitor before stopping this dormant broker and never ACK new work.
          state = register_planner(state, broker)
          Process.exit(broker, :kill)
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {:DOWN, ^monitor, :process, ^worker, worker_reason} ->
          state = %{state | worker_down: true, worker_reason: worker_reason}
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {:DOWN, ^owner_monitor, :process, _, _} ->
          # Caller loss does not release children whose exits remain unobserved.
          unless state.worker_down, do: Process.exit(worker, :kill)

          Enum.each(state.brokers, fn {broker, entry} ->
            unless entry.down, do: Process.exit(broker, :kill)
          end)

          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {:DOWN, broker_monitor, :process, broker, broker_reason} ->
          state = planner_down(state, broker, broker_monitor, broker_reason)
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {^ref, :completed_file, file} ->
          state = %{state | mutation: completed_file(state.mutation, file)}
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {^ref, :mutation_admitted, mutation, initial?} ->
          state = %{state | mutation: admitted_mutation(state.mutation, mutation, initial?)}
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {^ref, :planner_settled, broker, status} ->
          state = planner_settled(state, broker, status)
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {^ref, _late_result} ->
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)

        {:EXIT, ^worker, _} ->
          await_forced_retirement(worker, monitor, owner_monitor, ref, state)
      end
    end
  end

  defp unknown_cleanup(reason, mutation) do
    evidence = mutation || %{status: "unknown_outcome"}

    {:error,
     {:unknown_outcome,
      Map.merge(evidence, %{
        reason: Atom.to_string(reason),
        cleanup_confirmed: false,
        retirement_confirmed: false
      })}}
  end

  defp cleanup_result(:owner_gone, _mutation), do: :owner_gone
  defp cleanup_result(reason, mutation), do: interrupted(reason, mutation)
end
