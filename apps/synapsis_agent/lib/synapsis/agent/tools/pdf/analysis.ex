defmodule Synapsis.Agent.Tools.PDF.Analysis do
  @moduledoc "One owned streaming attempt per configured candidate; no ambiguous paid-call replay."

  alias Synapsis.Agent.Tools.PDF.Model
  alias Synapsis.Provider.{Adapter, ToolName}

  @max_output 16_384
  @max_body 32 * 1024 * 1024

  def run(candidate, parts, deadline) do
    owner = self()

    task =
      Task.Supervisor.async(Synapsis.Provider.TaskSupervisor, fn ->
        attempt(owner, candidate, parts, deadline)
      end)

    case Task.yield(task, max(0, deadline - now())) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :unknown_outcome}
    end
  end

  defp attempt(owner, candidate, parts, deadline) do
    Process.flag(:trap_exit, true)
    owner_ref = Process.monitor(owner)

    try do
      with true <- Process.alive?(owner) and now() < deadline,
           {:ok, runtime} <- Model.runtime(candidate),
           {:ok, request} <-
             Adapter.format_request([%{role: "user", parts: parts}], [], %{
               model: candidate.model,
               max_tokens: candidate.max_tokens,
               provider_type: runtime[:type] || runtime["type"],
               provider_name: candidate.provider,
               base_url: runtime[:base_url] || runtime["base_url"],
               endpoint: runtime[:base_url] || runtime["base_url"]
             }),
           :ok <- body_budget(request),
           true <- Process.alive?(owner) and now() < deadline,
           {:ok, handle} <- Adapter.stream(request, runtime, link: true) do
        try do
          collect(handle, owner_ref, deadline, [], 0)
        after
          close(handle)
        end
      else
        false -> {:error, :unknown_outcome}
        {:error, %Backplane.AiProtocol.Error{} = error} -> terminal(error)
        {:error, _} -> {:error, {:terminal, :model_unavailable}}
      end
    after
      Process.demonitor(owner_ref, [:flush])
    end
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  # Bound serialized HTTP content independently of the codec's canonical PDF
  # collection budget. The encoded request also includes Google's targeting fields,
  # so this is a conservative bound for the body sent by the shared adapter.
  defp body_budget(request) do
    {request, _aliases} = ToolName.pop_aliases(request)

    case Jason.encode(request) do
      {:ok, body} when byte_size(body) <= @max_body -> :ok
      _ -> {:error, :request_body_limit}
    end
  end

  defp collect(handle, owner_ref, deadline, chunks, size) do
    receive do
      {:provider_chunk, {:text_delta, text}} when is_binary(text) ->
        if size + byte_size(text) <= @max_output and String.valid?(text),
          do: collect(handle, owner_ref, deadline, [text | chunks], size + byte_size(text)),
          else: {:error, :output_limit}

      {:provider_chunk, _} ->
        collect(handle, owner_ref, deadline, chunks, size)

      :provider_done ->
        text = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
        if text != "" and now() < deadline, do: {:ok, text}, else: {:error, :analysis_unavailable}

      {:provider_error, error} ->
        terminal(error)

      {:DOWN, ^owner_ref, :process, _, _} ->
        {:error, :unknown_outcome}

      {:DOWN, ref, :process, _, _} when ref == handle.ref ->
        {:error, :unknown_outcome}

      {:EXIT, pid, :normal} when pid == handle.pid ->
        collect(handle, owner_ref, deadline, chunks, size)

      {:EXIT, _, _} ->
        {:error, :unknown_outcome}

      {ref, _} when ref == handle.ref ->
        collect(handle, owner_ref, deadline, chunks, size)
    after
      max(0, deadline - now()) -> {:error, :unknown_outcome}
    end
  end

  # Only a canonical known or definitely unsubmitted failure admits the next
  # explicitly configured model. Transport ambiguity never spends again.
  defp terminal(%Backplane.AiProtocol.Error{upstream_outcome: outcome, kind: kind})
       when outcome in [:known, :not_submitted] and
              kind in [
                :invalid_request,
                :authentication,
                :authorization,
                :not_found,
                :rate_limited,
                :upstream_error,
                :incompatible
              ],
       do: {:error, {:terminal, :provider_rejected}}

  defp terminal(_), do: {:error, :unknown_outcome}

  defp close(handle) do
    Process.unlink(handle.pid)
    Adapter.cancel(handle)
    Process.demonitor(handle.ref, [:flush])
    drain(handle)
  end

  defp drain(handle) do
    receive do
      {:provider_chunk, _} -> drain(handle)
      :provider_done -> drain(handle)
      {:provider_error, _} -> drain(handle)
      {ref, _} when ref == handle.ref -> drain(handle)
      {:EXIT, pid, _} when pid == handle.pid -> drain(handle)
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
