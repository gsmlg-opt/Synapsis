defmodule Synapsis.Session.Worker.SuggestedTurn do
  @moduledoc "Fresh host launch handshake at the existing Worker's native admission boundary."

  alias Synapsis.Session.InputContext
  alias Synapsis.Session.Worker.{PendingInputs, Runtime}

  def request(session_id, request, opts) when is_list(opts) do
    ceiling = now() + 30_000

    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))) and
         is_integer(Keyword.get(opts, :deadline, ceiling)) do
      deadline = min(Keyword.get(opts, :deadline, ceiling), ceiling)

      if deadline > now() do
        :gen_statem.call(
          {:via, Registry, {Synapsis.Session.Registry, session_id}},
          {:start_suggested_turn, request, deadline},
          max(deadline - now(), 1)
        )
      else
        {:error, :timeout}
      end
    else
      {:error, :invalid_input}
    end
  catch
    :exit, _ -> {:error, :unknown_outcome}
  end

  def request(_, _, _), do: {:error, :invalid_input}

  def start(data, request, from, deadline) do
    with :ok <- valid_request(data, request),
         true <- deadline > now(),
         true <- is_nil(data.suggested_turn),
         true <- PendingInputs.idle?(data),
         false <- Map.has_key?(data.runtime_roster, :root),
         false <- data.runtime_roster[:recovery_required] == true,
         false <- Map.has_key?(data.runtime_roster, :error) do
      input = %{
        kind: "prompt",
        id: request.input_context["input_id"],
        input_provenance: request.input_context
      }

      marker = %{
        request: request,
        from: from,
        monitor: Process.monitor(elem(from, 0)),
        timer:
          Process.send_after(
            self(),
            {:suggested_turn_timeout, request.claim_id},
            max(deadline - now(), 0)
          ),
        deadline: deadline,
        epoch: nil,
        run_id: nil,
        status: :preparing
      }

      case Runtime.start_turn(%{data | suggested_turn: marker}, request.content, [], input) do
        {:ok, next} ->
          marker = %{marker | epoch: next.runtime_epoch}
          {%{next | suggested_turn: marker}, []}

        {:error, _reason} ->
          {settle(%{data | suggested_turn: marker}, {:error, :unknown_outcome}), []}
      end
    else
      _ -> {data, [{:reply, from, {:error, :not_fresh}}]}
    end
  end

  def started(%{suggested_turn: %{status: :preparing, epoch: epoch} = marker} = data, run_id)
      when epoch == data.runtime_epoch do
    %{data | suggested_turn: %{marker | run_id: run_id}}
  end

  def started(data, _), do: data

  def consumed(
        %{suggested_turn: %{status: :preparing, epoch: epoch, run_id: run_id} = marker} = data,
        %{mode: :new, message: %{id: message_id, content: content}, turn_id: turn_id}
      )
      when epoch == data.runtime_epoch and run_id == data.runtime_run_id and is_binary(run_id) and
             is_binary(message_id) and is_binary(turn_id) do
    if content == [%{type: :text, text: marker.request.content}] do
      receipt = %{
        status: :started,
        session_id: data.session_id,
        run_id: run_id,
        turn_id: turn_id,
        message_id: message_id,
        input_id: marker.request.input_context["input_id"]
      }

      settle(data, {:ok, receipt})
    else
      settle(data, {:error, :unknown_outcome})
    end
  end

  def consumed(data, _), do: data

  def failed(%{suggested_turn: %{status: :preparing}} = data),
    do: settle(data, {:error, :unknown_outcome})

  def failed(data), do: data

  def timeout(%{suggested_turn: %{request: %{claim_id: id}, status: :preparing}} = data, id),
    do: settle(data, {:error, :unknown_outcome})

  def timeout(data, _), do: data

  def caller_down(%{suggested_turn: %{monitor: ref, status: :preparing}} = data, ref),
    do: settle(data, {:error, :unknown_outcome})

  def caller_down(data, _), do: data

  defp settle(%{suggested_turn: marker} = data, result) do
    Process.cancel_timer(marker.timer)
    Process.demonitor(marker.monitor, [:flush])
    :gen_statem.reply(marker.from, result)

    marker =
      marker
      |> Map.put(:from, nil)
      |> Map.put(:monitor, nil)
      |> Map.put(:timer, nil)
      |> Map.put(:status, if(match?({:ok, _}, result), do: :started, else: :unknown_outcome))
      |> Map.put(:result, result)

    %{data | suggested_turn: marker}
  end

  defp valid_request(data, request) when is_map(request) and not is_struct(request) do
    context = (data.session.config || %{})["creation_context"]

    with true <-
           Map.keys(request) --
             [:task_id, :source_session_id, :claim_id, :content, :input_context] == [],
         true <- is_map(context),
         true <- context["version"] == 1 and context["kind"] == "task_suggestion",
         true <- context["task_id"] == request[:task_id],
         true <- context["source_session_id"] == request[:source_session_id],
         true <- is_binary(context["cwd"]) and Path.type(context["cwd"]) == :absolute,
         true <- Path.expand(context["cwd"]) == data.project_path,
         true <- opaque?(request[:claim_id]) and opaque?(request[:content]),
         true <- is_map(request[:input_context]),
         :ok <- InputContext.validate(request[:input_context], data.session_id),
         true <- request.input_context["kind"] == "operator" do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp valid_request(_, _), do: {:error, :invalid_input}

  defp opaque?(value),
    do: is_binary(value) and byte_size(value) in 1..131_072 and String.valid?(value)

  defp now, do: System.monotonic_time(:millisecond)
end
