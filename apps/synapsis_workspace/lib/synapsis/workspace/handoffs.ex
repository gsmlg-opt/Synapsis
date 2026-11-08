defmodule Synapsis.Workspace.Handoffs do
  @moduledoc """
  Durable handoff mail and its generated, sender-owned Workspace artifact.

  The trusted configured Agent name and session UUID select authority. Model
  input cannot choose a sender, output path, UUID or storage backend. This domain
  permits only creation of its generated `/agents/<name>/handoffs/<ref>.json`;
  ordinary session Workspace permissions are unchanged.

  Mail persists first, then artifact content and metadata, then Workspace,
  mailbox and tool-effect notifications. Receipts describe each stage without
  promising delivery, agent startup or delegation. Failures stop later stages;
  confirmed effects are never rolled back or replayed. An owner-monitored worker
  has one five-second absolute deadline, including the persisted-session check
  and publication. Caller death terminates owned work and leaves durable
  handoffs intact. Trusted options may select a session `:store` module;
  descriptor context and model input cannot select a storage backend.
  """
  alias Synapsis.AgentCommunication
  alias Synapsis.Filesystem.Local
  alias Synapsis.Session.Store
  alias Synapsis.Workspace
  alias Synapsis.Workspace.FileDocuments

  @timeout 5_000
  @placeholder "00000000-0000-4000-8000-000000000000"

  def handoff(input, context, opts \\ []) do
    with :ok <- AgentCommunication.validate("handoff", input),
         :ok <- context_valid(context),
         {:ok, opts} <- options(opts),
         :ok <- active(self(), opts) do
      owner = self()
      token = make_ref()
      root = Synapsis.WorkspaceDocuments.root()
      initial = initial_receipt(input["to"])

      {guardian, monitor} =
        spawn_monitor(fn -> guard(owner, token, input, context, root, opts, initial) end)

      receive do
        {^token, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^guardian, _} ->
          failure("handoff_owner_failed", "uncertain", initial)
      end
    end
  end

  defp perform(owner, guardian, token, input, context, root, opts, initial) do
    with :ok <- preflight(root, context),
         :ok <- active(owner, opts),
         :ok <- persisted_session(context.session_id, opts),
         :ok <- active(owner, opts) do
      entered = %{initial | status: "unknown", message_status: "unknown"}
      progress(guardian, token, entered, :message)

      case AgentCommunication.persist_handoff(
             input,
             context,
             Keyword.take(opts, [:deadline, :kv])
           ) do
        {:ok, message} ->
          receipt =
            Map.merge(initial, %{
              status: "persisted",
              message_status: "persisted",
              message_id: message.id,
              ref: message.ref,
              artifact_path: path(context.agent_id, message.ref)
            })

          progress(guardian, token, receipt, :none)
          artifact(owner, guardian, token, message, context, root, opts, receipt)

        {:error, fields} ->
          base = if fields.effect == "uncertain", do: entered, else: initial
          {:error, Map.merge(base, fields)}
      end
    else
      {:error, %{code: _} = fields} -> {:error, Map.merge(initial, fields)}
      {:error, _} -> failure("unsafe_path", "none", initial)
    end
  end

  defp artifact(owner, guardian, token, message, context, root, opts, receipt) do
    case active(owner, opts) do
      :ok ->
        entered =
          Map.merge(receipt, %{
            artifact_status: "unknown",
            artifact_content_status: "unknown",
            artifact_metadata_status: "unconfirmed"
          })

        progress(guardian, token, entered, :artifact)

        result =
          FileDocuments.with_paths(
            root,
            [receipt.artifact_path],
            Keyword.take(opts, [:deadline]),
            fn io ->
              store_artifact(
                owner,
                guardian,
                token,
                message,
                context,
                root,
                Keyword.merge(opts, io),
                receipt,
                entered
              )
            end
          )

        case result do
          {:ok, _} = complete ->
            complete

          {:error, %{code: _}} = failed ->
            failed

          {:error, {:unknown_outcome, evidence}} ->
            fields = Map.take(evidence, [:artifact_content_status, :artifact_metadata_status])
            failure("artifact_failed", "uncertain", Map.merge(entered, fields))

          {:error, _} ->
            failure("artifact_failed", "uncertain", entered)
        end

      {:error, fields} ->
        merge_failure(receipt, fields)
    end
  end

  defp store_artifact(owner, guardian, token, message, context, root, opts, receipt, entered) do
    with :ok <- active(owner, opts) do
      case FileDocuments.put_handoff(root, message, Keyword.take(opts, [:deadline, :lease])) do
        {:ok, change} ->
          persisted =
            Map.merge(receipt, %{
              artifact_status: "persisted",
              artifact_content_status: "persisted",
              artifact_metadata_status: "persisted"
            })

          progress(guardian, token, persisted, :none)
          publications(owner, guardian, token, message, context, opts, persisted, change)

        {:error, {:unknown_outcome, evidence}} ->
          fields = Map.take(evidence, [:artifact_content_status, :artifact_metadata_status])
          failure("artifact_failed", "uncertain", Map.merge(entered, fields))

        {:error, _} ->
          failed =
            Map.merge(receipt, %{
              artifact_status: "failed",
              artifact_content_status: "not_persisted",
              artifact_metadata_status: "not_attempted"
            })

          failure("artifact_failed", "completed", failed)
      end
    else
      {:error, fields} ->
        merge_failure(receipt, fields)
    end
  end

  defp publications(owner, guardian, token, message, context, opts, receipt, change) do
    workspace_event = {:workspace_changed, Map.take(change, [:path, :action, :resource_id])}
    effect = {:tool_effect, :workspace_changed, %{ref: message.ref, type: "handoff"}}

    with {:ok, receipt} <-
           publish_stage(
             owner,
             guardian,
             token,
             receipt,
             :workspace_publication,
             "workspace:agent:#{context.agent_id}",
             workspace_event,
             opts
           ),
         {:ok, receipt} <- publish_mail(owner, guardian, token, receipt, message, context, opts),
         {:ok, receipt} <-
           publish_stage(
             owner,
             guardian,
             token,
             receipt,
             :session_publication,
             "tool_effects:#{context.session_id}",
             effect,
             opts
           ),
         {:ok, receipt} <-
           publish_stage(
             owner,
             guardian,
             token,
             receipt,
             :global_publication,
             "tool_effects:global",
             effect,
             opts
           ) do
      {:ok, receipt}
    end
  end

  defp publish_mail(owner, guardian, token, receipt, message, context, opts) do
    case active(owner, opts) do
      :ok ->
        entered = Map.put(receipt, :mailbox_publication, "unknown")
        progress(guardian, token, entered, :mailbox_publication)

        result =
          with :ok <- publication_active(owner, opts) do
            AgentCommunication.publish_handoff(
              message,
              context,
              Keyword.take(opts, [:deadline, :kv])
            )
          end

        case result do
          {:ok, fields} ->
            receipt = Map.merge(receipt, fields)
            progress(guardian, token, receipt, :none)
            {:ok, receipt}

          {:error, fields} ->
            merge_failure(receipt, fields)
        end

      {:error, fields} ->
        merge_failure(receipt, fields)
    end
  end

  defp publish_stage(owner, guardian, token, receipt, key, topic, event, opts) do
    case active(owner, opts) do
      :ok ->
        entered = Map.put(receipt, key, "unknown")
        progress(guardian, token, entered, key)

        result = with :ok <- publication_active(owner, opts), do: broadcast(topic, event)

        case result do
          :ok ->
            receipt = Map.put(receipt, key, "published")
            progress(guardian, token, receipt, :none)
            {:ok, receipt}

          :error ->
            failure("publication_failed", "uncertain", entered)

          {:error, fields} ->
            merge_failure(receipt, fields)
        end

      {:error, fields} ->
        merge_failure(receipt, fields)
    end
  end

  defp publication_active(owner, opts) do
    with :ok <- active(owner, opts) do
      case Local.check_scope(Keyword.take(opts, [:deadline, :lease])) do
        :ok -> :ok
        {:error, _} -> failure("publication_failed", "uncertain", %{})
      end
    end
  end

  defp broadcast(topic, event) do
    case Phoenix.PubSub.broadcast(Synapsis.PubSub, topic, event) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp preflight(root, context) do
    candidate = path(context.agent_id, @placeholder)
    encoded = candidate |> String.trim_leading("/") |> String.replace("/", "__")
    metadata = ".synapsis/meta/#{encoded}.json"

    with :ok <- Workspace.validate_path(candidate),
         {:ok, _, _} <- Local.resolve(root, String.trim_leading(candidate, "/")),
         {:ok, _, _} <- Local.resolve(root, metadata) do
      :ok
    end
  end

  defp context_valid(context) when is_map(context) and not is_struct(context) do
    if Enum.sort(Map.keys(context)) == [:agent_id, :primary, :session_id] and
         is_binary(context[:agent_id]) and byte_size(context.agent_id) in 1..256 and
         Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, context.agent_id) and
         is_binary(context[:session_id]) and
         Ecto.UUID.cast(context.session_id) == {:ok, context.session_id} and
         is_boolean(context[:primary]),
       do: :ok,
       else: failure("invalid_context", "none", %{})
  end

  defp context_valid(_), do: failure("invalid_context", "none", %{})

  defp persisted_session(id, opts) do
    store = opts[:store]

    case store.get_meta(id) do
      {:ok, %{id: ^id}} -> :ok
      {:error, :not_found} -> failure("not_found", "none", %{})
      {:error, :timeout} -> failure("timeout", "none", %{})
      _ -> failure("storage_failed", "none", %{})
    end
  rescue
    _ -> failure("storage_failed", "none", %{})
  catch
    _, _ -> failure("storage_failed", "none", %{})
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :kv, :store] == [] and
         (not Keyword.has_key?(opts, :deadline) or is_integer(opts[:deadline])) and
         is_atom(Keyword.get(opts, :store, Store)) do
      started = now()

      {:ok,
       opts
       |> Keyword.put(
         :deadline,
         min(Keyword.get(opts, :deadline, started + @timeout), started + @timeout)
       )
       |> Keyword.put_new(:store, Store)}
    else
      failure("invalid_context", "none", %{})
    end
  end

  defp active(owner, opts) do
    cond do
      not Process.alive?(owner) -> failure("caller_cancelled", "none", %{})
      opts[:deadline] <= now() -> failure("timeout", "none", %{})
      true -> :ok
    end
  end

  defp initial_receipt(to),
    do: %{
      to: to,
      status: "not_attempted",
      message_status: "not_attempted",
      artifact_status: "not_attempted",
      mailbox_publication: "not_published",
      workspace_publication: "not_published",
      session_publication: "not_published",
      global_publication: "not_published"
    }

  defp path(agent, ref), do: "/agents/#{agent}/handoffs/#{ref}.json"
  defp now, do: System.monotonic_time(:millisecond)

  defp failure(code, effect, receipt),
    do: {:error, Map.merge(receipt, %{code: code, effect: effect})}

  defp merge_failure(receipt, fields) do
    merged = Map.merge(receipt, fields)

    if fields.effect == "none" and receipt.message_status == "persisted",
      do: {:error, Map.put(merged, :effect, "completed")},
      else: {:error, merged}
  end

  defp progress(guardian, token, receipt, stage),
    do: send(guardian, {token, :progress, receipt, stage})

  defp guard(owner, token, input, context, root, opts, initial) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    guardian = self()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result = perform(owner, guardian, token, input, context, root, opts, initial)
          send(guardian, {token, :result, result})
        end,
        [:link, :monitor, {:max_heap_size, %{size: 4_000_000, kill: true, error_logger: false}}]
      )

    case await(worker, monitor, owner_monitor, token, opts[:deadline], initial, :none, nil) do
      :owner_gone -> :ok
      result -> send(owner, {token, result})
    end
  end

  defp await(worker, monitor, owner_monitor, token, deadline, receipt, stage, result) do
    receive do
      {^token, :progress, updated, entered} ->
        await(worker, monitor, owner_monitor, token, deadline, updated, entered, result)

      {^token, :result, completed} ->
        await(worker, monitor, owner_monitor, token, deadline, receipt, stage, completed)

      {:DOWN, ^monitor, :process, ^worker, _} ->
        result || interrupted("workflow_failed", receipt, stage)

      {:DOWN, ^owner_monitor, :process, _, _} ->
        stop(worker, monitor)
        :owner_gone

      {:EXIT, ^worker, _} ->
        await(worker, monitor, owner_monitor, token, deadline, receipt, stage, result)
    after
      max(0, deadline - now()) ->
        stop(worker, monitor)
        {receipt, stage, result} = drain(token, receipt, stage, result)
        result || interrupted("timeout", receipt, stage)
    end
  end

  defp stop(worker, monitor) do
    Process.exit(worker, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    end
  end

  defp drain(token, receipt, stage, result) do
    receive do
      {^token, :progress, updated, entered} -> drain(token, updated, entered, result)
      {^token, :result, completed} -> drain(token, receipt, stage, completed)
    after
      0 -> {receipt, stage, result}
    end
  end

  defp interrupted(code, receipt, stage) do
    effect =
      cond do
        stage != :none -> "uncertain"
        receipt.message_status == "persisted" -> "completed"
        true -> "none"
      end

    failure(code, effect, receipt)
  end
end
