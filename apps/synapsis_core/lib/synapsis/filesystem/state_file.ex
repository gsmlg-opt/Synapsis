defmodule Synapsis.Filesystem.StateFile do
  @moduledoc false

  # Byte/lock/atomic-file portion of Lobster 2026.9.16 state/store.js and
  # state/atomic_file.js. Local supplies admission, I/O ACKs and child ownership;
  # this helper has no executor, JSON interpretation or retained state service.
  #
  # MIT License
  # Copyright (c) 2026 Vignesh
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
  @unsupported_sync [:eacces, :ebadf, :einval, :eisdir, :enosys, :enotsup, :eopnotsupp, :eperm]

  def paths(target, ancestor) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    pid = List.to_string(:os.getpid())
    parent = Path.dirname(target)
    lock = target <> ".lock"
    release = lock <> ".release-" <> pid <> "-" <> nonce
    temp = Path.join(parent, "." <> Path.basename(target) <> "." <> nonce <> ".tmp")
    rollback_temp = temp <> ".rollback"
    directories = directory_chain(ancestor, parent)

    %{
      target: target,
      parent: parent,
      ancestor: ancestor,
      directories: directories,
      lock: lock,
      owner: Path.join(lock, "owner"),
      reclaim: Path.join(lock, ".reclaiming"),
      release: release,
      release_owner: Path.join(release, "owner"),
      release_reclaim: Path.join(release, ".reclaiming"),
      temp: temp,
      rollback_temp: rollback_temp,
      nonce: nonce,
      pid: pid,
      allowed:
        Enum.uniq(
          directories ++
            [
              target,
              lock,
              Path.join(lock, "owner"),
              Path.join(lock, ".reclaiming"),
              release,
              Path.join(release, "owner"),
              Path.join(release, ".reclaiming"),
              temp,
              rollback_temp
            ]
        )
    }
  end

  defp directory_chain(ancestor, ancestor), do: [ancestor]

  defp directory_chain(ancestor, final),
    do: directory_chain(ancestor, Path.dirname(final)) ++ [final]

  def run(context, request) do
    Process.put(__MODULE__, %{
      publication: :not_started,
      file_sync: :not_applicable,
      directory_sync: :not_applicable,
      created_directory_sync: :not_applicable,
      cleanup_confirmed: false,
      acquired: false,
      owner_written: false,
      owner: nil,
      heartbeat: nil,
      cleanup_errors: []
    })

    result =
      attempt(fn ->
        ensure_directory(context)
        acquire(context)
        execute(context, request)
      end)

    cleanup = attempt(fn -> release(context) end)
    evidence = Process.get(__MODULE__)
    Process.delete(__MODULE__)
    clean = cleanup == {:ok, :ok} and evidence.cleanup_errors == []

    case {result, clean} do
      {{:ok, value}, true} ->
        {:ok, Map.put(value, :cleanup_confirmed, true)}

      _ ->
        reason =
          case {result, cleanup} do
            {{:error, reason}, _} -> reason
            {_, {:error, reason}} -> reason
            _ -> {:cleanup, evidence.cleanup_errors}
          end

        {:error,
         evidence
         |> Map.take([:publication, :file_sync, :directory_sync])
         |> Map.merge(%{reason: reason, cleanup_confirmed: clean})}
    end
  end

  defp attempt(fun) do
    try do
      {:ok, fun.()}
    catch
      {:state_file, reason} -> {:error, reason}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp evidence(key, value) do
    Process.put(__MODULE__, Map.put(Process.get(__MODULE__), key, value))
    value
  end

  defp cleanup_error(reason) do
    state = Process.get(__MODULE__)
    Process.put(__MODULE__, %{state | cleanup_errors: [reason | state.cleanup_errors]})
  end

  defp call(context, paths, operation, mode, fun), do: context.io.(paths, operation, mode, fun)
  defp ok(:ok), do: :ok
  defp ok({:error, reason}), do: throw({:state_file, reason})
  defp value({:ok, value}), do: value
  defp value({:error, reason}), do: throw({:state_file, reason})

  defp ensure_directory(context) do
    [_existing | missing] = context.paths.directories

    Enum.each(missing, fn directory ->
      case call(context, [directory], :mkdir, :forward, fn -> File.mkdir(directory) end) do
        :ok ->
          # Sync the parent of each source-created directory. The final directory
          # itself is synced by atomic publication, exactly as ensureDirectory.
          sync = sync_directory(context, Path.dirname(directory), :forward)
          previous = Process.get(__MODULE__).created_directory_sync

          evidence(
            :created_directory_sync,
            if(match?({:unsupported, _}, previous), do: previous, else: sync)
          )

        {:error, :eexist} ->
          :ok

        {:error, reason} ->
          throw({:state_file, reason})
      end
    end)
  end

  defp acquire(context) do
    context.current.()

    case call(context, [context.paths.lock], :mkdir, :forward, fn ->
           File.mkdir(context.paths.lock)
         end) do
      :ok ->
        evidence(:acquired, true)
        identity = process_identity(context, context.paths.pid)

        start =
          case identity do
            {:ok, start} -> start
            _ -> ""
          end

        owner = context.paths.pid <> ":" <> start <> ":" <> context.paths.nonce <> "\n"
        evidence(:owner, owner)

        with_file(
          context,
          context.paths.owner,
          [:write, :binary, :exclusive],
          :forward,
          fn file ->
            call(context, [context.paths.owner], :write_owner, :forward, fn ->
              :file.write(file, owner)
            end)
            |> ok()
          end
        )

        evidence(:owner_written, true)
        evidence(:heartbeat, context.heartbeat_start.())
        :ok

      {:error, :eexist} ->
        unless reclaim(context), do: wait(context, 10)
        acquire(context)

      {:error, reason} ->
        throw({:state_file, reason})
    end
  end

  # Fixed process identity reads are bounded internal lock metadata, never a
  # user-addressable path/root. Linux starttime is procfs field 22.
  defp process_identity(context, pid) do
    if match?({:unix, :linux}, :os.type()) and Regex.match?(~r/^[1-9][0-9]*$/, pid) do
      path = "/proc/" <> pid <> "/stat"

      case call(context, [], :open, :forward, fn -> :file.open(path, [:read, :binary]) end) do
        {:ok, file} ->
          try do
            case call(context, [], :process_identity, :forward, fn -> :file.read(file, 65_537) end) do
              {:ok, bytes} when byte_size(bytes) <= 65_536 ->
                case :binary.matches(bytes, ")") do
                  [] ->
                    {:error, :unavailable}

                  matches ->
                    {offset, _} = List.last(matches)

                    fields =
                      bytes
                      |> binary_part(offset + 1, byte_size(bytes) - offset - 1)
                      |> String.split()

                    case Enum.at(fields, 19) do
                      nil -> {:error, :unavailable}
                      start -> {:ok, start}
                    end
                end

              _ ->
                {:error, :unavailable}
            end
          after
            close_file(context, [], file)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :unsupported}
    end
  end

  defp wait(context, milliseconds) do
    context.current.()

    receive do
    after
      milliseconds -> context.current.()
    end
  end

  defp execute(context, :read_locked) do
    before = capture(context)
    context.current.()

    summary(
      before,
      nil,
      :not_applicable,
      :not_applicable,
      Process.get(__MODULE__).created_directory_sync
    )
  end

  defp execute(context, {:read_locked, callback}) do
    before = capture(context)
    domain_value = value(context.callback.(callback, before))
    context.current.()

    summary(
      before,
      domain_value,
      :not_applicable,
      :not_applicable,
      Process.get(__MODULE__).created_directory_sync
    )
  end

  defp execute(context, {:write_always, bytes}) do
    atomic_write(context, bytes, context.paths.temp, :forward, :published)
    # state.set retains an acknowledged publication even if stop arrives after
    # rename. Its source reports signalAbortedAfterCommit instead of rollback.
    summary(:not_captured, nil, :published, :confirmed, Process.get(__MODULE__).directory_sync)
  end

  defp execute(context, {:transition_locked, callback}) do
    before = capture(context)
    transition = value(context.callback.(callback, before))

    unless is_map(transition) and Enum.sort(Map.keys(transition)) == [:rollback, :value, :write] do
      throw({:state_file, :invalid_transition})
    end

    unless is_binary(transition.write) and byte_size(transition.write) <= context.max_file and
             valid_rollback?(transition.rollback, context.max_file) do
      throw({:state_file, :invalid_transition})
    end

    try do
      context.current.()
      atomic_write(context, transition.write, context.paths.temp, :forward, :published)
      context.current.()

      summary(
        before,
        transition.value,
        :published,
        :confirmed,
        Process.get(__MODULE__).directory_sync
      )
    catch
      kind, reason ->
        stack = __STACKTRACE__

        if Process.get(__MODULE__).publication == :published do
          case transition.rollback do
            :remove ->
              call(context, [context.paths.target], {:publication, :rolled_back}, :cleanup, fn ->
                File.rm(context.paths.target)
              end)
              |> ok()

              sync_directory(context, context.paths.parent, :cleanup)
              evidence(:publication, :rolled_back)

            {:replace, bytes} ->
              atomic_write(context, bytes, context.paths.rollback_temp, :cleanup, :rolled_back)
          end
        end

        :erlang.raise(kind, reason, stack)
    end
  end

  defp valid_rollback?(:remove, _limit), do: true

  defp valid_rollback?({:replace, bytes}, limit),
    do: is_binary(bytes) and byte_size(bytes) <= limit

  defp valid_rollback?(_, _), do: false

  defp summary(before, value, publication, file_sync, directory_sync) do
    %{
      before: before,
      value: value,
      publication: publication,
      file_sync: file_sync,
      directory_sync: directory_sync,
      cleanup_confirmed: true
    }
  end

  defp capture(context) do
    path = context.paths.target

    case call(context, [path], :stat, :forward, fn -> File.lstat(path, time: :posix) end) do
      {:error, :enoent} ->
        %{exists: false, bytes: nil}

      {:ok, %{type: :regular, links: 1, size: size} = before} when size <= context.max_file ->
        bytes =
          with_file(context, path, [:read, :binary], :forward, fn file ->
            opened =
              value(
                call(context, [path], :descriptor_stat, :forward, fn ->
                  :file.read_file_info(file)
                end)
              )

            unless elem(opened, 11) == before.inode, do: throw({:state_file, :conflict})

            bytes =
              case call(context, [path], :read, :forward, fn ->
                     :file.read(file, context.max_file + 1)
                   end) do
                :eof -> ""
                result -> value(result)
              end

            if byte_size(bytes) > context.max_file, do: throw({:state_file, :file_limit})

            after_read =
              value(
                call(context, [path], :stat, :forward, fn -> File.lstat(path, time: :posix) end)
              )

            fields = [:inode, :major_device, :minor_device, :size, :mtime, :ctime, :links, :type]

            unless Map.take(before, fields) == Map.take(after_read, fields),
              do: throw({:state_file, :conflict})

            bytes
          end)

        %{exists: true, bytes: bytes}

      {:ok, %{size: size}} when size > context.max_file ->
        throw({:state_file, :file_limit})

      {:ok, _} ->
        throw({:state_file, :not_regular})

      {:error, reason} ->
        throw({:state_file, reason})
    end
  end

  defp with_file(context, path, modes, mode, fun) do
    file = value(call(context, [path], :open, mode, fn -> :file.open(path, modes) end))

    try do
      fun.(file)
    after
      close_file(context, [path], file)
    end
  end

  defp close_file(context, paths, file) do
    monitor = Process.monitor(file)
    result = call(context, paths, :close, :cleanup, fn -> :file.close(file) end)

    # The descriptor's real server exit is part of retirement, not merely a
    # successful close return. Local also independently monitors the same PID.
    receive do
      {:DOWN, ^monitor, :process, ^file, reason} ->
        if result != :ok or reason not in [:normal, :noproc],
          do: cleanup_error({:descriptor_close, result, reason})
    end

    ok(result)
  end

  defp atomic_write(context, bytes, temp, mode, publication) do
    if byte_size(bytes) > context.max_file, do: throw({:state_file, :file_limit})
    target = context.paths.target

    existing_mode =
      case call(context, [target], :stat, mode, fn -> File.lstat(target) end) do
        {:ok, %{type: :regular, links: 1, size: size, mode: permissions}}
        when size <= context.max_file ->
          Bitwise.band(permissions, 0o777)

        {:error, :enoent} ->
          nil

        {:ok, %{size: size}} when size > context.max_file ->
          throw({:state_file, :file_limit})

        {:ok, _} ->
          throw({:state_file, :not_regular})

        {:error, reason} ->
          throw({:state_file, reason})
      end

    try do
      with_file(context, temp, [:write, :binary, :exclusive], mode, fn file ->
        call(context, [temp], :write, mode, fn -> :file.write(file, bytes) end) |> ok()

        if existing_mode do
          # Follow Local's public path-based mode conventions. Exact creation
          # mode/fchmod parity is a separately declared source-only boundary.
          call(context, [temp], :mode, mode, fn -> File.chmod(temp, existing_mode) end) |> ok()
        end

        call(context, [temp], :file_sync, mode, fn -> :file.sync(file) end) |> ok()
        evidence(:file_sync, :confirmed)
      end)

      if mode == :forward, do: context.current.()

      call(context, [temp, target], {:publication, publication}, mode, fn ->
        :file.rename(temp, target)
      end)
      |> ok()

      evidence(:publication, publication)
      # Once rename is acknowledged, finish its durability/rollback decision
      # under the retained lock even when the forward deadline has expired.
      directory_sync = sync_directory(context, context.paths.parent, :cleanup)
      evidence(:directory_sync, directory_sync)
      :ok
    after
      case call(context, [temp], :remove_temp, :cleanup, fn -> File.rm(temp) end) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> cleanup_error({:temp, error})
      end
    end
  end

  defp sync_directory(context, directory, mode) do
    case call(context, [directory], :open, mode, fn ->
           :file.open(directory, [:read, :binary, :directory])
         end) do
      {:ok, file} ->
        try do
          case call(context, [directory], :directory_sync, mode, fn -> :file.sync(file) end) do
            :ok -> :confirmed
            {:error, reason} when reason in @unsupported_sync -> {:unsupported, reason}
            {:error, reason} -> throw({:state_file, reason})
          end
        after
          close_file(context, [directory], file)
        end

      {:error, reason} when reason in @unsupported_sync ->
        {:unsupported, reason}

      {:error, reason} ->
        throw({:state_file, reason})
    end
  end

  defp release(context) do
    state = Process.get(__MODULE__)

    if state.heartbeat do
      context.heartbeat_stop.(state.heartbeat) |> ok()
      evidence(:heartbeat, nil)
    end

    if state.acquired do
      if not state.owner_written or still_owns?(context, state.owner, 0) do
        # Detach the owned directory before removal, as the pinned source does.
        case call(
               context,
               [context.paths.lock, context.paths.release],
               :detach_lock,
               :cleanup,
               fn ->
                 File.rename(context.paths.lock, context.paths.release)
               end
             ) do
          :ok -> remove_lock(context, :release, :cleanup)
          {:error, :enoent} -> :ok
          {:error, _} -> remove_lock(context, :lock, :cleanup)
        end
      else
        throw({:state_file, :lock_ownership_unconfirmed})
      end
    end

    :ok
  end

  defp still_owns?(context, owner, attempt) do
    case attempt(fn -> read_small(context, context.paths.owner, :cleanup) end) do
      {:ok, text} ->
        text == owner

      {:error, :enoent} ->
        false

      {:error, _} when attempt == 0 ->
        receive do
        after
          10 -> still_owns?(context, owner, 1)
        end

      _ ->
        false
    end
  end

  defp read_small(context, path, mode) do
    with_file(context, path, [:read, :binary], mode, fn file ->
      case call(context, [path], :read_owner, mode, fn -> :file.read(file, 4_097) end) do
        {:ok, text} when byte_size(text) <= 4_096 -> text
        :eof -> ""
        {:error, reason} -> throw({:state_file, reason})
        _ -> throw({:state_file, :file_limit})
      end
    end)
  end

  defp remove_lock(context, which, mode) do
    {directory, owner, reclaim} =
      if which == :release,
        do: {context.paths.release, context.paths.release_owner, context.paths.release_reclaim},
        else: {context.paths.lock, context.paths.owner, context.paths.reclaim}

    Enum.each([owner], fn path ->
      case call(context, [path], :remove_owner, mode, fn -> File.rm(path) end) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> throw({:state_file, reason})
      end
    end)

    case call(context, [reclaim], :remove_reclaim, mode, fn -> File.rmdir(reclaim) end) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> throw({:state_file, reason})
    end

    case call(context, [directory], :remove_lock, mode, fn -> File.rmdir(directory) end) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> throw({:state_file, reason})
    end
  end

  defp reclaim(context) do
    case call(context, [context.paths.lock], :stat_lock, :forward, fn ->
           File.lstat(context.paths.lock, time: :posix)
         end) do
      {:error, :enoent} ->
        true

      {:ok, observed_lock} ->
        observed_owner = attempt(fn -> read_small(context, context.paths.owner, :forward) end)

        if stale?(context, observed_lock, observed_owner) do
          claim_reclaim(context, observed_lock, observed_owner)
        else
          false
        end

      {:error, reason} ->
        throw({:state_file, reason})
    end
  end

  defp stale?(context, lock, {:ok, owner}) do
    case owner |> String.trim() |> String.split(":") do
      [pid, identity, nonce] when nonce != "" ->
        if Regex.match?(~r/^[1-9][0-9]*$/, pid) do
          case process_identity(context, pid) do
            {:ok, current} when identity != "" -> current != identity
            {:error, :enoent} -> true
            # No public OTP subsecond timestamp observation is available here.
            # Do not reclaim a possibly live owner using rounded-second equality.
            # Exact source fallback-lease parity remains unqualified.
            _ -> false
          end
        else
          old?(lock)
        end

      _ ->
        old?(lock)
    end
  end

  defp stale?(_context, lock, {:error, :enoent}), do: old?(lock)
  defp stale?(_context, _lock, {:error, reason}), do: throw({:state_file, reason})
  defp old?(stat), do: System.system_time(:second) - stat.mtime >= 30

  defp claim_reclaim(context, observed_lock, observed_owner) do
    case call(context, [context.paths.reclaim], :claim_reclaim, :forward, fn ->
           File.mkdir(context.paths.reclaim)
         end) do
      :ok ->
        try do
          current_lock =
            value(
              call(context, [context.paths.lock], :stat_lock, :forward, fn ->
                File.lstat(context.paths.lock, time: :posix)
              end)
            )

          identity_fields = [:inode, :major_device, :minor_device]
          current_owner = attempt(fn -> read_small(context, context.paths.owner, :forward) end)

          if Map.take(current_lock, identity_fields) == Map.take(observed_lock, identity_fields) and
               current_owner == observed_owner do
            remove_lock(context, :lock, :forward)
            true
          else
            false
          end
        after
          case call(context, [context.paths.reclaim], :remove_reclaim, :cleanup, fn ->
                 File.rmdir(context.paths.reclaim)
               end) do
            :ok -> :ok
            {:error, :enoent} -> :ok
            error -> cleanup_error({:reclaim, error})
          end
        end

      {:error, :enoent} ->
        true

      {:error, :eexist} ->
        false

      {:error, reason} ->
        throw({:state_file, reason})
    end
  end
end
