defmodule Synapsis.Filesystem.PreciseMetadata do
  @moduledoc false

  alias Synapsis.Filesystem.Local
  alias Synapsis.Filesystem.PreciseMetadata.PortSession

  # Called only after Local.scoped has checked the exact admitted path key.
  # The generic guardian bookkeeping names are historical; no pure-planner
  # protocol or executable is reused for this filesystem-reading child.
  def capture(context, root, admitted_path, files, names, opts) do
    scope = [lease: context.lease, deadline: context.deadline]

    with :ok <- Local.check_scope(scope),
         {:ok, directory, _} <- Local.resolve(root, admitted_path),
         {:ok, before} <- capture_files(root, directory, files, scope),
         {:ok, node} <- node_executable(),
         {:ok, broker} <-
           PortSession.start_link(
             owner_pid: context.guardian,
             caller_pid: self(),
             node_executable: node,
             helper_path:
               Application.app_dir(:synapsis_core, "priv/filesystem_metadata/stdio.mjs"),
             notification: {context.guardian, context.ref},
             observer_pid: Keyword.get(opts, :observer_pid)
           ) do
      monitor = Process.monitor(broker)
      ack = make_ref()
      send(context.guardian, {context.ref, :planner_register, self(), broker, ack})

      captured =
        receive do
          {:planner_registered, ^ack} ->
            PortSession.capture(
              broker,
              %{"root" => directory, "files" => files, "names" => names},
              context.deadline
            )
        after
          remaining(context.deadline) -> {:error, :timeout}
        end

      retired = retire(broker, monitor, context.deadline)

      with {:ok, envelope} <- captured,
           :ok <- retired,
           :ok <- Local.check_scope(scope),
           {:ok, ^directory, _} <- Local.resolve(root, admitted_path),
           {:ok, ^before} <- capture_files(root, directory, files, scope) do
        {:ok, envelope["result"]}
      else
        {:ok, _} -> {:error, :conflict}
        {:ok, _, _} -> {:error, :conflict}
        error -> error
      end
    end
  end

  defp capture_files(root, directory, files, scope) do
    Enum.reduce_while(files, {:ok, []}, fn relative, {:ok, snapshots} ->
      with :ok <- Local.check_scope(scope),
           true <- relative_file?(relative),
           {:ok, absolute, _} <- Local.resolve(root, Path.join(directory, relative)),
           true <- inside?(directory, absolute),
           {:ok, %{type: :regular, links: 1} = stat} <- File.lstat(absolute, time: :posix) do
        identity =
          Map.take(stat, [:inode, :major_device, :minor_device, :size, :mtime, :ctime, :links])

        {:cont, {:ok, [{relative, identity} | snapshots]}}
      else
        false -> {:halt, {:error, :invalid_input}}
        {:ok, _} -> {:halt, {:error, :not_regular}}
        error -> {:halt, error}
      end
    end)
  end

  defp retire(broker, monitor, deadline) do
    status = PortSession.status(broker)

    with {:ok, ^status} <- PortSession.close(broker) do
      receive do
        {:DOWN, ^monitor, :process, ^broker, :normal} ->
          if completed?(status), do: :ok, else: {:error, :metadata_failed}

        {:DOWN, ^monitor, :process, ^broker, _} ->
          {:error, :metadata_failed}
      after
        remaining(deadline) -> {:error, :timeout}
      end
    end
  end

  defp completed?(%{
         phase: :settled,
         outcome: :completed,
         cleanup_confirmed: true,
         exit_status: 0,
         port_released: true,
         port: port
       })
       when is_port(port),
       do: Port.info(port) == nil

  defp completed?(_), do: false

  defp node_executable do
    configured =
      Application.get_env(:synapsis_agent, :filesystem_node) ||
        System.get_env("SYNAPSIS_FILESYSTEM_NODE") || "node"

    if is_binary(configured) do
      case System.find_executable(configured) do
        node when is_binary(node) -> {:ok, Path.expand(node)}
        _ -> {:error, :helper_unavailable}
      end
    else
      {:error, :helper_unavailable}
    end
  end

  defp relative_file?(path),
    do:
      is_binary(path) and String.valid?(path) and
        Path.type(path) == :relative and not String.contains?(path, ["\\", "\0"]) and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

  defp inside?(root, path), do: List.starts_with?(Path.split(path), Path.split(root))
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
