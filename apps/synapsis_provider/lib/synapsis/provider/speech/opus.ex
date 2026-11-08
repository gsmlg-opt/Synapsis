defmodule Synapsis.Provider.Speech.Opus do
  @moduledoc """
  Invocation-local MP3/WAV-to-Opus conversion using an owned FFmpeg Port.

  A finite stage deadline covers file preparation, the child process and bounded
  output reading. The caller supplies the original whole-operation deadline.
  Normal completion releases Port/monitor messages and temporary files before
  returning bytes. No shell, persistent process or codec dependency is added.
  """

  @max_timeout 2_147_483_647
  @max_bytes 16 * 1024 * 1024

  def transcode(audio, options) when is_binary(audio) and is_list(options) do
    raw_timeout = Keyword.get(options, :timeout_ms)
    ceiling = Keyword.get(options, :timeout_ceiling, @max_timeout)
    extension = Keyword.get(options, :input_extension, "wav")
    prefix = Keyword.get(options, :temp_prefix, "tts-google-")
    absolute = Keyword.get(options, :deadline_ms)
    limit = Keyword.get(options, :max_bytes, @max_bytes)

    with true <- is_number(raw_timeout) and raw_timeout > 0,
         true <- is_integer(ceiling) and ceiling > 0 and ceiling <= @max_timeout,
         true <- extension in ["mp3", "wav"],
         true <- is_binary(prefix) and prefix != "" and Path.basename(prefix) == prefix,
         true <- is_nil(absolute) or is_integer(absolute),
         true <- is_integer(limit) and limit > 0,
         executable when is_binary(executable) <- System.find_executable("ffmpeg") do
      timeout = raw_timeout |> floor() |> max(1) |> min(ceiling)
      whole_deadline = absolute || now() + timeout
      deadline = min(now() + timeout, whole_deadline)
      owner = self()

      task =
        Task.Supervisor.async_nolink(Synapsis.Provider.TaskSupervisor, fn ->
          owned(owner, executable, audio, extension, prefix, deadline, limit)
        end)

      case Task.yield(task, remaining(deadline)) do
        {:ok, result} ->
          result = await_task_exit(task.pid, result, whole_deadline)
          if remaining(deadline) > 0, do: result, else: {:error, :timeout}

        {:exit, _} ->
          {:error, :transcode}

        nil ->
          send(task.pid, {:google_opus_stop, owner})
          grace = min(1000, remaining(whole_deadline))

          case Task.yield(task, grace) do
            nil -> Task.shutdown(task, :brutal_kill)
            _ -> :ok
          end

          {:error, :timeout}
      end
    else
      nil -> {:error, :ffmpeg_unavailable}
      false -> {:error, :invalid_transcode_options}
    end
  rescue
    _ -> {:error, :transcode}
  end

  def transcode(_, _), do: {:error, :invalid_transcode_options}

  defp owned(owner, executable, audio, extension, prefix, deadline, limit) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    directory =
      Path.join(
        System.tmp_dir!(),
        prefix <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    try do
      with :ok <- owner_ready(owner, deadline),
           :ok <- File.mkdir(directory) do
        try do
          transcode_in(directory, executable, audio, extension, deadline, limit, owner, owner_ref)
        after
          File.rm_rf(directory)
        end
      end
    after
      Process.demonitor(owner_ref, [:flush])
    end
  rescue
    _ -> {:error, :transcode}
  end

  defp transcode_in(directory, executable, audio, extension, deadline, limit, owner, owner_ref) do
    input = Path.join(directory, "input." <> extension)
    output = Path.join(directory, "voice.opus")

    with :ok <- owner_ready(owner, deadline),
         :ok <- File.write(input, audio),
         :ok <- owner_ready(owner, deadline) do
      args = [
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        input,
        "-vn",
        "-sn",
        "-dn",
        "-c:a",
        "libopus",
        "-b:a",
        "64k",
        "-ar",
        "48000",
        "-ac",
        "1",
        "-f",
        "opus",
        output
      ]

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: args
        ])

      monitor = :erlang.monitor(:port, port)

      try do
        with :ok <- await(port, monitor, deadline, owner, owner_ref),
             :ok <- owner_ready(owner, deadline),
             {:ok, stat} <- File.stat(output),
             true <- stat.size > 0 and stat.size <= limit,
             {:ok, bytes} <- bounded_read(output, limit),
             :ok <- owner_ready(owner, deadline) do
          {:ok, bytes}
        else
          false -> {:error, :transcode_output_size}
          {:error, _} = error -> error
        end
      after
        close(port)
        :erlang.demonitor(monitor, [:flush])
        drain(port)
      end
    end
  end

  defp await(port, monitor, deadline, owner, owner_ref) do
    receive do
      {^port, {:data, _bytes}} ->
        await(port, monitor, deadline, owner, owner_ref)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _status}} ->
        {:error, :transcode_exit}

      {:DOWN, ^monitor, :port, ^port, :normal} ->
        await(port, monitor, deadline, owner, owner_ref)

      {:DOWN, ^monitor, :port, ^port, _reason} ->
        {:error, :transcode_exit}

      {:EXIT, ^port, :normal} ->
        await(port, monitor, deadline, owner, owner_ref)

      {:EXIT, ^port, _reason} ->
        {:error, :transcode_exit}

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        {:error, :caller_exit}

      {:google_opus_stop, ^owner} ->
        {:error, :timeout}

      {:EXIT, _supervisor, _reason} ->
        {:error, :transcode_shutdown}
    after
      remaining(deadline) -> {:error, :timeout}
    end
  end

  defp bounded_read(path, limit) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, limit + 1) do
            bytes when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
            _ -> {:error, :transcode_output_size}
          end
        after
          File.close(file)
        end

      {:error, _} ->
        {:error, :transcode_io}
    end
  end

  defp close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp drain(port) do
    receive do
      {^port, _message} -> drain(port)
      {:EXIT, ^port, _reason} -> drain(port)
    after
      0 -> :ok
    end
  end

  defp owner_ready(owner, deadline) do
    if Process.alive?(owner), do: within_deadline(deadline), else: {:error, :caller_exit}
  end

  defp await_task_exit(pid, result, deadline) do
    monitor = Process.monitor(pid)

    try do
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> result
      after
        remaining(deadline) -> {:error, :timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp within_deadline(deadline),
    do: if(remaining(deadline) > 0, do: :ok, else: {:error, :timeout})

  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end
