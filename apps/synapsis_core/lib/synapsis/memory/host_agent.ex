defmodule Synapsis.Memory.HostAgent do
  @moduledoc """
  Bounded reads from an explicitly trusted local Backplane host-agent source.

  `recall/3` accepts `%{id: id, endpoint: "http://127.0.0.1:4222",
  agent_id: routing_id}` and query plus `:limit` (1..20, default 5), `:timeout`
  (1..10_000 milliseconds, default 6_000), and an optional monotonic millisecond
  `:deadline` that can only shorten the timeout. No config, environment,
  credentials, provider, or file-memory fallback is consulted. IPv6 `::1` is
  also accepted; endpoints must have no path, userinfo, query or fragment.

  Returns `{:ok, public_map}` with canonical `:hits`, trusted `:source` identity,
  and validated host state, or `{:error, fixed_atom}`. Only documented public
  record fields are retained. Citations identify the source endpoint/id and
  record ID, never file lines or project ownership. The host authorizes its
  default private partition; routing `agent_id` is provenance, not isolation.
  `get/3` accepts a lowercase canonical UUID and only `:timeout`/`:deadline`.
  It returns a singular `:record` with canonical online state and never falls
  back to recall, a mirror or provisional content. Shared/project/session
  filtering is unsupported by this client.

  Raw HTTP bodies are limited to 256 KiB before JSON decode; portable output is
  limited to 64 KiB. Oversize results fail without truncation. A guardian owns
  the deadline and kills the linked reader on owner loss, including suspended
  readers. This cleans local caller-owned work, not remote recall traces or
  shared HTTP-pool processes. The host may persist recall traces; callers must
  not assume retries or local cancellation undo remote side effects.
  """

  alias Synapsis.Memory.ScopedReader

  @max_response 262_144
  @max_output 65_536
  @source_keys [:id, :endpoint, :agent_id]
  @state_keys ~w(mode authority consistency stale history_available pending_operations)
  @get_state %{
    "mode" => "online",
    "authority" => "canonical",
    "consistency" => "canonical",
    "stale" => false,
    "history_available" => true
  }
  @optional_state ~w(overlay_truncated partition_revision last_sync_age_seconds as_of acknowledged_operations)
  @public_keys ~w(mode authority consistency stale history_available pending_operations overlay_truncated partition_revision last_sync_age_seconds as_of acknowledged_operations canonical_id provisional confidence memory_type tags score final_score distance kind lifecycle_state)a
  @public_atoms Map.new(@public_keys, &{Atom.to_string(&1), &1})
  @record_fields ~w(canonical_id authority provisional confidence memory_type tags score final_score distance kind lifecycle_state)

  @doc "Validates the entire trusted source; arbitrary ownership selectors are rejected."
  def validate_source(source) when is_map(source) do
    if Enum.sort(Map.keys(source)) == Enum.sort(@source_keys) and
         ScopedReader.valid_id?(source.id) and ScopedReader.valid_id?(source.agent_id) and
         valid_endpoint?(source.endpoint),
       do: :ok,
       else: {:error, :invalid_source}
  end

  def validate_source(_), do: {:error, :invalid_source}

  @doc "Recall only query/limit from the host-authorized default partition."
  def recall(source, query, opts \\ []) do
    with :ok <- validate_source(source),
         {:ok, limit, deadline} <- input(query, opts) do
      bounded(
        fn timeout ->
          with {:ok, result} <- request(source, :recall, %{query: query, limit: limit}, timeout),
               {:ok, public} <- normalize(result, source, limit) do
            output(public)
          end
        end,
        deadline
      )
    end
  end

  @doc "Read one canonical record from the host-authorized default partition."
  def get(source, id, opts \\ []) do
    with :ok <- validate_source(source),
         true <-
           is_binary(id) and Ecto.UUID.cast(id) == {:ok, id} and
             options?(opts, [:timeout, :deadline]),
         {:ok, deadline} <- deadline(opts) do
      bounded(
        fn timeout ->
          with {:ok, result} <- request(source, :get, %{id: id}, timeout),
               {:ok, public} <- normalize_get(result, source, id) do
            output(public)
          end
        end,
        deadline
      )
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  defp valid_endpoint?(endpoint) when is_binary(endpoint) do
    case Regex.run(~r/\Ahttp:\/\/(127\.0\.0\.1|\[::1\])(?::([0-9]+))?\z/, endpoint) do
      [_, _host] -> true
      [_, _host, port] -> byte_size(port) <= 5 and String.to_integer(port) in 1..65_535
      _ -> false
    end
  end

  defp valid_endpoint?(_), do: false

  defp input(query, opts) do
    if options?(opts, [:limit, :timeout, :deadline]) and
         is_binary(query) and String.valid?(query) and byte_size(query) in 1..2048 do
      limit = Keyword.get(opts, :limit, 5)

      with true <- is_integer(limit) and limit in 1..20,
           {:ok, deadline} <- deadline(opts) do
        {:ok, limit, deadline}
      else
        false -> {:error, :invalid_input}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_input}
    end
  end

  defp options?(opts, allowed) do
    Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
      length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))
  end

  defp deadline(opts) do
    timeout = Keyword.get(opts, :timeout, 6000)
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + timeout_value(timeout))

    cond do
      not (is_integer(timeout) and timeout in 1..10_000 and is_integer(deadline)) ->
        {:error, :invalid_input}

      deadline <= now ->
        {:error, :timeout}

      true ->
        {:ok, min(now + timeout, deadline)}
    end
  end

  defp timeout_value(timeout) when is_integer(timeout), do: timeout
  defp timeout_value(_), do: 0

  defp bounded(fun, deadline) do
    owner = self()
    ref = make_ref()
    {guardian, monitor} = spawn_monitor(fn -> guard(owner, ref, deadline, fun) end)

    receive do
      {^ref, result} ->
        receive do: ({:DOWN, ^monitor, :process, ^guardian, _} -> result)

      {:DOWN, ^monitor, :process, ^guardian, _} ->
        {:error, :worker_limit}
    end
  end

  defp guard(owner, ref, deadline, fun) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    guardian = self()
    result_ref = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          # Keep the caller's absolute deadline through scheduling; an expired
          # reader must not start HTTP even before the guardian handles its timer.
          remaining = deadline - System.monotonic_time(:millisecond)
          result = if remaining > 0, do: fun.(remaining), else: {:error, :timeout}
          send(guardian, {result_ref, result})
        end,
        [:link, :monitor, {:max_heap_size, %{size: 2_000_000, kill: true, error_logger: false}}]
      )

    case await(worker, monitor, owner_monitor, result_ref, deadline, nil) do
      :owner_gone -> :ok
      result -> send(owner, {ref, result})
    end
  end

  defp await(worker, monitor, owner_monitor, ref, deadline, result) do
    receive do
      {^ref, value} ->
        await(worker, monitor, owner_monitor, ref, deadline, value)

      {:DOWN, ^monitor, :process, ^worker, _} ->
        result || {:error, :worker_limit}

      {:DOWN, ^owner_monitor, :process, _, _} ->
        stop(worker, monitor)
        :owner_gone

      {:EXIT, ^worker, _} ->
        await(worker, monitor, owner_monitor, ref, deadline, result)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        stop(worker, monitor)
        {:error, :timeout}
    end
  end

  defp stop(worker, monitor) do
    Process.exit(worker, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^worker, _} -> :ok)
  end

  defp request(source, operation, arguments, timeout) do
    # The high-level keyword constructor merges global Req defaults (including
    # credentials and plugins). Build a clean request before explicit options.
    response =
      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        method: :post,
        url:
          source.endpoint <>
            "/memory/" <> source.agent_id <> "/call/" <> Atom.to_string(operation),
        json: arguments,
        raw: true,
        into: &collect/2,
        retry: false,
        redirect: false,
        receive_timeout: timeout,
        request_timeout: timeout,
        connect_options: [timeout: timeout]
      )
      |> Req.request()

    with {:ok, body} <- response_body(response, operation),
         {:ok, decoded} <- decode(body) do
      envelope(decoded, operation)
    end
  end

  defp collect({:data, data}, {request, response}) do
    {size, chunks} = Req.Response.get_private(response, :host_memory_body, {0, []})

    if size + byte_size(data) <= @max_response do
      response =
        Req.Response.put_private(
          response,
          :host_memory_body,
          {size + byte_size(data), [data | chunks]}
        )

      {:cont, {request, response}}
    else
      {:halt, {request, Req.Response.put_private(response, :host_memory_limit, true)}}
    end
  end

  defp response_body({:ok, response}, operation) do
    cond do
      Req.Response.get_private(response, :host_memory_limit, false) ->
        {:error, :response_limit}

      response.status in 300..399 ->
        {:error, :redirect}

      response.status in [401, 403] ->
        {:error, :unauthorized}

      operation == :get and response.status not in 200..299 ->
        fallback = if response.status in 500..599, do: :unavailable, else: :http_error

        case decode(body(response)) do
          {:ok, %{"ok" => false, "error" => code}} ->
            case get_error(code) do
              :host_error -> {:error, fallback}
              reason -> {:error, reason}
            end

          _ ->
            {:error, fallback}
        end

      response.status in 500..599 ->
        {:error, :unavailable}

      response.status not in 200..299 ->
        {:error, :http_error}

      true ->
        {:ok, body(response)}
    end
  end

  defp response_body({:error, %Req.TransportError{reason: reason}}, _operation)
       when reason in [:timeout, :connect_timeout],
       do: {:error, :timeout}

  defp response_body({:error, _}, _operation), do: {:error, :unavailable}

  defp body(response) do
    {_size, chunks} = Req.Response.get_private(response, :host_memory_body, {0, []})
    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp envelope(%{"ok" => true, "result" => result}, _) when is_map(result), do: {:ok, result}
  defp envelope(%{"ok" => false, "error" => code}, :get), do: {:error, get_error(code)}
  defp envelope(%{"ok" => false}, _), do: {:error, :host_error}
  defp envelope(_, _), do: {:error, :malformed_result}

  defp get_error("not_found"), do: :not_found
  defp get_error("unauthorized"), do: :unauthorized
  defp get_error("invalid_arguments"), do: :invalid_arguments
  defp get_error("unsupported_filter"), do: :unsupported_filter
  defp get_error("payload_too_large"), do: :payload_too_large
  defp get_error("unsupported_operation"), do: :unsupported_operation
  defp get_error("canonical_unavailable"), do: :canonical_unavailable
  defp get_error(_), do: :host_error

  defp normalize_get(result, source, id) do
    hit = result["record"]

    with true <- Map.take(result, Map.keys(@get_state)) === @get_state,
         true <-
           not Map.has_key?(result, "pending_operations") or result["pending_operations"] === 0,
         true <-
           is_map(hit) and hit["id"] === id and hit["canonical_id"] === id and
             hit["kind"] === "memory" and Map.get(hit, "authority", "canonical") === "canonical" and
             Map.get(hit, "provisional", false) === false,
         {:ok, record} <- record(hit, source) do
      state = Map.new(@get_state, fn {key, value} -> {Map.fetch!(@public_atoms, key), value} end)

      {:ok,
       Map.merge(state, %{
         record: record,
         source: %{id: source.id, endpoint: source.endpoint, partition: "host_default"}
       })}
    else
      _ -> {:error, :malformed_result}
    end
  end

  defp normalize(result, source, limit) do
    hits = result["hits"]

    with true <- state_valid?(result),
         true <- is_list(hits) and length(hits) <= limit,
         true <- aliases_valid?(result, hits),
         {:ok, records} <- records(hits, source),
         true <- length(Enum.uniq_by(records, & &1.memory_id)) == length(records) do
      public =
        result
        |> Map.take(@state_keys ++ @optional_state)
        |> Map.new(fn {key, value} -> {Map.fetch!(@public_atoms, key), value} end)
        |> Map.merge(%{
          hits: records,
          source: %{id: source.id, endpoint: source.endpoint, partition: "host_default"}
        })

      public =
        if Map.has_key?(result, "source"),
          do: Map.put(public, :host_source, result["source"]),
          else: public

      {:ok, public}
    else
      _ -> {:error, :malformed_result}
    end
  end

  defp state_valid?(state) do
    Enum.all?(@state_keys, &Map.has_key?(state, &1)) and
      is_boolean(state["stale"]) and is_boolean(state["history_available"]) and
      nonnegative?(state["pending_operations"]) and
      Enum.all?(@optional_state, fn key ->
        not Map.has_key?(state, key) or valid_state_field?(key, state[key])
      end) and
      (not Map.has_key?(state, "source") or
         state["source"] in ~w(edge_mirror acknowledged_commands provisional_commands)) and
      consistent_state?(state)
  end

  defp consistent_state?(
         %{"mode" => "online", "stale" => false, "history_available" => true} = state
       ) do
    case {state["authority"], state["consistency"], state["pending_operations"]} do
      {"canonical", "canonical", 0} -> true
      {"canonical_with_provisional", "read_your_writes", n} when n > 0 -> true
      _ -> false
    end
  end

  defp consistent_state?(%{"mode" => "offline", "stale" => true} = state) do
    case {state["authority"], state["consistency"], state["pending_operations"],
          state["history_available"]} do
      {"canonical", "bounded_stale", 0, _} -> true
      {"canonical_with_provisional", "bounded_stale", n, _} when n > 0 -> true
      {"provisional", "provisional_only", _, false} -> true
      _ -> false
    end
  end

  defp consistent_state?(_), do: false

  defp valid_state_field?("overlay_truncated", value), do: is_boolean(value)
  defp valid_state_field?("acknowledged_operations", value), do: nonnegative?(value)
  defp valid_state_field?("partition_revision", value), do: is_nil(value) or nonnegative?(value)

  defp valid_state_field?("last_sync_age_seconds", value),
    do: is_nil(value) or (is_number(value) and value >= 0)

  defp valid_state_field?("as_of", nil), do: true

  defp valid_state_field?("as_of", value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_state_field?(_, _), do: false
  defp nonnegative?(value), do: is_integer(value) and value >= 0

  # results/items are facade aliases; upserts/provisional_results are subsets
  # used by the host overlay and must never be merged by this client.
  defp aliases_valid?(result, hits) do
    Enum.all?(~w(results items), fn key ->
      not Map.has_key?(result, key) or result[key] === hits
    end) and
      Enum.all?(~w(upserts provisional_results), fn key ->
        not Map.has_key?(result, key) or
          (is_list(result[key]) and length(result[key]) <= 100 and
             Enum.all?(result[key], &is_map/1))
      end)
  end

  defp records(hits, source) do
    Enum.reduce_while(hits, {:ok, []}, fn hit, {:ok, acc} ->
      case record(hit, source) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp record(hit, source) when is_map(hit) do
    # Mirror.Store emits canonical_id only; provisional commands may carry a
    # separate local id. Present invalid/null preferred aliases must fail closed.
    id = Map.get(hit, "id", Map.get(hit, "memory_id", hit["canonical_id"]))

    if ScopedReader.valid_id?(id) and
         (not Map.has_key?(hit, "memory_id") or hit["memory_id"] === id) and
         text?(hit["content"], @max_response) and
         Enum.all?(@record_fields, fn key ->
           not Map.has_key?(hit, key) or record_field?(key, hit[key])
         end) and
         consistent_record?(hit) do
      public =
        hit
        |> Map.take(@record_fields)
        |> Map.new(fn {key, value} -> {Map.fetch!(@public_atoms, key), value} end)

      {:ok,
       Map.merge(public, %{
         memory_id: id,
         content: hit["content"],
         citation: %{source_id: source.id, endpoint: source.endpoint, memory_id: id}
       })}
    else
      {:error, :malformed_result}
    end
  end

  defp record(_, _), do: {:error, :malformed_result}

  defp record_field?("canonical_id", value), do: is_nil(value) or ScopedReader.valid_id?(value)
  defp record_field?("authority", value), do: value in ~w(canonical provisional)
  defp record_field?("provisional", value), do: is_boolean(value)

  defp record_field?("confidence", value),
    do: is_nil(value) or (is_number(value) and value >= 0 and value <= 1)

  defp record_field?(key, value) when key in ~w(score final_score distance), do: is_number(value)

  defp record_field?("tags", value),
    do: is_list(value) and length(value) <= 20 and Enum.all?(value, &text?(&1, 128))

  defp record_field?("lifecycle_state", value),
    do: value in ~w(candidate active disputed superseded archived tombstoned)

  defp record_field?(_, value), do: text?(value, 128)

  defp consistent_record?(%{"authority" => "canonical", "provisional" => true}), do: false
  defp consistent_record?(%{"authority" => "provisional", "provisional" => false}), do: false
  defp consistent_record?(_), do: true

  defp text?(value, bound),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= bound

  defp output(public) do
    if byte_size(Jason.encode!(public)) <= @max_output,
      do: {:ok, public},
      else: {:error, :output_limit}
  end
end
