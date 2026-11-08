defmodule Synapsis.AgentCommunication do
  @moduledoc """
  Persistent mailbox send, ask, reply and inbox operations for native adapters.

  The adapter supplies trusted `%{agent_id: opaque_mailbox, session_id: uuid,
  primary: boolean}` context after permission checks. Input cannot choose sender,
  session or primary authority. Mailbox names are configured Agent strings, not
  runtime run/task IDs. Persistence and PubSub publication do not prove remote
  delivery or start a turn. `info`/`warning` are notifications with payload level.

  Results are portable maps. Errors distinguish no effect, known completed
  persistence, and uncertain effects; publication is never rolled back. Text is
  limited to 16 KiB, context/metadata to 4 KiB, inboxes to 100 messages and output
  to 64 KiB. Ordinary operations have a five-second total deadline. Ask defaults
  to 120 seconds, accepts at most 300 seconds, and uses one absolute deadline.
  A guardian owns its subscription and monitors the effect caller; timeout or
  caller death expires the durable open request with a separate bounded cleanup.

  Trusted options are `:deadline` (absolute monotonic milliseconds) and `:kv`
  (storage failure seam). They must never come from model arguments. Call these
  synchronous functions only in effect tasks, never session/agent processes.
  """
  import Kernel, except: [send: 2]
  alias Synapsis.AgentMessages

  @text_limit 16_384
  @json_limit 4_096
  @output_limit 65_536
  @operation_timeout 5_000
  @ask_timeout 120_000
  @max_ask_timeout 300_000
  @mail_types ~w(request response notification delegation handoff completion)
  @reply_statuses ~w(success error partial declined)
  @handoff_limit 61_440

  @doc """
  Persists a handoff without publishing it. Workspace owns the subsequent
  generated artifact and publication sequence; this stage never calls Workspace.
  Text fields are at most 16 KiB, constraints 4 KiB, and the complete input 60 KiB.
  At most 64 logical artifact references of 1024 bytes are retained, never read.
  """
  def persist_handoff(input, context, opts \\ []) do
    with :ok <- validate("handoff", input),
         :ok <- context(context),
         {:ok, opts} <- options(opts, @operation_timeout),
         :ok <- before_effect(opts) do
      payload =
        Map.take(input, ~w(summary instructions))
        |> Map.merge(%{
          "artifacts" => Map.get(input, "artifacts", []),
          "priority" => Map.get(input, "priority", "normal"),
          "constraints" => Map.get(input, "constraints", %{})
        })

      attrs =
        attrs(context, input["to"], "handoff", payload) |> Map.put(:id, Ecto.UUID.generate())

      fields = %{message_id: attrs.id, ref: attrs.ref, to: attrs.to_agent_id}

      case AgentMessages.create(attrs, opts) do
        {:ok, message} ->
          {:ok, message}

        {:error, :timeout} ->
          error("timeout", "none", fields)

        {:error, %Ecto.Changeset{}} ->
          error("invalid_input", "none", fields)

        {:error, _} ->
          error("storage_failed", "uncertain", Map.put(fields, :message_status, "unknown"))
      end
    end
  end

  @doc """
  Publishes a persisted handoff as a typed envelope. Call from the Workspace
  workflow's owner-monitored task after artifact persistence. Publication does
  not start an agent or acknowledge remote delivery.
  """
  def publish_handoff(message, context, opts \\ []) do
    with :ok <- context(context),
         :ok <- handoff_message(message, context),
         {:ok, opts} <- options(opts, @operation_timeout) do
      fields = receipt(message) |> Map.put(:message_status, "persisted")

      case publish("agent:#{message.to_agent_id}", envelope(message), opts) do
        :ok ->
          {:ok, Map.put(fields, :mailbox_publication, "published")}

        {:error, :timeout} ->
          error("timeout", "completed", Map.put(fields, :mailbox_publication, "not_published"))

        {:error, _} ->
          error(
            "publication_failed",
            "uncertain",
            Map.put(fields, :mailbox_publication, "unknown")
          )
      end
    end
  end

  def send(input, context, opts \\ []) do
    with :ok <- validate("send", input),
         :ok <- context(context),
         {:ok, opts} <- options(opts, @operation_timeout),
         :ok <- before_effect(opts) do
      level = Map.get(input, "type", "notification")
      payload = %{"content" => input["content"], "metadata" => Map.get(input, "metadata", %{})}
      payload = if level == "notification", do: payload, else: Map.put(payload, "level", level)
      attrs = attrs(context, input["to"], "notification", payload)

      case AgentMessages.create(attrs, opts) do
        {:ok, message} ->
          result = receipt(message)

          case publish("agent:#{message.to_agent_id}", envelope(message), opts) do
            :ok -> output({:ok, Map.put(result, :publication, "published")})
            {:error, reason} -> publication_error(reason, result)
          end

        {:error, reason} ->
          storage_error(reason, "uncertain")
      end
    end
  end

  def reply(input, context, opts \\ []) do
    with :ok <- validate("reply", input),
         :ok <- context(context),
         {:ok, opts} <- options(opts, @operation_timeout),
         :ok <- before_effect(opts) do
      attrs = %{
        ref: Ecto.UUID.generate(),
        from_agent_id: context.agent_id,
        session_id: context.session_id,
        payload: %{"content" => input["content"], "status" => Map.get(input, "status", "success")}
      }

      case AgentMessages.reply(input["ref"], context.agent_id, attrs, opts) do
        {:ok, %{response: response, request: request}} ->
          result = Map.put(receipt(response), :in_reply_to, request.ref)

          case publish(
                 "agent_reply:#{request.ref}",
                 {:agent_reply, request.ref, response.payload},
                 opts
               ) do
            :ok ->
              case publish("agent:#{response.to_agent_id}", envelope(response), opts) do
                :ok -> output({:ok, Map.put(result, :publication, "published")})
                {:error, reason} -> publication_error(reason, result, true)
              end

            {:error, reason} ->
              publication_error(reason, result)
          end

        {:error, {:storage, _} = reason} ->
          storage_error(reason, "uncertain")

        {:error, %Ecto.Changeset{}} ->
          error("invalid_input", "none")

        {:error, reason} ->
          error(reason, "none")
      end
    end
  end

  def inbox(input, context, opts \\ []) do
    with :ok <- validate("inbox", input),
         :ok <- context(context),
         {:ok, opts} <- options(opts, @operation_timeout),
         :ok <- before_effect(opts) do
      query_opts =
        Keyword.merge(opts,
          limit: Map.get(input, "limit", if(input["action"] == "thread", do: 50, else: 20)),
          ref: input["ref"],
          type: input["type"],
          since: input["since"]
        )

      with {:ok, messages} <-
             read(AgentMessages.query(input["action"], context.agent_id, query_opts)),
           {:ok, _} <- inbox_output(messages),
           {:ok, messages} <- mark_unread(input["action"], messages, opts) do
        inbox_output(messages)
      end
    end
  end

  def ask(input, context, opts \\ []) do
    with :ok <- validate("ask", input),
         :ok <- context(context),
         :ok <- primary(context),
         {:ok, opts} <- options(opts, Map.get(input, "timeout_ms", @ask_timeout)),
         :ok <- before_effect(opts) do
      owner = self()
      token = make_ref()

      {guardian, monitor} =
        spawn_monitor(fn -> ask_guardian(owner, token, input, context, opts) end)

      receive do
        {^token, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^guardian, _reason} ->
          error("ask_owner_failed", "uncertain")
      end
    end
  end

  def validate(operation, input) when is_map(input) and not is_struct(input) do
    valid =
      case operation do
        "handoff" ->
          closed?(input, ~w(to summary instructions artifacts priority constraints)) and
            mailbox?(input["to"]) and text?(input["summary"], @text_limit) and
            text?(input["instructions"], @text_limit) and
            Map.get(input, "priority", "normal") in ~w(low normal high critical) and
            json_object?(Map.get(input, "constraints", %{})) and
            handoff_artifacts?(Map.get(input, "artifacts", [])) and
            byte_size(Jason.encode!(input)) <= @handoff_limit

        "send" ->
          closed?(input, ~w(to content type metadata)) and mailbox?(input["to"]) and
            text?(input["content"], @text_limit) and
            Map.get(input, "type", "notification") in ~w(notification info warning) and
            json_object?(Map.get(input, "metadata", %{}))

        "ask" ->
          closed?(input, ~w(to question context timeout_ms)) and mailbox?(input["to"]) and
            text?(input["question"], @text_limit) and json_object?(Map.get(input, "context", %{})) and
            is_integer(Map.get(input, "timeout_ms", @ask_timeout)) and
            Map.get(input, "timeout_ms", @ask_timeout) in 1..@max_ask_timeout

        "reply" ->
          closed?(input, ~w(ref content status)) and mailbox?(input["ref"]) and
            text?(input["content"], @text_limit) and
            Map.get(input, "status", "success") in @reply_statuses

        "inbox" ->
          closed?(input, ~w(action ref limit since type)) and
            input["action"] in ~w(unread history thread) and
            (input["action"] != "thread" or mailbox?(input["ref"])) and
            (not Map.has_key?(input, "ref") or mailbox?(input["ref"])) and
            is_integer(Map.get(input, "limit", 20)) and Map.get(input, "limit", 20) in 1..100 and
            (not Map.has_key?(input, "type") or input["type"] in @mail_types) and
            (not Map.has_key?(input, "since") or datetime?(input["since"]))

        _ ->
          false
      end

    if valid, do: :ok, else: error("invalid_input", "none")
  end

  def validate(_, _), do: error("invalid_input", "none")

  defp ask_guardian(owner, token, input, context, opts) do
    owner_monitor = Process.monitor(owner)
    ref = Ecto.UUID.generate()
    topic = "agent_reply:#{ref}"

    result =
      case subscribe(topic) do
        :ok ->
          result = start_ask(owner, owner_monitor, ref, input, context, opts)

          case unsubscribe(topic) do
            :ok -> result
            {:error, _} -> error("subscription_cleanup_failed", "uncertain")
          end

        {:error, _} ->
          error("subscription_failed", "none")
      end

    Process.demonitor(owner_monitor, [:flush])
    Kernel.send(owner, {token, result})
  end

  defp start_ask(owner, monitor, ref, input, context, opts) do
    with :ok <- owner_alive(owner),
         :ok <- before_effect(opts) do
      remaining = opts[:deadline] - now()

      request_attrs =
        attrs(context, input["to"], "request", %{
          "question" => input["question"],
          "context" => Map.get(input, "context", %{})
        })
        |> Map.merge(%{
          ref: ref,
          expires_at: DateTime.add(DateTime.utc_now(), max(0, remaining), :millisecond)
        })

      case AgentMessages.create(request_attrs, opts) do
        {:ok, request} ->
          with :ok <- owner_alive(owner),
               :ok <- publish("agent:#{request.to_agent_id}", envelope(request), opts) do
            wait_reply(owner, monitor, request, opts)
          else
            {:error, %{code: code}} -> finish_ask(request, code, opts)
            {:error, reason} -> finish_ask(request, reason, opts)
          end

        {:error, reason} ->
          storage_error(reason, "uncertain")
      end
    end
  end

  defp wait_reply(owner, monitor, request, opts) do
    remaining = max(0, opts[:deadline] - now())

    receive do
      {:DOWN, ^monitor, :process, ^owner, _} ->
        finish_ask(request, "caller_cancelled", opts)

      {:agent_reply, ref, _untrusted_payload} when ref == request.ref ->
        case durable_response(request, opts) do
          {:ok, response} -> response_output(request, response)
          {:error, :not_found} -> wait_reply(owner, monitor, request, opts)
          {:error, reason} -> finish_ask(request, reason, opts)
        end
    after
      remaining -> finish_ask(request, "timeout", opts)
    end
  end

  defp finish_ask(request, reason, opts) do
    cleanup_opts = Keyword.put(opts, :deadline, now() + @operation_timeout)

    case AgentMessages.expire_request(request.id, cleanup_opts) do
      {:ok, %{status: "acknowledged"}} ->
        case durable_response(request, cleanup_opts) do
          {:ok, response} ->
            response_output(request, response)

          {:error, _} ->
            error("response_unavailable", "completed", %{
              request_id: request.id,
              ref: request.ref,
              request_status: "acknowledged"
            })
        end

      {:ok, %{status: "expired"}} ->
        code =
          case reason do
            {:storage, _} -> "storage_failed"
            value when is_atom(value) -> Atom.to_string(value)
            value when is_binary(value) -> value
            _ -> "request_failed"
          end

        error(code, "completed", %{
          request_id: request.id,
          ref: request.ref,
          request_status: "expired"
        })

      _ ->
        error("request_cleanup_failed", "uncertain", %{
          request_id: request.id,
          ref: request.ref,
          request_status: "unknown"
        })
    end
  end

  defp durable_response(request, opts) do
    with {:ok, current} <- AgentMessages.fetch(request.id, opts),
         {:ok, messages} <-
           AgentMessages.query(
             "thread",
             request.from_agent_id,
             Keyword.put(opts, :ref, request.ref)
           ) do
      response =
        Enum.find(messages, fn message ->
          message.type == "response" and message.in_reply_to == request.id and
            message.from_agent_id == request.to_agent_id and
            message.to_agent_id == request.from_agent_id
        end)

      if current.status == "acknowledged" and response != nil,
        do: {:ok, response},
        else: {:error, :not_found}
    end
  end

  defp response_output(request, response) do
    output(
      {:ok,
       %{
         status: "received",
         request_id: request.id,
         ref: request.ref,
         response_id: response.id,
         response: response.payload
       }},
      "completed"
    )
  end

  defp attrs(context, to, type, payload) do
    %{
      ref: Ecto.UUID.generate(),
      from_agent_id: context.agent_id,
      to_agent_id: to,
      type: type,
      payload: payload,
      session_id: context.session_id
    }
  end

  defp handoff_message(%Synapsis.AgentMessage{type: "handoff"} = message, context) do
    if message.from_agent_id == context.agent_id and message.session_id == context.session_id and
         match?({:ok, _}, Ecto.UUID.cast(message.id)) and
         match?({:ok, _}, Ecto.UUID.cast(message.ref)) and
         match?(%DateTime{}, message.inserted_at) and is_map(message.payload) do
      validate("handoff", Map.put(message.payload, "to", message.to_agent_id))
    else
      error("invalid_context", "none")
    end
  end

  defp handoff_message(_, _), do: error("invalid_context", "none")

  defp handoff_artifacts?(paths) when is_list(paths),
    do: length(paths) <= 64 and Enum.all?(paths, &handoff_reference?/1)

  defp handoff_artifacts?(_), do: false

  defp handoff_reference?("@synapsis/" <> path = reference) do
    text?(reference, 1024) and not String.contains?(path, ["\\", "\0"]) and
      case String.split(path, "/") do
        [scope, _ | _] = segments when scope in ["agents", "shared", "global"] ->
          Enum.all?(segments, &(&1 not in ["", ".", ".."]))

        _ ->
          false
      end
  end

  defp handoff_reference?(_), do: false

  defp receipt(message),
    do: %{status: "persisted", message_id: message.id, ref: message.ref, to: message.to_agent_id}

  defp envelope(message) do
    type =
      case message.type do
        "request" -> :request
        "response" -> :response
        "handoff" -> :handoff
        _ -> :notification
      end

    {:agent_envelope,
     %{
       from: message.from_agent_id,
       to: message.to_agent_id,
       ref: message.ref,
       type: type,
       payload: message.payload,
       timestamp: message.inserted_at
     }}
  end

  defp mark_unread("unread", messages, opts) do
    case AgentMessages.mark_messages_read(messages, opts) do
      {:ok, messages} -> {:ok, messages}
      {:error, reason} -> storage_error(reason, "uncertain")
    end
  end

  defp mark_unread(_, messages, _opts), do: {:ok, messages}

  defp inbox_output(messages) do
    formatted =
      Enum.map(messages, fn message ->
        %{
          id: message.id,
          ref: message.ref,
          from: message.from_agent_id,
          to: message.to_agent_id,
          type: message.type,
          status: message.status,
          payload: message.payload,
          session_id: message.session_id,
          in_reply_to: message.in_reply_to,
          created_at: DateTime.to_iso8601(message.inserted_at)
        }
      end)

    output({:ok, %{messages: formatted, count: length(formatted)}})
  rescue
    _ -> error("invalid_record", "none")
  end

  defp context(context) when is_map(context) do
    id = context[:session_id]

    if mailbox?(context[:agent_id]) and is_binary(id) and match?({:ok, ^id}, Ecto.UUID.cast(id)),
      do: :ok,
      else: error("invalid_context", "none")
  end

  defp context(_), do: error("invalid_context", "none")
  defp primary(%{primary: true}), do: :ok
  defp primary(_), do: error("primary_only", "none")

  defp owner_alive(owner),
    do: if(Process.alive?(owner), do: :ok, else: error("caller_cancelled", "none"))

  defp options(opts, timeout) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :kv] == [] and
         (not Keyword.has_key?(opts, :deadline) or is_integer(opts[:deadline])) do
      {:ok,
       Keyword.put(
         opts,
         :deadline,
         min(Keyword.get(opts, :deadline, now() + timeout), now() + timeout)
       )}
    else
      error("invalid_context", "none")
    end
  end

  defp before_effect(opts),
    do: if(opts[:deadline] > now(), do: :ok, else: error("timeout", "none"))

  defp now, do: System.monotonic_time(:millisecond)

  defp publish(topic, event, opts) do
    if opts[:deadline] > now() do
      case Phoenix.PubSub.broadcast(Synapsis.PubSub, topic, event) do
        :ok -> :ok
        _ -> {:error, :publication_failed}
      end
    else
      {:error, :timeout}
    end
  rescue
    _ -> {:error, :publication_failed}
  catch
    :exit, _ -> {:error, :publication_failed}
  end

  defp subscribe(topic) do
    Phoenix.PubSub.subscribe(Synapsis.PubSub, topic)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp unsubscribe(topic) do
    Phoenix.PubSub.unsubscribe(Synapsis.PubSub, topic)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp publication_error(reason, result, reply_published \\ false)

  defp publication_error(:timeout, result, true) do
    fields =
      Map.merge(result, %{
        publication: "partial",
        reply_publication: "published",
        mailbox_publication: "not_published"
      })

    error("timeout", "completed", fields)
  end

  defp publication_error(_, result, true) do
    fields =
      Map.merge(result, %{
        publication: "partial",
        reply_publication: "published",
        mailbox_publication: "unknown"
      })

    error("publication_failed", "uncertain", fields)
  end

  defp publication_error(:timeout, result, false),
    do: error("timeout", "completed", Map.put(result, :publication, "not_published"))

  defp publication_error(_, result, false),
    do: error("publication_failed", "uncertain", Map.put(result, :publication, "unknown"))

  defp read({:ok, _} = result), do: result
  defp read({:error, reason}), do: storage_error(reason, "none")
  defp storage_error(:timeout, _effect), do: error("timeout", "none")
  defp storage_error({:storage, _}, effect), do: error("storage_failed", effect)
  defp storage_error(%Ecto.Changeset{}, _effect), do: error("invalid_input", "none")
  defp storage_error(reason, effect), do: error(reason, effect)

  defp error(code, effect, fields \\ %{}) do
    code = if is_atom(code), do: Atom.to_string(code), else: code
    {:error, Map.merge(fields, %{code: code, effect: effect})}
  end

  defp output({:ok, result}, effect \\ "none") do
    case Jason.encode(result) do
      {:ok, json} when byte_size(json) <= @output_limit -> {:ok, result}
      _ -> error("output_limit", effect)
    end
  rescue
    _ -> error("output_limit", effect)
  end

  defp closed?(input, keys), do: Map.keys(input) -- keys == []
  defp mailbox?(value), do: text?(value, 256)

  defp text?(value, limit),
    do:
      is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
        String.trim(value) != ""

  defp datetime?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp datetime?(_), do: false

  defp json_object?(value) when is_map(value) and not is_struct(value) do
    :erlang.external_size(value) <= @json_limit * 4 and portable?(value) and
      case Jason.encode(value) do
        {:ok, json} -> byte_size(json) <= @json_limit
        _ -> false
      end
  end

  defp json_object?(_), do: false

  defp portable?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} ->
        is_binary(key) and String.valid?(key) and portable?(item)
      end)

  defp portable?(value) when is_list(value), do: Enum.all?(value, &portable?/1)
  defp portable?(value) when is_binary(value), do: String.valid?(value)
  defp portable?(value), do: is_number(value) or is_boolean(value) or is_nil(value)
end
