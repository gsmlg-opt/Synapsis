defmodule Synapsis.SessionPresence do
  @moduledoc """
  Bounded observations of registered session workers, without calling workers.

  Trusted context contains a persisted session UUID and configured Agent string.
  Discovery's legacy `agent_id` selector is a session UUID, not a mailbox or
  native run ID. Owner identity comes only from raw Store metadata. Registry
  values, PIDs, configuration and native/build-agent lifecycle are never exposed.

  Observations are point-in-time reads, not liveness guarantees. Build agents
  remain unsupported. Enumeration uses bounded key-only persisted candidates and
  returns only live registration observations. `has_more` indicates unexamined
  persisted candidates, which may have no live or owner-matching observations.
  Each page reads current state independently; mutations can change later pages.

  Trusted options are `:registry`, `:store` and an absolute monotonic millisecond
  `:deadline`. Operations have at most five seconds and 64 KiB of output. The
  storage read uses a linked task to honor that total deadline and caller
  cancellation; no session worker, observer, index or background job is created.
  """

  alias Synapsis.Session.Store

  @timeout 5_000
  @output_limit 65_536
  @candidate_budget 1_000
  @candidate_page_size 100

  def discover(input, context, opts \\ []) do
    with :ok <- validate("discover", input),
         :ok <- context(context),
         {:ok, opts} <- options(opts),
         :ok <- remaining(opts) do
      cond do
        Map.get(input, "type", "session_worker") != "session_worker" ->
          output(%{sessions: [], count: 0})

        input["action"] == "get" ->
          with {:ok, session} <- observe(input["agent_id"], opts),
               do: output(%{session: session})

        true ->
          enumerate(input, opts)
      end
    end
  end

  def status(input, context, opts \\ []) do
    with :ok <- validate("status", input),
         :ok <- context(context),
         {:ok, opts} <- options(opts),
         :ok <- remaining(opts) do
      result = %{
        build_agents_supported: false,
        agents: [],
        message: "Build Agent system not yet implemented."
      }

      if Map.has_key?(input, "session_id") do
        with {:ok, session} <- observe(input["session_id"], opts),
             do: output(Map.put(result, :session, session))
      else
        output(result)
      end
    end
  end

  def validate("discover", input) when is_map(input) and not is_struct(input) do
    valid =
      case input["action"] do
        "get" ->
          closed?(input, ~w(action agent_id type)) and uuid?(input["agent_id"])

        "list" ->
          closed?(input, ~w(action type limit cursor)) and page?(input)

        "find_by_agent" ->
          closed?(input, ~w(action owner_agent_id type limit cursor)) and
            opaque?(input["owner_agent_id"], 256) and page?(input)

        _ ->
          false
      end

    if valid and optional?(input, "type", &opaque?(&1, 64)),
      do: :ok,
      else: {:error, :invalid_input}
  end

  def validate("status", input) when is_map(input) and not is_struct(input) do
    if closed?(input, ["session_id"]) and optional?(input, "session_id", &uuid?/1),
      do: :ok,
      else: {:error, :invalid_input}
  end

  def validate(_, _), do: {:error, :invalid_input}

  defp enumerate(input, opts) do
    state = %{
      sessions: [],
      count: 0,
      limit: Map.get(input, "limit", 100),
      cursor: input["cursor"],
      budget: @candidate_budget
    }

    enumerate_page(state, input["owner_agent_id"], opts)
  end

  defp enumerate_page(state, owner, opts) do
    with :ok <- remaining(opts),
         {:ok, page} <- candidate_page(state, opts),
         {:ok, state, unexamined?} <- observe_candidates(page.session_ids, state, owner, opts),
         :ok <- remaining(opts) do
      more = unexamined? or page.has_more

      cond do
        not more -> enumeration_output(state, false, false)
        state.count == state.limit -> enumeration_output(state, true, false)
        state.budget == 0 -> enumeration_output(state, true, true)
        true -> enumerate_page(state, owner, opts)
      end
    end
  end

  defp candidate_page(state, opts) do
    limit = min(@candidate_page_size, state.budget)

    bounded_read(opts, fn ->
      case opts[:store].list_session_ids(
             cursor: state.cursor,
             limit: limit,
             deadline: opts[:deadline]
           ) do
        {:ok, %{session_ids: ids, has_more: more, next_cursor: cursor, truncated: false} = page}
        when is_list(ids) and is_boolean(more) ->
          valid =
            length(ids) <= limit and Enum.all?(ids, &uuid?/1) and
              ids == Enum.sort(Enum.uniq(ids)) and
              Enum.all?(ids, &(is_nil(state.cursor) or &1 > state.cursor)) and
              if(more, do: ids != [] and cursor == List.last(ids), else: is_nil(cursor))

          if valid, do: {:ok, page}, else: {:error, :storage_unavailable}

        {:error, reason} when reason in [:timeout, :scan_limit] ->
          {:error, reason}

        _ ->
          {:error, :storage_unavailable}
      end
    end)
  end

  defp observe_candidates([], state, _owner, _opts), do: {:ok, state, false}

  defp observe_candidates(_ids, %{count: count, limit: count} = state, _owner, _opts),
    do: {:ok, state, true}

  defp observe_candidates([id | ids], state, owner, opts) do
    with :ok <- remaining(opts),
         {:ok, registration} <- registration(id, opts[:registry]),
         {:ok, session} <- registered_observation(id, registration, opts) do
      state = %{state | cursor: id, budget: state.budget - 1}

      state =
        if session && (is_nil(owner) or session.owner_agent_id == owner),
          do: %{state | sessions: [session | state.sessions], count: state.count + 1},
          else: state

      observe_candidates(ids, state, owner, opts)
    end
  end

  defp registered_observation(id, %{registered: true, alive: true} = registration, opts) do
    with {:ok, owner} <- metadata(id, opts),
         do: {:ok, observation(id, registration, owner)}
  end

  defp registered_observation(_id, _registration, _opts), do: {:ok, nil}

  defp enumeration_output(state, more, truncated) do
    output(%{
      sessions: Enum.reverse(state.sessions),
      count: state.count,
      has_more: more,
      next_cursor: if(more, do: state.cursor),
      truncated: truncated
    })
  end

  defp observe(id, opts) do
    with {:ok, registration} <- registration(id, opts[:registry]),
         {:ok, owner} <- metadata(id, opts),
         :ok <- remaining(opts) do
      {:ok, observation(id, registration, owner)}
    end
  end

  defp observation(id, registration, owner),
    do:
      Map.merge(registration, %{
        session_id: id,
        kind: "session_worker",
        owner_agent_id: owner,
        owner_known: owner != nil
      })

  defp registration(id, registry) do
    case Registry.lookup(registry, id) do
      [] -> {:ok, %{registered: false, alive: false}}
      [{pid, _}] when is_pid(pid) -> {:ok, %{registered: true, alive: Process.alive?(pid)}}
      _ -> {:error, :registry_unavailable}
    end
  rescue
    _ -> {:error, :registry_unavailable}
  catch
    :exit, _ -> {:error, :registry_unavailable}
  end

  defp metadata(id, opts) do
    bounded_read(opts, fn ->
      with :ok <- remaining(opts),
           do: read_owner(opts[:store], id, opts[:deadline] - now())
    end)
  end

  defp bounded_read(opts, read) do
    with :ok <- remaining(opts) do
      task =
        Task.async(fn ->
          try do
            read.()
          rescue
            _ -> {:error, :storage_unavailable}
          catch
            _, _ -> {:error, :storage_unavailable}
          end
        end)

      case Task.yield(task, max(opts[:deadline] - now(), 0)) do
        {:ok, result} ->
          result

        {:exit, _} ->
          {:error, :storage_unavailable}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end
    end
  end

  defp read_owner(store, id, timeout) when timeout > 0 do
    case store.get_meta(id, timeout: timeout) do
      {:ok, meta} when is_map(meta) and not is_struct(meta) ->
        case Map.get(meta, :agent) do
          nil -> {:ok, nil}
          owner -> if opaque?(owner, 256), do: {:ok, owner}, else: {:error, :malformed_metadata}
        end

      {:error, :not_found} ->
        {:ok, nil}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :storage_unavailable}

      _ ->
        {:error, :malformed_metadata}
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    _, _ -> {:error, :storage_unavailable}
  end

  defp read_owner(_store, _id, _timeout), do: {:error, :timeout}

  defp context(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == [:agent_id, :session_id] and
         uuid?(context[:session_id]) and opaque?(context[:agent_id], 256),
       do: :ok,
       else: {:error, :invalid_context}
  end

  defp context(_), do: {:error, :invalid_context}

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:registry, :store, :deadline] == [] do
      deadline = Keyword.get(opts, :deadline, now() + @timeout)
      registry = Keyword.get(opts, :registry, Synapsis.Session.Registry)
      store = Keyword.get(opts, :store, Store)

      if is_integer(deadline) and is_atom(registry) and is_atom(store),
        do: {:ok, [registry: registry, store: store, deadline: min(deadline, now() + @timeout)]},
        else: {:error, :invalid_context}
    else
      {:error, :invalid_context}
    end
  end

  defp options(_), do: {:error, :invalid_context}
  defp remaining(opts), do: if(opts[:deadline] > now(), do: :ok, else: {:error, :timeout})
  defp now, do: System.monotonic_time(:millisecond)

  defp output(result) do
    case Jason.encode(result) do
      {:ok, json} when byte_size(json) <= @output_limit -> {:ok, result}
      _ -> {:error, :output_limit}
    end
  end

  defp page?(input),
    do:
      optional?(input, "limit", &(is_integer(&1) and &1 in 1..100)) and
        optional?(input, "cursor", &uuid?/1)

  defp optional?(input, key, check), do: not Map.has_key?(input, key) or check.(input[key])
  defp closed?(input, keys), do: Map.keys(input) -- keys == []
  defp uuid?(id) when is_binary(id), do: match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp uuid?(_), do: false

  defp opaque?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
        String.trim(value) != "" and not String.contains?(value, "\0")
end
