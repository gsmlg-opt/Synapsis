defmodule Synapsis.Swarm do
  @moduledoc """
  Session PubSub notifications and saved teammate metadata, without agent lifecycle.

  Metadata uses `:synapsis_swarm_teammates`, owned only by the supervised core
  `Synapsis.Swarm.Store`. State lasts until that owner exits and survives tool
  Registry restarts. This module never creates the table or invokes legacy tools.
  Legacy tools call this API, sharing its validation, limits and bounded
  per-session lock for reads, read/modify/write and deletion operations.

  New records use `status: "configured"`; existing legacy status fields remain
  readable metadata and do not establish a live agent. Saved tool names are
  declarations only and never admit tools or expand native grants. Notifications
  have no durability, delivery acknowledgement or turn-activation guarantee.
  """

  alias Backplane.AiProtocol.Validation

  @timeout 1_000
  @max_state 65_536
  @max_teammates 64
  @default_tools ~w(synapsis::read synapsis::ls)
  @message_keys ~w(to content type in_reply_to)
  @teammate_keys ~w(action name prompt tools model)

  def message(session_id, sender, args) do
    with :ok <- scope(session_id),
         true <- opaque?(sender, 256),
         :ok <- validate_message(args) do
      id = Ecto.UUID.generate()

      message = %{
        id: id,
        from: sender,
        to: args["to"],
        content: args["content"],
        type: Map.get(args, "type", "notify"),
        in_reply_to: args["in_reply_to"]
      }

      case Phoenix.PubSub.broadcast(
             Synapsis.PubSub,
             "swarm:#{session_id}:#{args["to"]}",
             {:swarm_message, message}
           ) do
        :ok -> {:ok, %{message_id: id, status: "published", to: args["to"]}}
        _ -> {:error, :unavailable}
      end
    else
      false -> {:error, :invalid_scope}
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def teammate(session_id, args) do
    with :ok <- scope(session_id),
         :ok <- validate_teammate(args) do
      deadline = System.monotonic_time(:millisecond) + @timeout

      locked(session_id, deadline, fn table ->
        with {:ok, records} <- load(table, session_id) do
          teammate_action(table, session_id, records, args, deadline)
        end
      end)
    end
  end

  def delete_team(session_id) do
    with :ok <- scope(session_id) do
      deadline = System.monotonic_time(:millisecond) + @timeout

      locked(session_id, deadline, fn table ->
        with {:ok, records} <- load(table, session_id),
             :ok <- before_deadline(deadline) do
          :ets.delete(table, session_id)
          {:ok, %{count: map_size(records)}}
        end
      end)
    end
  end

  def validate_message(args) when is_map(args) and not is_struct(args) do
    if Map.keys(args) -- @message_keys == [] and opaque?(args["to"], 256) and
         text?(args["content"], 32_768) and
         Map.get(args, "type", "notify") in ~w(request response notify) and
         optional?(args, "in_reply_to", &opaque?(&1, 256)),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate_message(_), do: {:error, :invalid_input}

  def validate_teammate(args) when is_map(args) and not is_struct(args) do
    if Map.keys(args) -- @teammate_keys == [] and args["action"] in ~w(create list get update) and
         (args["action"] not in ~w(get update) or opaque?(args["name"], 256)) and
         optional?(args, "name", &opaque?(&1, 256)) and
         optional?(args, "prompt", &text?(&1, 8192)) and
         optional?(args, "model", &opaque?(&1, 256)) and
         optional?(args, "tools", &tools?/1),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate_teammate(_), do: {:error, :invalid_input}

  defp teammate_action(_table, _session, records, %{"action" => "list"}, _deadline),
    do: {:ok, records |> Map.values() |> Enum.sort_by(& &1.name)}

  defp teammate_action(_table, _session, records, %{"action" => "get", "name" => name}, _deadline) do
    case Map.fetch(records, name) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp teammate_action(table, session, records, %{"action" => "create"} = args, deadline) do
    name = Map.get_lazy(args, "name", fn -> "teammate_#{Ecto.UUID.generate()}" end)

    record = %{
      id: Ecto.UUID.generate(),
      name: name,
      prompt: Map.get(args, "prompt", ""),
      tools: Map.get(args, "tools", @default_tools),
      model: args["model"],
      status: "configured"
    }

    persist(table, session, Map.put(records, name, record), record, deadline)
  end

  defp teammate_action(
         table,
         session,
         records,
         %{"action" => "update", "name" => name} = args,
         deadline
       ) do
    case Map.fetch(records, name) do
      {:ok, record} ->
        updated =
          Enum.reduce([:prompt, :tools, :model], record, fn key, record ->
            case Map.fetch(args, Atom.to_string(key)) do
              {:ok, value} -> Map.put(record, key, value)
              :error -> record
            end
          end)

        persist(table, session, Map.put(records, name, updated), updated, deadline)

      :error ->
        {:error, :not_found}
    end
  end

  defp persist(table, session, records, result, deadline) do
    with :ok <- bounded_state(records), :ok <- before_deadline(deadline) do
      :ets.insert(table, {session, records})
      {:ok, result}
    end
  end

  defp load(table, session) do
    records =
      case :ets.lookup(table, session) do
        [] -> %{}
        [{^session, records}] -> records
      end

    with :ok <- bounded_state(records), do: {:ok, records}
  end

  defp bounded_state(records) when is_map(records) and not is_struct(records) do
    cond do
      map_size(records) > @max_teammates ->
        {:error, :output_limit}

      not Enum.all?(records, fn {name, record} -> record?(name, record) end) ->
        {:error, :invalid_state}

      true ->
        with :ok <- Validation.term(records), {:ok, json} <- Jason.encode(records) do
          if byte_size(json) <= @max_state, do: :ok, else: {:error, :output_limit}
        else
          _ -> {:error, :invalid_state}
        end
    end
  end

  defp bounded_state(_), do: {:error, :invalid_state}

  defp record?(name, %{
         id: id,
         name: name,
         prompt: prompt,
         tools: tools,
         model: model,
         status: status
       }) do
    scope(id) == :ok and opaque?(name, 256) and text?(prompt, 8192) and tools?(tools) and
      (is_nil(model) or opaque?(model, 256)) and opaque?(status, 64)
  end

  defp record?(_, _), do: false

  defp locked(session, deadline, fun) do
    with :ok <- before_deadline(deadline) do
      result =
        :global.trans(
          {{__MODULE__, session}, self()},
          fn ->
            with :ok <- before_deadline(deadline), {:ok, table} <- table() do
              fun.(table)
            end
          end,
          [node()],
          0
        )

      case result do
        :aborted ->
          remaining = deadline - System.monotonic_time(:millisecond)

          if remaining > 0 do
            receive do
            after
              min(5, remaining) -> locked(session, deadline, fun)
            end
          else
            {:error, :timeout}
          end

        result ->
          result
      end
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp table, do: Synapsis.Swarm.Store.table()

  defp before_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :timeout}
  end

  defp scope(id) when is_binary(id) do
    if Ecto.UUID.cast(id) == {:ok, id}, do: :ok, else: {:error, :invalid_scope}
  end

  defp scope(_), do: {:error, :invalid_scope}

  defp optional?(args, key, check), do: not Map.has_key?(args, key) or check.(args[key])

  defp tools?(tools),
    do: is_list(tools) and length(tools) <= 32 and Enum.all?(tools, &opaque?(&1, 256))

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) <= limit and String.valid?(value)

  defp opaque?(value, limit),
    do: text?(value, limit) and String.trim(value) != "" and not String.contains?(value, "\0")
end
