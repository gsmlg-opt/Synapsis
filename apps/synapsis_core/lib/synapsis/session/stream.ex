defmodule Synapsis.Session.Stream do
  @moduledoc "Manages provider HTTP streaming connections."

  require Logger

  defmodule Ref do
    @moduledoc "Worker-local stream reference used to fence provider events."
    defstruct [:tag, :provider_ref, :proxy_pid]
  end

  @stream_start_timeout_ms 5_000

  def start_stream(request, provider_config, provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, provider_module} ->
        try do
          provider_module.stream(request, provider_config)
        rescue
          e ->
            Logger.warning("provider_stream_crash",
              provider: provider_name,
              error: Exception.message(e)
            )

            {:error, "Provider stream failed"}
        catch
          kind, reason ->
            Logger.warning("provider_stream_throw",
              provider: provider_name,
              kind: kind,
              error: inspect(reason)
            )

            {:error, "Provider stream failed"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_stream(request, provider_config, provider_name, opts) when is_list(opts) do
    case Keyword.get(opts, :forward_to) do
      pid when is_pid(pid) ->
        start_fenced_stream(request, provider_config, provider_name, pid)

      _ ->
        start_stream(request, provider_config, provider_name)
    end
  end

  defp start_fenced_stream(request, provider_config, provider_name, owner) do
    caller = self()
    tag = make_ref()

    case Task.Supervisor.start_child(Synapsis.Provider.TaskSupervisor, fn ->
           run_fenced_stream(caller, owner, tag, request, provider_config, provider_name)
         end) do
      {:ok, proxy_pid} ->
        receive do
          {__MODULE__, ^tag, {:started, stream_ref}} ->
            {:ok, stream_ref}

          {__MODULE__, ^tag, {:error, reason}} ->
            {:error, reason}
        after
          @stream_start_timeout_ms ->
            Process.exit(proxy_pid, :kill)
            {:error, :stream_start_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_fenced_stream(caller, owner, tag, request, provider_config, provider_name) do
    case start_stream(request, provider_config, provider_name) do
      {:ok, provider_ref} ->
        stream_ref = %Ref{tag: tag, provider_ref: provider_ref, proxy_pid: self()}
        send(caller, {__MODULE__, tag, {:started, stream_ref}})
        forward_provider_events(owner, stream_ref)

      {:error, reason} ->
        send(caller, {__MODULE__, tag, {:error, reason}})
    end
  end

  defp forward_provider_events(owner, stream_ref) do
    receive do
      {:provider_chunk, event} ->
        send(owner, {:provider_chunk, stream_ref, event})
        forward_provider_events(owner, stream_ref)

      :provider_done ->
        send(owner, {:provider_done, stream_ref})

      {:provider_error, reason} ->
        send(owner, {:provider_error, stream_ref, reason})

      _other ->
        forward_provider_events(owner, stream_ref)
    end
  end

  def cancel_stream(%Ref{provider_ref: provider_ref, proxy_pid: proxy_pid}, provider_name) do
    cancel_stream(provider_ref, provider_name)

    if is_pid(proxy_pid) and Process.alive?(proxy_pid) do
      Process.exit(proxy_pid, :shutdown)
    end

    :ok
  end

  def cancel_stream(ref, provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, provider_module} ->
        try do
          provider_module.cancel(ref)
        rescue
          e ->
            Logger.warning("provider_cancel_crash",
              provider: provider_name,
              error: Exception.message(e)
            )

            :ok
        end

      {:error, _} ->
        :ok
    end
  end
end
