defmodule Synapsis.Agent.Automation.Execution do
  @moduledoc """
  Versioned automation context and completed source-result delivery.

  The daemon owns execution and task budgets. These helpers use its frozen Run
  metadata and the existing Session owner; observational events are not durable
  delivery receipts or a retry queue.
  """

  alias Synapsis.Agent.RunEvents

  @config_fields ~w(automation_contract_version automation_origin session_target wake_mode delivery)a
  @empty_summary ~r/\A[\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}]*\z/u
  @job_fields ~w(id name prompt schedule timezone enabled agent_name automation_contract_version
    automation_origin session_target wake_mode delivery provider model deleteAfterRun
    max_runtime_ms no_overlap createdAtMs)a

  @doc "Capture execution fields beside the scheduler's canonical source metadata."
  def metadata(config, base_metadata) do
    if value(config, :automation_contract_version) === 1 do
      custom = value(config, :metadata, %{})
      custom = if is_map(custom), do: stringify_keys(custom), else: %{}

      captured =
        custom
        |> Map.drop(
          ~w(automation_ref automation_job automation_delivery automation_completion_status routine_schedule routine_name heartbeat_name)
        )
        |> Map.merge(base_metadata)
        |> Map.drop(Enum.map(@config_fields, &Atom.to_string/1))

      captured =
        Enum.reduce(@config_fields, captured, fn key, acc ->
          case fetch(config, key) do
            {:ok, field} -> Map.put(acc, Atom.to_string(key), field)
            :error -> acc
          end
        end)

      capture_job(config, base_metadata, captured)
    else
      base_metadata
    end
  end

  defp capture_job(config, base_metadata, captured) do
    case base_metadata["automation_ref"] do
      %{"source" => source, "id" => id} when source in ["routine", "heartbeat"] ->
        if value(config, :id) == id and is_binary(id) do
          job =
            Enum.reduce(@job_fields, %{"id" => id, "source" => source}, fn key, job ->
              case fetch(config, key) do
                {:ok, nil} -> job
                {:ok, field} -> Map.put(job, Atom.to_string(key), field)
                :error -> job
              end
            end)

          Map.put(captured, "automation_job", job)
        else
          Map.delete(captured, "automation_job")
        end

      _ ->
        Map.delete(captured, "automation_job")
    end
  end

  @doc false
  def automated?(%{kind: kind, metadata: metadata}) when kind in ["schedule", "heartbeat"],
    do: value(metadata, :automation_contract_version) === 1

  def automated?(_run), do: false

  @doc false
  def webhook?(run), do: automated?(run) and delivery_mode(run) == "webhook"

  @doc "Construct a primary completion only from the admitted Run snapshot."
  def webhook_request(run, outcome, session_id) do
    job = value(run.metadata, :automation_job)
    ref = value(run.metadata, :automation_ref)
    delivery = value(run.metadata, :delivery, %{})
    target = value(delivery, :to)

    cond do
      not is_map(job) or not is_map(ref) or job["id"] != ref["id"] or
        job["source"] != ref["source"] or job["delivery"] != delivery or
          not is_binary(target) ->
        {:settled,
         %{"status" => "unknown", "attempted" => false, "error" => "webhook_snapshot_unavailable"}}

      match?({:ok, text} when is_binary(text), outcome) and
          Regex.match?(@empty_summary, elem(outcome, 1)) ->
        {:settled,
         %{
           "status" => "not-delivered",
           "delivered" => false,
           "attempted" => false,
           "suppression_reason" => "empty"
         }}

      true ->
        trace = %{"to" => target, "source" => "explicit"}

        started =
          if match?(%DateTime{}, run.started_at),
            do: DateTime.to_unix(run.started_at, :millisecond)

        now = System.system_time(:millisecond)
        job = if started, do: Map.put(job, "state", %{"runningAtMs" => started}), else: job

        event = %{
          "jobId" => job["id"],
          "action" => "finished",
          "job" => job,
          "status" => if(match?({:ok, _}, outcome), do: "ok", else: "error"),
          "delivered" => true,
          "deliveryStatus" => "delivered",
          "delivery" => %{
            "intended" => trace,
            "delivered" => true,
            "resolved" => Map.put(trace, "ok", true)
          }
        }

        event =
          if started,
            do: Map.merge(event, %{"runAtMs" => started, "durationMs" => max(now - started, 0)}),
            else: event

        event = if is_binary(session_id), do: Map.put(event, "sessionId", session_id), else: event
        event = if is_binary(run.model), do: Map.put(event, "model", run.model), else: event

        event =
          if is_binary(run.provider), do: Map.put(event, "provider", run.provider), else: event

        event =
          case outcome do
            {:ok, text} -> Map.put(event, "summary", text)
            {:error, reason} -> Map.put(event, "error", bounded_error(reason))
          end

        {:post, target, Jason.encode!(event)}
    end
  end

  @doc "Retain the strongest acknowledged delivery fact beside the core result."
  def settle_webhook(run, outcome, observation) do
    previous = value(run.metadata, :automation_delivery, %{})
    observation = if previous["status"] == "delivered", do: previous, else: observation
    target = run.metadata |> value(:delivery, %{}) |> value(:to)
    delivery = Map.put(observation, "mode", "webhook")

    delivery =
      if is_binary(target) do
        trace = %{"to" => target, "source" => "explicit"}
        delivery = Map.put(delivery, "intended", trace)

        if Map.has_key?(delivery, "delivered"),
          do: Map.put(delivery, "resolved", Map.put(trace, "ok", delivery["delivered"])),
          else: delivery
      else
        delivery
      end

    completion =
      cond do
        match?({:error, _}, outcome) ->
          "failed"

        not match?({:ok, _}, outcome) ->
          "unknown"

        delivery["status"] == "delivered" or delivery["suppression_reason"] == "empty" ->
          "succeeded"

        delivery["status"] == "unknown" ->
          "unknown"

        true ->
          "failed"
      end

    metadata =
      run.metadata
      |> Map.put("automation_delivery", delivery)
      |> Map.put("automation_completion_status", completion)

    case outcome do
      {:ok, summary} ->
        output = %{"kind" => run.kind, "status" => "completed", "summary" => summary}
        %{run | metadata: Map.put(metadata, "output", output), summary: summary}

      {:error, reason} ->
        output = %{"kind" => run.kind, "status" => "failed", "error" => bounded_error(reason)}
        %{run | metadata: Map.put(metadata, "output", output), error: bounded_error(reason)}

      _ ->
        %{run | metadata: metadata}
    end
  end

  @doc false
  def interrupted_webhook(run) do
    previous = value(run.metadata, :automation_delivery, %{})

    observation =
      case previous do
        %{"status" => "not-delivered", "delivered" => false, "http_status" => status}
        when is_integer(status) ->
          # The owner acknowledged an HTTP rejection before cleanup. Losing
          # that owner cannot turn the received response into uncertainty.
          previous

        %{"attempted" => false} ->
          Map.put(previous, "error", "webhook_owner_lost")

        _ ->
          unknown = %{"status" => "unknown", "error" => "webhook_owner_lost"}

          if is_boolean(previous["attempted"]),
            do: Map.put(unknown, "attempted", previous["attempted"]),
            else: unknown
      end

    core =
      case value(run.metadata, :output, %{}) do
        %{"status" => "completed", "summary" => summary} when is_binary(summary) -> {:ok, summary}
        %{"status" => "failed", "error" => error} when is_binary(error) -> {:error, error}
        _ -> :unknown
      end

    settle_webhook(run, core, observation)
  end

  defp bounded_error(reason) do
    text =
      if is_binary(reason), do: reason, else: inspect(reason, limit: 10, printable_limit: 500)

    String.slice(text, 0, 500)
  end

  @doc "Prepare optional exact-source context without continuing that source's turn."
  def prepare(run, sessions, base_prompt) do
    if automated?(run) do
      {block, observation} = context(run, sessions)

      prompt =
        if is_binary(block) and block != "", do: block <> "\n\n" <> base_prompt, else: base_prompt

      {prompt, Map.put(run.metadata, "automation_context", observation)}
    else
      {base_prompt, run.metadata}
    end
  end

  @doc "Record intended delivery before the terminal Run transition is persisted."
  def delivery_metadata(run) do
    cond do
      webhook?(run) ->
        run.metadata

      automated?(run) ->
        status = if delivery_mode(run) == "none", do: "suppressed", else: "pending"
        Map.put(run.metadata, "automation_delivery", delivery_observation(run, status))

      true ->
        run.metadata
    end
  end

  @doc "Attempt completed delivery once; a deferred acknowledgement remains ephemeral."
  def deliver(run, sessions, timeout) do
    observation =
      case delivery_mode(run) do
        "none" -> delivery_observation(run, "suppressed")
        "announce" -> announce(run, sessions, timeout)
        _ -> delivery_observation(run, "unavailable")
      end

    RunEvents.append_observational(run, "automation.delivery", observation)

    case observation["status"] do
      "unknown_outcome" -> {:error, :automation_delivery_unknown_outcome}
      "unavailable" -> {:error, :automation_delivery_unavailable}
      _ -> {:ok, observation}
    end
  end

  defp context(run, sessions) do
    id = source_session_id(run)
    observation = %{"source_session_id" => id}

    case value(run.metadata, :session_target) do
      "isolated" ->
        {nil, Map.put(observation, "status", "omitted")}

      "current" when is_binary(id) and id != "" ->
        deadline = System.monotonic_time(:millisecond) + 5_000

        case read_context(sessions, id, deadline) do
          {:ok, %{context: block, source: source}} when is_binary(block) or is_nil(block) ->
            status = if block in [nil, ""], do: "empty", else: "available"
            {block, Map.merge(observation, %{"status" => status, "source" => to_string(source)})}

          _ ->
            {nil, Map.put(observation, "status", "unavailable")}
        end

      _ ->
        {nil, Map.put(observation, "status", "unavailable")}
    end
  end

  defp read_context(sessions, id, deadline) do
    sessions.automation_context(id, deadline: deadline)
  rescue
    _ -> {:error, :context_unavailable}
  catch
    _, _ -> {:error, :context_unavailable}
  end

  defp announce(run, sessions, timeout) do
    id = source_session_id(run)

    if is_binary(id) and id != "" and is_binary(run.summary) do
      case append_result(sessions, id, run.summary, timeout) do
        {:ok, %{status: status} = result} when status in [:delivered, :deferred] ->
          delivery_observation(run, Atom.to_string(status))
          |> Map.put("message_id", Map.get(result, :message_id))

        {:error, reason} when reason in [:not_found, :source_unavailable, :invalid_input] ->
          delivery_observation(run, "unavailable")

        _ ->
          delivery_observation(run, "unknown_outcome")
      end
    else
      delivery_observation(run, "unavailable")
    end
  end

  defp append_result(sessions, id, text, timeout) do
    sessions.append_automation_result(id, text, timeout: timeout)
  rescue
    _ -> {:error, :unknown_outcome}
  catch
    _, _ -> {:error, :unknown_outcome}
  end

  defp delivery_observation(run, status) do
    %{
      "status" => status,
      "mode" => delivery_mode(run),
      "source_session_id" => source_session_id(run)
    }
  end

  defp delivery_mode(run), do: run.metadata |> value(:delivery, %{}) |> value(:mode)

  defp source_session_id(run),
    do: run.metadata |> value(:automation_origin, %{}) |> value(:session_id)

  defp fetch(map, key) do
    case Map.fetch(map, Atom.to_string(key)) do
      :error -> Map.fetch(map, key)
      found -> found
    end
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, Atom.to_string(key), Map.get(map, key, default))

  defp value(_map, _key, default), do: default

  defp stringify_keys(map), do: Map.new(map, fn {key, field} -> {to_string(key), field} end)
end
