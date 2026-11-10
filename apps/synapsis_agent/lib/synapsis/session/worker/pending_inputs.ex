defmodule Synapsis.Session.Worker.PendingInputs do
  @moduledoc """
  Worker-owned, asynchronous pending-input persistence lane.

  A single supervised task owns each mutation. Acknowledged durable staging is
  inserted into live event ownership before its caller is replied to. The lane
  holds a barrier after dispatched uncertainty, including a task wait deadline;
  it never interprets task cancellation or caller timeout as database rollback.
  """

  alias Synapsis.Session.PendingInputStore
  alias Synapsis.Session.Worker.{Persistence, Runtime}

  @queue_limit 64
  @event_limit 20

  defstruct owner_id: nil,
            task: nil,
            queue: [],
            deferred_actions: [],
            booted: false,
            blocked: false,
            drain: false,
            suspended: false,
            events: MapSet.new(),
            current: nil

  def new, do: %__MODULE__{owner_id: Ecto.UUID.generate()}

  def boot(data), do: enqueue(data, operation(:recover))

  def prompt(data, content, images, from, input_context \\ nil) do
    lane = %{data.pending_inputs | suspended: false}

    enqueue(
      %{data | pending_inputs: lane},
      operation(:prompt, from, %{content: content, images: images, input_context: input_context})
    )
  end

  def steer(data, content, from),
    do: enqueue(data, operation(:steer, from, %{content: content}))

  def cancel_steers(data), do: enqueue(data, operation(:cancel_steers))

  def wake(data, text, opts, from) do
    lane = data.pending_inputs

    reservations =
      Enum.count(lane.queue, &(&1.kind == :wake)) +
        if(lane.task && lane.task.op.kind == :wake, do: 1, else: 0)

    cond do
      data.agent[:id] != Keyword.fetch!(opts, :target_agent_id) ->
        {data, [{:reply, from, {:error, :agent_mismatch}}]}

      MapSet.size(lane.events) + reservations >= @event_limit ->
        {data, [{:reply, from, {:error, :queue_full}}]}

      true ->
        attrs = %{
          content: text,
          owner_id: lane.owner_id,
          target_agent_id: data.agent.id,
          mode: Keyword.get(opts, :mode, "next-heartbeat"),
          input_provenance: %{
            "kind" => "internal_system",
            "source_tool" => "cron",
            "source_session_id" => Keyword.fetch!(opts, :source_session_id),
            "source_agent_id" => Keyword.fetch!(opts, :source_agent_id)
          }
        }

        op = operation(:wake, from, %{attrs: attrs})

        enqueue(data, %{
          op
          | deadline: min(op.deadline, Keyword.get(opts, :deadline, op.deadline))
        })
    end
  end

  def busy?(%{pending_inputs: nil}), do: false

  def busy?(%{pending_inputs: lane}) do
    not lane.booted or lane.blocked or not is_nil(lane.task) or lane.queue != [] or
      not is_nil(lane.current) or (lane.drain and not lane.suspended)
  end

  @doc """
  True while the lane only reconciles its durable queue (boot or post-run drain)
  with no input queued or running. Control calls wait for this to settle.
  """
  def settling?(%{pending_inputs: nil}), do: false

  def settling?(%{pending_inputs: lane} = data) do
    not data.runtime_active and is_nil(lane.current) and lane.queue == [] and not lane.blocked and
      (not lane.booted or not is_nil(lane.task))
  end

  def changing_agent?(%{pending_inputs: nil}), do: false
  def changing_agent?(data), do: busy?(data) or MapSet.size(data.pending_inputs.events) > 0

  @doc false
  def idle?(%{pending_inputs: nil}), do: false
  def idle?(data), do: not busy?(data) and direct_ready?(data)

  def advance(data) do
    actions = data.pending_inputs.deferred_actions
    data = %{data | pending_inputs: %{data.pending_inputs | deferred_actions: []}}
    {data, more} = advance_lane(data)
    deferred = data.pending_inputs.deferred_actions
    data = %{data | pending_inputs: %{data.pending_inputs | deferred_actions: []}}
    {data, actions ++ more ++ deferred}
  end

  defp advance_lane(data) do
    lane = data.pending_inputs

    cond do
      lane.blocked or not is_nil(lane.task) ->
        {data, []}

      lane.queue != [] ->
        [op | rest] = lane.queue
        data = %{data | pending_inputs: %{lane | queue: rest}}

        cond do
          op.deadline <= now() ->
            expire_queued(data, op)

          op.kind == :prompt and direct_ready?(data) and not lane.drain ->
            direct_prompt(data, op)

          true ->
            {start_task(data, op), []}
        end

      not lane.booted or lane.suspended or not turn_ready?(data) ->
        {data, []}

      match?(%{phase: :selected}, lane.current) ->
        start_selected(data)

      is_nil(lane.current) and lane.drain ->
        {data, actions} = enqueue(data, operation(:take))
        {data, more} = advance(data)
        {data, actions ++ more}

      true ->
        {data, []}
    end
  end

  defp direct_ready?(data) do
    data.pending_inputs.booted and is_nil(data.pending_inputs.current) and
      MapSet.size(data.pending_inputs.events) == 0 and turn_ready?(data)
  end

  defp turn_ready?(data) do
    not data.runtime_active and is_nil(data.runtime_task) and
      is_nil(data.automation_task) and data.automation_pending == [] and
      not data.automation_uncertain and data.stream_ref == nil and data.pending_tool_count == 0 and
      MapSet.size(data.pending_approvals) == 0 and is_nil(data.query_loop_task) and
      Synapsis.Session.Worker.engine_ready?(data)
  end

  defp direct_prompt(data, op) do
    input =
      if context = op.payload.input_context do
        %{kind: "prompt", id: context["input_id"], input_provenance: context}
      end

    case Runtime.start_turn(data, op.payload.content, op.payload.images, input) do
      {:ok, data} ->
        {data, more} = advance(data)
        {data, reply(op, :ok) ++ more}

      {:error, reason} ->
        {data, more} = advance(data)
        {data, reply(op, {:error, reason}) ++ more}
    end
  end

  defp start_selected(data) do
    input = data.pending_inputs.current.input

    if input.kind == "system_event" and input.event["target_agent_id"] != data.agent[:id] do
      {pause(data), []}
    else
      case Runtime.start_turn(data, input.content, input.image_parts, input) do
        {:ok, data} ->
          current = %{data.pending_inputs.current | phase: :preparing, epoch: data.runtime_epoch}
          {%{data | pending_inputs: %{data.pending_inputs | current: current}}, []}

        {:error, reason} ->
          Persistence.broadcast(data.session_id, "error", %{message: inspect(reason)})
          {pause(data), []}
      end
    end
  end

  def adopt(%{pending_inputs: nil} = data, _event), do: data

  def adopt(data, %{mode: :new, message: message}) do
    lane = data.pending_inputs

    case lane.current do
      %{phase: :preparing, epoch: epoch, run_id: run_id, input: input} = current
      when epoch == data.runtime_epoch and run_id == data.runtime_run_id and is_binary(run_id) ->
        current = %{
          current
          | phase: :started,
            run_id: data.runtime_run_id,
            message_id: message.id
        }

        lane = %{lane | current: current, events: MapSet.delete(lane.events, input.id)}
        kind = if input.kind == "system_event", do: :start, else: :consume

        {data, actions} =
          enqueue(
            %{data | pending_inputs: lane},
            operation(kind, nil, %{input: input, run_id: data.runtime_run_id})
          )

        defer(data, actions)

      _ ->
        data
    end
  end

  def adopt(data, _event), do: data

  def started(%{pending_inputs: nil} = data, _run_id), do: data

  def started(data, run_id) do
    lane = data.pending_inputs

    case lane.current do
      %{phase: :preparing, epoch: epoch, run_id: nil} = current
      when epoch == data.runtime_epoch ->
        %{data | pending_inputs: %{lane | current: %{current | run_id: run_id}}}

      _ ->
        data
    end
  end

  def terminal(%{pending_inputs: nil} = data, _type), do: data

  def terminal(data, type) do
    lane = data.pending_inputs

    case lane.current do
      %{phase: :started, input: %{kind: "system_event"} = input} = current ->
        outcome = if type == :run_completed, do: :completed, else: :failed
        lane = %{lane | current: %{current | phase: :finishing}, drain: true}

        {data, actions} =
          enqueue(
            %{data | pending_inputs: lane},
            operation(:finish, nil, %{input: input, outcome: outcome})
          )

        defer(data, actions)

      %{input: %{kind: "system_event"}} ->
        pause(data)

      _ ->
        %{data | pending_inputs: %{lane | current: nil, drain: type == :run_completed}}
    end
  end

  def failed(%{pending_inputs: nil} = data), do: data

  def failed(data) do
    lane = data.pending_inputs
    unresolved = not is_nil(lane.current) and lane.current.phase != :finishing
    data = if lane.blocked or unresolved, do: pause(data), else: data
    lane = data.pending_inputs

    %{
      data
      | pending_inputs: %{
          lane
          | suspended: true,
            drain: false
        }
    }
  end

  defp pause(data) do
    {data, actions} = barrier(data, nil, :unknown_outcome)
    defer(data, actions)
  end

  defp defer(data, actions) do
    lane = data.pending_inputs
    # A barrier drains at most the bounded queue plus its one active caller;
    # it clears those handles before any later barrier can capture them again.
    %{data | pending_inputs: %{lane | deferred_actions: lane.deferred_actions ++ actions}}
  end

  defp enqueue(data, op) do
    lane = data.pending_inputs

    cond do
      lane.blocked ->
        {data, reply(op, {:error, :unknown_outcome})}

      length(lane.queue) + if(lane.task, do: 1, else: 0) >= @queue_limit ->
        if is_nil(op.from),
          do: barrier(data, op, :queue_full),
          else: {data, reply(op, {:error, :queue_full})}

      true ->
        {%{data | pending_inputs: %{lane | queue: lane.queue ++ [op]}}, []}
    end
  end

  defp operation(kind, from \\ nil, payload \\ %{}),
    do: %{kind: kind, from: from, payload: payload, deadline: now() + 5_000}

  defp start_task(data, op) do
    id = data.session_id
    owner_id = data.pending_inputs.owner_id

    task =
      Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
        execute(id, owner_id, op)
      end)

    timer =
      Process.send_after(self(), {:pending_input_timeout, task.ref}, max(op.deadline - now(), 1))

    %{
      data
      | pending_inputs: %{
          data.pending_inputs
          | task: %{task: task, op: op, timer: timer, expired: false}
        }
    }
  end

  defp execute(id, owner_id, %{kind: :recover, deadline: deadline}) do
    with :ok <- PendingInputStore.recover_for_owner(id, owner_id, deadline: deadline),
         {:ok, inputs} <- PendingInputStore.list_result(id, deadline: deadline) do
      {:ok, inputs}
    end
  end

  defp execute(id, _owner_id, %{kind: :prompt, payload: payload, deadline: deadline}) do
    opts =
      if context = payload.input_context do
        [deadline: deadline, id: context["input_id"], input_provenance: context]
      else
        [deadline: deadline]
      end

    PendingInputStore.append_prompt(id, payload.content, payload.images, opts)
  end

  defp execute(id, _owner_id, %{kind: :steer, payload: payload, deadline: deadline}),
    do: PendingInputStore.append_steer(id, payload.content, deadline: deadline)

  defp execute(id, _owner_id, %{kind: :wake, payload: payload, deadline: deadline}),
    do: PendingInputStore.append_event(id, payload.attrs, deadline: deadline)

  defp execute(id, owner_id, %{kind: :take, deadline: deadline}),
    do: PendingInputStore.take_next_turn(id, owner_id, deadline: deadline)

  defp execute(id, owner_id, %{kind: :start, payload: payload, deadline: deadline}),
    do:
      PendingInputStore.start_event(id, payload.input.id, owner_id, payload.run_id,
        deadline: deadline
      )

  defp execute(id, _owner_id, %{kind: :consume, payload: payload, deadline: deadline}),
    do: PendingInputStore.mark_consumed(id, payload.input.id, deadline: deadline)

  defp execute(id, owner_id, %{kind: :finish, payload: payload, deadline: deadline}),
    do:
      PendingInputStore.finish_event(id, payload.input.id, owner_id, payload.outcome,
        deadline: deadline
      )

  defp execute(id, _owner_id, %{kind: :cancel_steers, deadline: deadline}),
    do: PendingInputStore.cancel_steers(id, deadline: deadline)

  def result(data, result) do
    pending = data.pending_inputs.task
    Process.cancel_timer(pending.timer)
    lane = %{data.pending_inputs | task: nil}
    data = %{data | pending_inputs: lane}

    cond do
      pending.expired or lane.blocked -> {data, []}
      pending.op.deadline <= now() -> barrier(data, pending.op, :unknown_outcome)
      true -> apply_result(data, pending.op, result)
    end
  end

  defp apply_result(data, %{kind: :recover}, {:ok, inputs}) do
    lane = %{
      data.pending_inputs
      | booted: true,
        drain: Enum.any?(inputs, &(&1.kind == "prompt" and &1.status == "queued"))
    }

    {%{data | pending_inputs: lane}, []}
  end

  defp apply_result(data, %{kind: kind} = op, {:ok, input})
       when kind in [:prompt, :steer, :wake] do
    Persistence.broadcast(
      data.session_id,
      "input_queued",
      Map.take(input, [:id, :kind, :content])
    )

    lane = data.pending_inputs
    lane = %{lane | drain: lane.drain or kind != :steer}

    if kind == :wake do
      # Live ownership insertion precedes the accepted reply action.
      lane = %{lane | events: MapSet.put(lane.events, input.id)}
      result = {:ok, %{event_id: input.id, accepted: true, target_session_id: data.session_id}}
      {%{data | pending_inputs: lane}, reply(op, result)}
    else
      {%{data | pending_inputs: lane}, reply(op, :ok)}
    end
  end

  defp apply_result(data, %{kind: :take}, {:ok, input}) do
    lane = data.pending_inputs

    if input.kind == "system_event" and not MapSet.member?(lane.events, input.id) do
      {pause(data), []}
    else
      current = %{input: input, phase: :selected, epoch: nil, run_id: nil, message_id: nil}
      {%{data | pending_inputs: %{lane | current: current, drain: false}}, []}
    end
  end

  defp apply_result(data, %{kind: :take}, :empty),
    do: {%{data | pending_inputs: %{data.pending_inputs | drain: false}}, []}

  defp apply_result(data, %{kind: kind, payload: %{input: input}}, :ok)
       when kind in [:start, :consume] do
    Persistence.broadcast(
      data.session_id,
      "input_started",
      Map.take(input, [:id, :kind, :content])
    )

    {data, []}
  end

  defp apply_result(data, %{kind: :finish}, :ok),
    do: {%{data | pending_inputs: %{data.pending_inputs | current: nil}}, []}

  defp apply_result(data, %{kind: :cancel_steers}, :ok), do: {data, []}

  defp apply_result(data, op, {:error, reason}) do
    if reason in [:unknown_outcome, :timeout] or
         op.kind in [:recover, :take, :start, :consume, :finish] do
      barrier(data, op, reason)
    else
      {data, reply(op, {:error, reason})}
    end
  end

  defp apply_result(data, op, _other), do: barrier(data, op, :unknown_outcome)

  def timeout(data) do
    pending = data.pending_inputs.task
    {data, actions} = barrier(data, pending.op, :unknown_outcome)
    pending = %{pending | expired: true, op: %{pending.op | from: nil}}
    {%{data | pending_inputs: %{data.pending_inputs | task: pending}}, actions}
  end

  defp expire_queued(data, op) do
    if is_nil(op.from) do
      barrier(data, op, :timeout)
    else
      {data, more} = advance(data)
      {data, reply(op, {:error, :timeout}) ++ more}
    end
  end

  defp barrier(data, op, reason) do
    pending = data.pending_inputs.task

    actions =
      (reply(op, {:error, reason}) ++
         Enum.flat_map(data.pending_inputs.queue, &reply(&1, {:error, :unknown_outcome})) ++
         if(pending, do: reply(pending.op, {:error, :unknown_outcome}), else: []))
      |> Enum.uniq_by(&elem(&1, 1))

    pending = if pending, do: %{pending | op: %{pending.op | from: nil}}
    lane = %{data.pending_inputs | blocked: true, queue: [], task: pending}

    Persistence.broadcast(data.session_id, "error", %{
      message: "Pending input outcome requires recovery"
    })

    {%{data | pending_inputs: lane}, actions}
  end

  def stop(%{pending_inputs: nil}), do: :ok

  def stop(data) do
    if data.pending_inputs.task do
      pending = data.pending_inputs.task
      Process.cancel_timer(pending.timer)
      # Shutdown is not a rollback acknowledgement. Prior-owner events are
      # retired on the next boot even if a dispatched write finishes late.
      Task.shutdown(pending.task, :brutal_kill)
    end

    :ok
  end

  defp reply(nil, _result), do: []
  defp reply(%{from: nil}, _result), do: []
  defp reply(%{from: from}, result), do: [{:reply, from, result}]
  defp now, do: System.monotonic_time(:millisecond)
end
