defmodule Synapsis.VoiceSession do
  @moduledoc """
  Owns the live transcript, input queue and media lease for a logical voice
  session. The SessionAdapter owns the native Conversation, tool effects and
  collaboration, including tasks that continue after the controller disconnects.
  """
  use GenServer, restart: :temporary
  require Logger

  alias Synapsis.Agent.{ContextBuilder, Resolver}
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.Runtime.SessionAdapter
  alias Synapsis.Agent.Tools.MCPSources
  alias Synapsis.Provider.Realtime.{Catalog, Connection, Protocol}
  alias Synapsis.Voice.{AudioEndpoint.Host, DeviceCallIntent, DeviceCallRestorer, History, Sync}
  alias Synapsis.{AgentConfig, AgentConfigs, Part, Providers, Sessions}

  @registry Synapsis.Voice.Registry
  @supervisor Synapsis.Voice.Supervisor
  @setup_timeout 12_000
  @max_capture_bytes 1_920
  @max_playback_bytes 96_000
  @max_waiting_frames 16
  @max_waiting_inputs 16
  @max_caption_bytes 32_000
  @max_chat_event_bytes 2_000_000
  @chat_image_types ~w(image/png image/jpeg image/webp)

  def start(session_id, options \\ []) do
    with {:ok, pid} <- find_or_start(session_id) do
      call(pid, {:start, options}, 15_000)
    end
  end

  def status(session), do: call(session, :status)

  def chat_snapshot(session_id) do
    case call(session_id, :chat_snapshot) do
      {:ok, snapshot} ->
        snapshot

      {:error, :voice_timeout} = error ->
        error

      {:error, _} ->
        %{
          revision: 0,
          phase: :offline,
          busy: false,
          queued: 0,
          messages: Sessions.get_messages(session_id),
          facts: History.recovery(session_id),
          reply: nil
        }
    end
  end

  def request_chat_snapshot(session_id), do: cast(session_id, {:chat_snapshot, self()})

  def chat_image(session_id, message_id, turn_index, part_index) do
    case Sessions.get_message_at(session_id, turn_index) do
      {:ok, %{id: ^message_id, parts: parts}} ->
        Enum.at(parts, part_index)

      _ ->
        call(session_id, {:chat_image, message_id, turn_index, part_index})
    end
  end

  def chat_topic(session_id), do: "voice-chat:" <> session_id
  def stop(session), do: call(session, :stop, 7_000)
  def stop_playback(session), do: call(session, :stop_playback, 7_000)
  def mute(session, value) when is_boolean(value), do: call(session, {:mute, value}, 7_000)
  def commit(session), do: call(session, :commit)
  def switch(session, options), do: call(session, {:switch, options}, 12_000)
  def cancel_task(session, agent, run), do: call(session, {:cancel_task, agent, run})

  def submit(session, text, images) when is_binary(text) and is_list(images) do
    text = String.trim(text)

    cond do
      text == "" and images == [] ->
        {:error, :empty_voice_message}

      not Enum.all?(
        images,
        &match?(%Synapsis.Part.Image{media_type: type} when type in @chat_image_types, &1)
      ) ->
        {:error, :unsupported_voice_image}

      true ->
        parts = if text == "", do: images, else: [%Synapsis.Part.Text{content: text} | images]

        with {:ok, [%{content: blocks}]} <-
               ProviderMessages.from_host([%{role: :user, parts: parts}]),
             event = Protocol.input_item("item_" <> String.duplicate("x", 24), blocks),
             true <- byte_size(JSON.encode!(event)) <= @max_chat_event_bytes do
          {[], content, payloads} = ProviderMessages.reference_images([], blocks)
          call(session, {:submit_chat, content, payloads})
        else
          false -> {:error, :voice_message_too_large}
          _ -> {:error, :invalid_voice_message}
        end
    end
  end

  def browser_ready(session, generation, info),
    do: call(session, {:browser_ready, generation, info})

  def capture(session, generation, seq, pcm), do: call(session, {:capture, generation, seq, pcm})

  def playback_ack(session, generation, seq),
    do: cast(session, {:playback_ack, self(), generation, seq})

  def cursor(session, generation, position),
    do: cast(session, {:cursor, self(), generation, position})

  def flushed(session, generation, token, position),
    do: cast(session, {:flushed, self(), generation, token, position})

  def browser_error(session, generation, reason),
    do: cast(session, {:browser_error, self(), generation, reason})

  def devices(:host), do: Host.devices()
  def topic(session_id), do: "voice-status:" <> session_id

  def delete(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, session_id}})
  end

  @doc false
  def ensure_device_call_owner(id) do
    with {:ok, session} <- Sessions.get(id),
         true <- Sessions.host_voice?(session) or {:error, :fixed_host_session} do
      find_or_start(id)
    end
  end

  defp find_or_start(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, session_id: session_id}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, {:shutdown, reason}} -> {:error, reason}
          result -> result
        end
    end
  end

  defp call(session, request, timeout \\ 5_000)

  defp call(pid, :chat_snapshot, timeout) when is_pid(pid) do
    GenServer.call(pid, :chat_snapshot, timeout)
  catch
    :exit, {:timeout, _} ->
      if Process.alive?(pid), do: {:error, :voice_timeout}, else: {:error, :voice_unavailable}
  end

  defp call(pid, request, timeout) when is_pid(pid), do: GenServer.call(pid, request, timeout)

  defp call(id, request, timeout) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> call(pid, request, timeout)
      [] -> if(request == :status, do: {:ok, %{phase: :offline}}, else: {:error, :voice_offline})
    end
  catch
    :exit, _ -> {:error, :voice_unavailable}
  end

  defp cast(id, request) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> GenServer.cast(pid, request)
      [] -> :ok
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :session_id)

    with {:ok, session} <- Sessions.get(id),
         true <- Sessions.voice?(session) or {:error, :voice_session_required},
         {:ok, device_call} <- saved_device_call(session),
         {:ok, adapter} <-
           SessionAdapter.start_link(
             session_id: id,
             owner: self(),
             epoch: make_ref(),
             voice: true
           ) do
      messages = Sessions.get_messages(id)

      {canonical, [], image_payloads} =
        ProviderMessages.reference_images(History.initial(messages), [])

      {:ok,
       %{
         session: session,
         adapter: adapter,
         context: nil,
         device_call: device_call,
         retry_timer: nil,
         retry_delay: 0,
         controller: nil,
         controller_ref: nil,
         endpoint: nil,
         endpoint_info: nil,
         generation: nil,
         connection_generation: nil,
         socket: nil,
         socket_ref: nil,
         session_ready: false,
         runtime_ready: false,
         options: nil,
         phase: :offline,
         reason: nil,
         muted: device_call != nil and device_call.muted,
         input_seq: 0,
         capture_bytes: 0,
         output_seq: 0,
         output_ack: 0,
         sync: Sync.new(),
         attempt: nil,
         playback: %{},
         flush: nil,
         truncation_writes: MapSet.new(),
         playback_order: 0,
         chat_messages: messages,
         unarchived: [],
         chat_ids: MapSet.new(messages, & &1.id),
         chat_reply: nil,
         chat_snapshot: nil,
         status_timer: false,
         admitted_audio: MapSet.new(),
         microphone: nil,
         preparing_audio: nil,
         speech_catalog: nil,
         speaking: nil,
         inputs: :queue.new(),
         run_phase: :idle,
         canonical: canonical,
         image_payloads: image_payloads,
         confirmed: History.recovery(id),
         roster: %{agents: []},
         child_results: %{},
         projection: nil,
         projection_queue: :queue.new()
       }, {:continue, :restore_device_call}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp saved_device_call(session) do
    if Sessions.host_voice?(session) do
      case DeviceCallIntent.load(session.id) do
        {:ok, %{active: true} = intent} -> {:ok, intent}
        {:ok, %{active: false}} -> {:ok, nil}
        :not_found -> {:ok, nil}
        error -> error
      end
    else
      {:ok, nil}
    end
  end

  @impl true
  def handle_continue(:restore_device_call, %{device_call: nil} = state), do: {:noreply, state}

  def handle_continue(:restore_device_call, state),
    do: {:noreply, publish(%{state | phase: :reconnecting})}

  @impl true
  def handle_call(:status, _, state), do: {:reply, {:ok, public(state)}, state}

  def handle_call(:chat_snapshot, _, state),
    do: {:reply, {:ok, current_chat_snapshot(state)}, state}

  def handle_call({:chat_image, id, turn_index, part_index}, _, state) do
    message =
      case Enum.at(state.chat_messages, turn_index) do
        %{id: ^id} = message -> message
        _ -> Enum.find(state.chat_messages, &(&1.id == id))
      end

    image =
      with %{parts: parts} <- message,
           %Part.Image{} = image <- Enum.at(parts, part_index) do
        image
      else
        _ -> nil
      end

    {:reply, image, state}
  end

  def handle_call({:start, opts}, {owner, _}, %{phase: phase, device_call: nil} = state)
      when phase in [:offline, :error] do
    with {:ok, options} <- saved_endpoint_options(state.session, opts) do
      case options.mode do
        "host" ->
          with {:ok, intent} <- DeviceCallIntent.save(state.session.id, true, false, opts) do
            DeviceCallRestorer.watch(state.session.id, self())
            next = connect_device(%{state | device_call: intent, muted: false}, options)
            {:reply, {:ok, public(next)}, next}
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end

        "browser" ->
          case connect(%{state | muted: false}, owner, options) do
            {:ok, next} -> {:reply, {:ok, public(next)}, next}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start, _}, _, state), do: {:reply, {:error, :media_lease_in_use}, state}

  def handle_call({:submit_chat, content, images}, _, %{phase: phase} = state)
      when phase in [:listening, :responding] do
    if :queue.len(state.inputs) < @max_waiting_inputs do
      state = %{state | inputs: :queue.in({content, images}, state.inputs)}

      {:reply, :ok, state |> offer_input() |> publish_chat()}
    else
      {:reply, {:error, :voice_input_queue_full}, state}
    end
  end

  def handle_call({:submit_chat, _, _}, _, state), do: {:reply, {:error, :voice_offline}, state}

  def handle_call({:response, _ref, _request, _instructions}, _, %{phase: phase} = state)
      when phase not in [:listening, :responding],
      do: {:reply, :offline, state}

  def handle_call({:response, ref, request, instructions}, {owner, _}, state) do
    case List.last(request.messages) do
      %{role: :user, content: [%{live_microphone: true, connection_generation: gen}]}
      when gen != state.connection_generation ->
        {:reply, :offline, state}

      _ ->
        subscribe(ref, request, instructions, owner, state)
    end
  end

  def handle_call({:cancel_task, agent, run}, _, state),
    do: {:reply, SessionAdapter.cancel_child(state.adapter, agent, run), state}

  def handle_call(request, _, %{device_call: intent} = state) when not is_nil(intent),
    do: control(request, state)

  def handle_call(request, {controller, _}, %{controller: controller} = state) do
    control(request, state)
  end

  def handle_call(_, _, state), do: {:reply, {:error, :media_lease_required}, state}

  defp connect(state, owner, options) do
    with {:ok, context, connection} <- prepare_context(state),
         {:ok, socket} <- Connection.open(connection, context.agent.voice_model) do
      generation = Ecto.UUID.generate()
      Process.send_after(self(), {:setup_timeout, generation}, @setup_timeout)

      next = %{
        state
        | controller: owner,
          controller_ref: if(owner, do: Process.monitor(owner)),
          phase: :connecting,
          reason: nil,
          connection_generation: generation,
          generation: Ecto.UUID.generate(),
          context: context,
          options: options,
          socket: socket,
          socket_ref: Process.monitor(Connection.owner(socket)),
          sync: Sync.new(),
          admitted_audio: MapSet.new(),
          playback: %{},
          capture_bytes: 0,
          input_seq: 0,
          output_seq: 0,
          output_ack: 0
      }

      {:ok, publish(next)}
    end
  end

  defp connect_device(state, options) do
    case connect(state, nil, options) do
      {:ok, next} -> next
      {:error, reason} -> schedule_reconnect(state, reason)
    end
  end

  defp reconnect_device(state) do
    case saved_endpoint_options(state.session, state.device_call.options) do
      {:ok, options} -> connect_device(state, options)
      {:error, reason} -> schedule_reconnect(state, reason)
    end
  end

  defp schedule_reconnect(%{retry_timer: nil} = state, reason) do
    delay = if state.run_phase == :failed, do: 10_000, else: state.retry_delay
    timer = :erlang.start_timer(delay, self(), :reconnect_device)
    delay = min(max(state.retry_delay * 2, 500), 10_000)

    publish(%{
      state
      | phase: :reconnecting,
        reason: reason,
        retry_timer: timer,
        retry_delay: delay
    })
  end

  defp schedule_reconnect(state, reason),
    do: publish(%{state | phase: :reconnecting, reason: reason})

  defp subscribe(ref, request, instructions, owner, %{attempt: %{owner: nil} = live} = state) do
    # Media may finish while Conversation is preparing this same microphone
    # turn. Only the matching native subscription can receive its tool calls.
    {tools, names} = Protocol.tools(request.tools)
    last = List.last(request.messages)

    staged =
      Sync.stage(
        state.sync,
        request.messages,
        state.connection_generation,
        state.confirmed,
        state.image_payloads
      )

    if match?(
         %{role: :user, content: [%{item_id: item, connection_generation: gen}]}
         when item == live.item and gen == state.connection_generation,
         last
       ) and
         tools == live.tools and names == live.names and instructions == live.instructions and
         match?({[], _}, staged) do
      {[], sync} = staged
      attempt = %{live | ref: ref, owner: owner, monitor: Process.monitor(owner)}
      if attempt.id, do: emit(attempt, %{type: :response_started})

      if state.chat_reply.text != "",
        do: emit(attempt, %{type: :content_text_delta, delta: state.chat_reply.text})

      state = %{state | attempt: attempt, sync: sync}
      state = if live.done, do: receive_realtime(state, live.done), else: state
      {:reply, :ok, state}
    else
      # A different catalog or new native history requires a fresh authorized
      # response. Retire this one without exposing any unverified tool output.
      send(
        owner,
        {:voice_response, ref, %{type: :response_interrupted, reason: "voice_context_changed"}}
      )

      state = %{state | speech_catalog: nil, microphone: state.microphone || live.item}

      state =
        interrupt(
          put_in(state.attempt.interrupt, "voice_context_changed"),
          "voice_context_changed"
        )

      state = if live.done, do: abandon_live_reply(state), else: state
      {:reply, :ok, state}
    end
  end

  defp subscribe(ref, request, instructions, owner, %{attempt: nil} = state) do
    {tools, names} = Protocol.tools(request.tools)

    staged =
      Sync.stage(
        state.sync,
        request.messages,
        state.connection_generation,
        state.confirmed,
        state.image_payloads
      )

    case staged do
      {:error, reason} ->
        {:reply, {:error, reason}, disconnect(state, reason)}

      {events, sync} ->
        stage_response(state, events, sync, {ref, owner, request, instructions, tools, names})
    end
  end

  defp subscribe(_, _, _, _, state), do: {:reply, {:error, :response_busy}, state}

  defp stage_response(state, events, sync, {ref, owner, request, instructions, tools, names}) do
    state = append_chat(state, request.messages)
    attempt = new_attempt(request.attempt_id, instructions, tools, names)
    attempt = %{attempt | ref: ref, owner: owner, monitor: Process.monitor(owner)}
    state = %{state | sync: sync, speech_catalog: nil} |> start_attempt(attempt)

    if map_size(sync.pending) <= 128 and Enum.all?(events, &(wire(state, &1) == :ok)) do
      {:reply, :ok, state |> dispatch_response() |> publish()}
    else
      {:reply, :ok, disconnect(state, :realtime_sync_failed)}
    end
  end

  defp new_attempt(token, instructions, tools, names) do
    %{
      token: token,
      chat_id: "voice-" <> token,
      id: nil,
      item: nil,
      ref: nil,
      owner: nil,
      monitor: nil,
      done: nil,
      names: names,
      tools: tools,
      instructions: instructions,
      dispatched: false,
      interrupt: nil,
      cancel_sent: false
    }
  end

  defp start_attempt(state, attempt) do
    %{state | attempt: attempt, phase: :responding, chat_reply: %{id: attempt.chat_id, text: ""}}
  end

  defp start_live_reply(
         %{
           attempt: nil,
           speaking: nil,
           flush: nil,
           speech_catalog: catalog,
           sync: %{pending: pending},
           run_phase: :busy
         } = state
       )
       when not is_nil(catalog) and map_size(pending) == 0 do
    item = state.microphone || state.preparing_audio

    if is_binary(item) and state.preparing_audio in [nil, item] and
         MapSet.member?(state.admitted_audio, item) do
      {instructions, tools, names} = catalog
      attempt = %{new_attempt(Ecto.UUID.generate(), instructions, tools, names) | item: item}

      Process.send_after(self(), {:await_voice_subscription, attempt.token}, @setup_timeout * 2)

      state
      |> Map.put(:speech_catalog, nil)
      |> start_attempt(attempt)
      |> dispatch_response()
      |> publish()
    else
      state
    end
  end

  defp start_live_reply(state), do: state

  defp abandon_live_reply(state) do
    %{state | attempt: nil, preparing_audio: nil, phase: :listening, chat_reply: nil}
    |> offer_input()
    |> publish()
  end

  defp control(:stop, %{device_call: intent} = state) when not is_nil(intent) do
    case DeviceCallIntent.save(state.session.id, false, false, []) do
      {:ok, _} ->
        if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
        state = %{state | device_call: nil, retry_timer: nil, retry_delay: 0}
        {:reply, :ok, hangup(state, nil)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp control(:stop, state), do: {:reply, :ok, hangup(state, nil)}
  defp control(:stop_playback, state), do: {:reply, :ok, interrupt(state, "stop_playback")}

  defp control({:mute, value}, %{device_call: intent} = state) when not is_nil(intent) do
    case DeviceCallIntent.save(state.session.id, true, value, intent.options) do
      {:ok, intent} ->
        state = %{state | device_call: intent, muted: value}

        case state.endpoint_info && mute_endpoint(state.endpoint, value) do
          {:error, reason} -> {:reply, :ok, disconnect(state, reason)}
          _ -> {:reply, :ok, publish(state)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp control({:mute, value}, state) do
    case mute_endpoint(state.endpoint, value) do
      :ok ->
        {:reply, :ok, publish(%{state | muted: value})}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp control(
         :commit,
         %{
           context: %{agent: %{voice_turn_detection: "manual"}},
           capture_bytes: bytes,
           muted: false
         } = state
       )
       when bytes >= 4_800 do
    {:reply, wire(state, Protocol.commit()), %{state | capture_bytes: 0}}
  end

  defp control(:commit, state), do: {:reply, {:error, :no_manual_audio}, state}

  defp control(
         {:browser_ready, generation, info},
         %{generation: generation, endpoint: :browser} = state
       )
       when is_map(info) and map_size(info) <= 8 do
    next =
      %{
        state
        | endpoint_info:
            Map.take(info, [
              "input_device",
              "output_device",
              "echo_cancellation",
              "output_selection",
              "identity"
            ])
      }
      |> ready()

    {:reply, :ok, next}
  end

  defp control(
         {:capture, generation, seq, pcm},
         %{generation: generation, endpoint: :browser, input_seq: previous} = state
       )
       when is_integer(seq) and seq == previous + 1 do
    if valid_capture?(pcm) do
      {:reply, :ok, collect(%{state | input_seq: seq}, pcm)}
    else
      {:reply, {:error, :invalid_pcm}, state}
    end
  end

  defp control({:switch, opts}, %{session_ready: true, phase: phase, flush: nil} = state)
       when phase in [:listening, :responding] do
    with {:ok, options} <- saved_endpoint_options(state.session, opts),
         {:ok, state} <- save_switch(state, opts) do
      next = interrupt(%{state | phase: :switching}, "audio_endpoint_changed")
      wire(next, Protocol.clear())

      next =
        if next.flush do
          put_in(next.flush.after, {:switch, options})
        else
          switch_endpoint(next, options)
        end

      {:reply, :ok, publish(next)}
    else
      error ->
        {:reply, error, state}
    end
  end

  defp control(_, state), do: {:reply, {:error, :invalid_voice_operation}, state}

  defp save_switch(%{device_call: nil} = state, _), do: {:ok, state}

  defp save_switch(state, opts) do
    with {:ok, intent} <- DeviceCallIntent.save(state.session.id, true, state.muted, opts) do
      {:ok, %{state | device_call: intent}}
    end
  end

  @impl true
  def handle_cast({:chat_snapshot, caller}, state) do
    send(caller, {:voice_chat, state.session.id, current_chat_snapshot(state)})
    {:noreply, state}
  end

  def handle_cast({:retire_response, ref}, %{attempt: %{ref: ref}} = state),
    do: {:noreply, disconnect(state, :realtime_attempt_retired)}

  def handle_cast(
        {:retire_response, ref, :realtime_response_timeout},
        %{attempt: %{ref: ref, dispatched: false}, speaking: item} = state
      )
      when is_binary(item) do
    # A long utterance can outlive the native subscription's idle timeout.
    # Its commit may prepare another attempt on the same media connection.
    next = finish_attempt(state, %{type: :response_interrupted, reason: "awaiting_speech_commit"})
    {:noreply, publish(%{next | phase: :listening, preparing_audio: nil, microphone: nil})}
  end

  def handle_cast(
        {:retire_response, ref, :realtime_response_timeout},
        %{attempt: %{ref: ref}} = state
      ),
      do: {:noreply, disconnect(state, :realtime_response_timeout)}

  def handle_cast(
        {:playback_ack, owner, generation, seq},
        %{controller: owner, generation: generation, output_seq: sent, output_ack: ack} = state
      )
      when is_integer(seq) and seq == ack + 1 and seq <= sent,
      do: {:noreply, %{state | output_ack: seq}}

  def handle_cast(
        {:cursor, owner, generation, position},
        %{controller: owner, generation: generation} = state
      ),
      do: {:noreply, update_cursor(state, position)}

  def handle_cast(
        {:flushed, owner, generation, token, position},
        %{controller: owner, generation: generation, flush: %{token: token}} = state
      ),
      do: {:noreply, finalize_flush(update_cursor(state, position))}

  def handle_cast(
        {:browser_error, owner, generation, reason},
        %{controller: owner, generation: generation} = state
      ),
      do:
        {:noreply,
         hangup(
           state,
           if(is_binary(reason), do: String.slice(reason, 0, 160), else: :browser_audio_failed)
         )}

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:timeout, timer, :reconnect_device},
        %{retry_timer: timer, device_call: intent} = state
      )
      when not is_nil(intent) do
    state = %{state | retry_timer: nil}

    # A failed native adapter cannot admit another prompt. Re-read its journal
    # in a new owner only after all live work and history writes have settled.
    if state.run_phase == :failed and is_nil(state.projection) and
         :queue.is_empty(state.projection_queue) and
         Enum.all?(
           state.roster.agents,
           &(&1[:historical] || &1.status in [:completed, :closed, :interrupted, :errored])
         ) and
         is_nil(SessionAdapter.automation_snapshot(state.adapter).root) do
      {:stop, :normal, state}
    else
      {:noreply, reconnect_device(state)}
    end
  end

  def handle_info(
        {:await_voice_subscription, token},
        %{attempt: %{owner: nil, token: token}} = state
      ),
      do: {:noreply, disconnect(state, :voice_runtime_check_timeout)}

  def handle_info(
        {:setup_timeout, generation},
        %{connection_generation: generation, phase: :connecting, session_ready: false} = state
      ),
      do: {:noreply, disconnect(state, :realtime_setup_timeout)}

  def handle_info(
        {:setup_timeout, generation},
        %{connection_generation: generation, phase: :connecting, runtime_ready: false} = state
      ),
      do: {:noreply, disconnect(state, :voice_runtime_check_timeout)}

  def handle_info(
        {:endpoint_timeout, generation},
        %{generation: generation, endpoint_info: nil} = state
      ),
      do: {:noreply, hangup(state, :audio_endpoint_timeout)}

  def handle_info(
        {:flush_timeout, token},
        %{flush: %{token: token, after: {:switch, _}}} = state
      ),
      do: {:noreply, disconnect(state, :browser_release_unconfirmed)}

  def handle_info({:flush_timeout, token}, %{flush: %{token: token}} = state),
    do: {:noreply, finalize_flush(state)}

  def handle_info(
        {:hangup_timeout, generation},
        %{connection_generation: generation, phase: :ending} = state
      ),
      do: {:noreply, disconnect(state, state.reason || :realtime_cancel_unconfirmed)}

  def handle_info({:DOWN, ref, :process, _, _}, %{controller_ref: ref} = state),
    do: {:noreply, hangup(state, :media_owner_lost)}

  def handle_info({:DOWN, ref, :process, _, _}, %{socket_ref: ref} = state),
    do: {:noreply, disconnect(state, :realtime_disconnected)}

  def handle_info({:DOWN, ref, :process, _, _}, %{attempt: %{monitor: ref}} = state),
    do: {:noreply, disconnect(state, :realtime_attempt_retired)}

  def handle_info({:EXIT, pid, _reason}, %{adapter: pid} = state),
    do: {:stop, :normal, disconnect(state, :runtime_unavailable)}

  def handle_info({:EXIT, pid, _reason}, %{endpoint: {:host, pid}} = state),
    do: {:noreply, hangup(%{state | endpoint: nil}, :host_audio_exited)}

  def handle_info({:audio_endpoint, generation, event}, %{generation: generation} = state),
    do: {:noreply, host_event(state, event)}

  def handle_info(:publish_voice_status, state),
    do: {:noreply, publish(%{state | status_timer: false})}

  def handle_info({:runtime_started, _, _run}, state),
    do: {:noreply, %{state | run_phase: :busy}}

  def handle_info({:runtime_history, _, _, messages}, state),
    do: {:noreply, checkpoint(state, messages)}

  def handle_info({:voice_turn_interrupted, messages}, state),
    do:
      {:noreply,
       state
       |> checkpoint(messages)
       |> Map.put(:run_phase, :waiting)
       |> offer_input()
       |> publish_chat()}

  def handle_info({:runtime_event, _, _, %{type: type, message: %{id: id} = message}}, state)
      when type in [:prompt_consumed, :response_completed] and is_binary(id) do
    {:noreply, state |> append_chat([message]) |> publish_chat()}
  end

  def handle_info({:runtime_event, _, _, %{type: :run_completed}}, state),
    do: {:noreply, state |> Map.put(:run_phase, :idle) |> offer_input() |> publish()}

  def handle_info({:runtime_event, _, _, %{type: type}}, %{phase: :error} = state)
      when type in [:run_failed, :run_cancelled, :storage_failed],
      do: {:noreply, %{state | run_phase: :failed}}

  def handle_info({:runtime_event, _, _, %{type: type}}, state)
      when type in [:run_failed, :run_cancelled, :storage_failed],
      do: {:noreply, disconnect(%{state | run_phase: :failed}, :voice_runtime_failed)}

  def handle_info({:runtime_admission_failed, _, :recovery_required}, state),
    do: {:noreply, disconnect(%{state | run_phase: :failed}, :voice_runtime_requires_recovery)}

  def handle_info({:runtime_admission_failed, _, _}, state),
    do: {:noreply, disconnect(%{state | run_phase: :failed}, :voice_runtime_admission_failed)}

  def handle_info({:voice_input_result, {:ok, _}}, state), do: {:noreply, state}

  def handle_info({:voice_input_result, {:error, _}}, state),
    do: {:noreply, disconnect(state, :voice_input_rejected)}

  def handle_info({:runtime_roster, _, roster}, state) do
    next =
      Enum.reduce(roster.agents, %{state | roster: roster}, fn
        %{status: :completed, run_id: run_id}, acc ->
          if not Map.has_key?(acc.child_results, run_id) and is_binary(roster[:namespace]) do
            acc
            |> put_in([:child_results, run_id], nil)
            |> project_later({:child_result, roster.namespace, run_id})
          else
            acc
          end

        _, acc ->
          acc
      end)

    next =
      case {state.runtime_ready, roster[:recovery_required]} do
        {false, true} ->
          disconnect(%{next | run_phase: :failed}, :voice_runtime_requires_recovery)

        {false, false} ->
          next = %{next | runtime_ready: true}

          if next.device_call && next.phase == :reconnecting && next.retry_timer == nil,
            do: reconnect_device(next),
            else: next |> open_initial_endpoint() |> publish()

        _ ->
          publish(next)
      end

    {:noreply, next}
  end

  def handle_info({:voice_child_cancelled, _agent, _run, {:error, _}}, state),
    do: {:noreply, publish(%{state | reason: :task_cancellation_unconfirmed})}

  def handle_info({ref, reply}, %{projection: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    next = %{state | projection: nil}

    case reply do
      {:child_result, run_id, result} ->
        {:noreply, next |> put_in([:child_results, run_id], result) |> publish() |> project()}

      :ok ->
        {:noreply, next |> project() |> archive_chat()}

      _ ->
        {:noreply, disconnect(next, :voice_storage_failed)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{projection: %{ref: ref}} = state),
    do: {:noreply, disconnect(%{state | projection: nil}, :voice_storage_failed)}

  def handle_info(message, %{socket: socket} = state) when not is_nil(socket) do
    next =
      case Connection.receive_event(message, socket) do
        :open ->
          case wire(state, Protocol.session_update(state.context.agent)) do
            :ok -> state
            _ -> disconnect(state, :realtime_setup_failed)
          end

        {:event, event, receipt} ->
          next = receive_realtime(state, event)
          if next.socket, do: Connection.acknowledge(socket, receipt)
          next

        {:sent, ref} ->
          %{state | truncation_writes: MapSet.delete(state.truncation_writes, ref)}
          |> close_when_settled()

        {:error, reason} ->
          disconnect(state, reason)

        :ignore ->
          state
      end

    {:noreply, next}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    close_endpoint(state.endpoint)
    close_socket(state)
    :ok
  end

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted})

  defp prepare_context(%{run_phase: :failed}), do: {:error, :voice_runtime_requires_recovery}

  defp prepare_context(%{context: context}) when not is_nil(context) do
    with {:ok, config} <- Providers.refresh_runtime_auth(context.provider_config),
         {:ok, connection} <- Catalog.connection(config) do
      {:ok, context, connection}
    end
  end

  defp prepare_context(%{session: session}) do
    with {:ok, %{kind: kind} = agent} when kind in [:voice, :host_voice] <-
           Resolver.resolve_configured(session.agent, session.config),
         {:ok, agent} <- MCPSources.refresh(agent),
         {:ok, config} <- Providers.runtime_config(agent.provider),
         {:ok, config} <- Providers.refresh_runtime_auth(config),
         {:ok, connection} <- Catalog.connection(config),
         workspace = Path.expand(agent.workspace_path || File.cwd!()),
         {:ok, workspace} <- Synapsis.Session.Worker.Boot.ensure_workspace_path(workspace) do
      agent = Map.put(agent, :model, agent.voice_model)

      prompt =
        ContextBuilder.build_system_prompt(:voice,
          agent_config: agent,
          agent_id: agent.name,
          workspace_path: workspace,
          memory_context: session.config["memory_context"] != false
        )

      voice_instructions =
        "You are speaking in a realtime audio call. Keep spoken turns concise. " <>
          "For long work, use spawn_agent with the saved standard Agent name in agent_type, " <>
          "fork_turns=none and a self-contained text task. Continue speaking while it works. " <>
          "The default delegate is #{agent.voice_delegate || "unconfigured"}."

      {:ok,
       %{
         session: session,
         agent: agent,
         provider_config: config,
         project_path: workspace,
         system_prompt: prompt <> "\n\n" <> voice_instructions,
         voice_session: self(),
         messages: [],
         input_context: nil
       }, connection}
    else
      {:ok, _} -> {:error, :voice_agent_required}
      error -> error
    end
  end

  defp saved_endpoint_options(session, opts) when is_list(opts) do
    case AgentConfigs.get_by_name(session.agent) do
      %AgentConfig{enabled: true, kind: kind} = agent when kind in [:voice, :host_voice] ->
        mode = agent.audio_mode

        cond do
          kind == :host_voice and Sessions.host_history?(session, agent) ->
            {:error, :fixed_host_session}

          Sessions.host_voice?(session) and kind != :host_voice ->
            {:error, :agent_unavailable}

          Keyword.get(opts, :mode, mode) != mode ->
            {:error, :invalid_audio_endpoint}

          true ->
            endpoint_options(AgentConfig.audio_profiles(agent), mode, opts)
        end

      _ ->
        {:error, :agent_unavailable}
    end
  end

  defp saved_endpoint_options(_, _), do: {:error, :invalid_audio_endpoint}

  defp endpoint_options(profiles, mode, opts) do
    with {:ok, profile} <- Map.fetch(profiles, mode),
         input = Keyword.get(opts, :input_device, profile.input_device),
         output = Keyword.get(opts, :output_device, profile.output_device),
         true <- valid_device?(input) and valid_device?(output) do
      {:ok, %{profile | input_device: input, output_device: output} |> Map.put(:mode, mode)}
    else
      _ -> {:error, :invalid_audio_endpoint}
    end
  end

  defp valid_device?(nil), do: true
  defp valid_device?(id), do: is_binary(id) and byte_size(id) <= 512 and String.valid?(id)

  defp open_initial_endpoint(
         %{phase: :connecting, session_ready: true, runtime_ready: true, endpoint: nil} = state
       ),
       do: open_endpoint(state)

  defp open_initial_endpoint(state), do: state

  defp open_endpoint(state) do
    Process.send_after(self(), {:endpoint_timeout, state.generation}, @setup_timeout)

    case state.options.mode do
      "host" ->
        case Host.start_link(
               owner: self(),
               muted: state.muted,
               generation: state.generation,
               session_id: state.session.id,
               input_device: state.options.input_device,
               output_device: state.options.output_device,
               input_volume: state.options.input_volume,
               output_volume: state.options.output_volume
             ) do
          {:ok, pid} -> publish(%{state | endpoint: {:host, pid}})
          {:error, reason} -> disconnect(state, reason)
        end

      "browser" ->
        send(state.controller, {:voice_browser_open, state.generation, state.options})
        publish(%{state | endpoint: :browser})
    end
  end

  defp switch_endpoint(state, options) do
    close_endpoint(state.endpoint)

    if state.endpoint == :browser,
      do: send(state.controller, {:voice_browser_close, state.generation})

    %{
      state
      | endpoint: nil,
        endpoint_info: nil,
        generation: Ecto.UUID.generate(),
        options: options,
        input_seq: 0,
        output_seq: 0,
        output_ack: 0,
        muted: state.device_call != nil and state.muted,
        capture_bytes: 0,
        phase: :connecting
    }
    |> open_endpoint()
  end

  defp ready(%{phase: :connecting, session_ready: true} = state) do
    phase = if state.attempt, do: :responding, else: :listening
    %{state | phase: phase, retry_delay: 0} |> offer_input() |> publish()
  end

  defp ready(state), do: state

  defp receive_realtime(%{session_ready: false} = state, %{"type" => "session.updated"}),
    do: open_initial_endpoint(%{state | session_ready: true})

  defp receive_realtime(state, %{
         "type" => "error",
         "error" => %{"code" => "response_cancel_not_active"}
       }),
       do: state

  defp receive_realtime(state, %{"type" => "error"} = event) do
    error = event["error"]
    details = if is_map(error), do: error, else: %{}
    code = safe_realtime_field(details["code"]) || "unknown"
    parameter = safe_realtime_field(details["param"]) || "unknown"

    Logger.warning("voice_realtime_event_rejected code=#{code} parameter=#{parameter}",
      session_id: state.session.id
    )

    disconnect(state, :realtime_protocol_error)
  end

  defp receive_realtime(state, %{"type" => type, "item" => %{"id" => id}})
       when type in [
              "conversation.item.added",
              "conversation.item.created",
              "conversation.item.done"
            ] do
    %{state | sync: Sync.acknowledge(state.sync, id)} |> dispatch_response()
  end

  defp receive_realtime(
         %{phase: phase} = state,
         %{"type" => "input_audio_buffer.speech_started"} = event
       )
       when phase in [:listening, :responding] do
    if MapSet.member?(state.admitted_audio, event["item_id"]) or
         (is_binary(state.speaking) and state.speaking == event["item_id"]) do
      state
    else
      begin_speech(state, event["item_id"])
    end
  end

  defp receive_realtime(%{phase: phase} = state, %{
         "type" => "input_audio_buffer.committed",
         "item_id" => item
       })
       when phase in [:listening, :responding] and is_binary(item) do
    if MapSet.member?(state.admitted_audio, item) do
      state
    else
      message = History.microphone_message(item, state.connection_generation)
      # The gateway already has the PCM. Publish the input at its commit boundary,
      # independently of native tool work or the previous reply's cancellation.
      state = sync_microphone_history(state)

      if state.socket do
        microphone =
          cond do
            state.speaking && state.speaking != item -> state.microphone
            state.preparing_audio == item -> nil
            true -> item
          end

        speaking = if state.speaking == item, do: nil, else: state.speaking

        %{
          state
          | admitted_audio: MapSet.put(state.admitted_audio, item),
            capture_bytes: 0,
            microphone: microphone,
            speaking: speaking,
            sync: Sync.remember(state.sync, item)
        }
        |> append_chat([message])
        |> archive_chat()
        |> dispatch_response()
        |> offer_input()
        |> start_live_reply()
        |> publish_chat()
      else
        state
      end
    end
  end

  defp receive_realtime(state, %{
         "type" => "conversation.item.input_audio_transcription.completed",
         "item_id" => item,
         "transcript" => transcript
       })
       when is_binary(item) and is_binary(transcript) and
              byte_size(transcript) <= @max_caption_bytes do
    if MapSet.member?(state.admitted_audio, item) do
      record_fact(
        state,
        :voice_transcript,
        state.connection_generation <> ":" <> item,
        transcript
      )
    else
      state
    end
  end

  defp receive_realtime(
         %{attempt: %{id: nil, dispatched: true} = attempt} = state,
         %{
           "type" => "response.created",
           "response" => %{"id" => id, "metadata" => %{"attempt" => token}}
         }
       )
       when is_binary(id) and token == attempt.token do
    emit(attempt, %{type: :response_started})
    next = put_in(state.attempt.id, id)
    if attempt.interrupt, do: request_cancel(next), else: next
  end

  defp receive_realtime(
         %{attempt: %{id: id, interrupt: nil}} = state,
         %{
           "type" => "response.output_audio.delta",
           "response_id" => id,
           "delta" => encoded,
           "item_id" => item_id,
           "content_index" => index
         }
       )
       when is_binary(id) and is_binary(encoded) and is_binary(item_id) and is_integer(index) and
              index >= 0 do
    with {:ok, pcm} <- Base.decode64(encoded),
         true <- byte_size(pcm) in 2..@max_playback_bytes and rem(byte_size(pcm), 2) == 0 do
      play(state, pcm, %{response_id: id, item_id: item_id, content_index: index})
    else
      _ -> disconnect(state, :invalid_realtime_audio)
    end
  end

  defp receive_realtime(
         %{attempt: %{id: id, interrupt: nil} = attempt} = state,
         %{"type" => type, "response_id" => id, "delta" => text}
       )
       when is_binary(id) and
              type in ["response.output_audio_transcript.delta", "response.output_text.delta"] and
              is_binary(text) do
    if byte_size(state.chat_reply.text) + byte_size(text) <= @max_caption_bytes do
      emit(attempt, %{type: :content_text_delta, delta: text})
      state |> update_in([:chat_reply, :text], &(&1 <> text)) |> schedule_status()
    else
      disconnect(state, :realtime_caption_limit)
    end
  end

  defp receive_realtime(
         %{attempt: %{id: id, owner: nil} = live} = state,
         %{"type" => "response.done", "response" => %{"id" => id}} = event
       )
       when is_binary(id) do
    if live.interrupt == "voice_context_changed",
      do: abandon_live_reply(state),
      else: put_in(state.attempt.done, event)
  end

  defp receive_realtime(
         %{attempt: %{id: id} = attempt} = state,
         %{"type" => "response.done", "response" => %{"id" => id} = response}
       )
       when is_binary(id) do
    response_status = response["status"]

    next =
      case Protocol.finish(response, attempt.names, attempt.interrupt) do
        {:ok, calls, terminal} ->
          if Enum.any?(calls, &MapSet.member?(state.sync.calls, &1.id)) do
            reject_function_calls(state, response, :realtime_duplicate_call_id)
          else
            finish_realtime_response(state, response["output"], calls, terminal)
          end

        {:error, :invalid_function_call} ->
          reject_function_calls(state, response, :invalid_function_call)

        {:error, :realtime_response_failed}
        when response_status in ["failed", "incomplete", "cancelled"] ->
          code = response_error_code(response["status_details"])

          Logger.warning("voice_response_ended status=#{response_status} code=#{code}",
            session_id: state.session.id
          )

          state =
            if Enum.any?(state.playback, fn {_, item} -> item.response_id == id end),
              do: flush_endpoint(state, false),
              else: state

          state
          |> Map.put(:reason, :realtime_response_failed)
          |> finish_attempt(%{
            type: :response_interrupted,
            reason: "realtime_response_" <> response_status
          })

        {:error, reason} ->
          disconnect(state, reason)
      end

    if next.phase == :responding,
      do: publish(%{next | phase: :listening}),
      else: close_when_settled(next)
  end

  defp receive_realtime(state, _), do: state

  defp begin_speech(state, item_id) do
    state = interrupt(state, "barge_in")

    case item_id do
      item when is_binary(item) ->
        state = sync_microphone_history(state)
        if state.socket, do: offer_input(%{state | speaking: item, microphone: item}), else: state

      _ ->
        state
    end
  end

  defp reject_function_calls(state, response, reason) do
    Logger.warning("voice_function_call_rejected", session_id: state.session.id, reason: reason)
    {output, terminal} = Protocol.finish_without_calls(response)
    finish_realtime_response(%{state | reason: reason}, output, [], terminal)
  end

  defp finish_realtime_response(state, output, calls, terminal) do
    Enum.each(calls, &emit(state.attempt, %{type: :tool_call_completed, tool_call: &1}))

    sync =
      if terminal.type == :response_completed,
        do: Sync.completed(state.sync, output, calls),
        else: state.sync

    catalog =
      if calls == [] and terminal.type == :response_completed and state.preparing_audio do
        {state.attempt.instructions, state.attempt.tools, state.attempt.names}
      end

    terminal = associate_generation(terminal, state.connection_generation)
    # Preserve conversation order if the next utterance commits before the
    # runtime publishes this already completed speech-only turn.
    state =
      case {calls, terminal} do
        {[], %{type: :response_completed, message: %{content: [_ | _]} = message}} ->
          append_chat(state, [Map.put(message, :id, state.attempt.chat_id)])

        _ ->
          state
      end

    state
    |> Map.put(:speech_catalog, catalog)
    |> Map.put(:sync, sync)
    |> mark_generated(state.attempt.id)
    |> finish_attempt(terminal)
  end

  defp response_error_code(%{"error" => error}) when is_map(error),
    do: safe_realtime_field(error["code"]) || safe_realtime_field(error["type"]) || "unknown"

  defp response_error_code(%{"reason" => reason}), do: safe_realtime_field(reason) || "unknown"
  defp response_error_code(_), do: "unknown"

  defp safe_realtime_field(value) when is_binary(value) and byte_size(value) <= 128 do
    if Regex.match?(~r/\A[a-zA-Z0-9_.\[\]-]+\z/, value), do: value
  end

  defp safe_realtime_field(_), do: nil

  defp dispatch_response(
         %{flush: nil, attempt: %{dispatched: false} = attempt, sync: %{pending: pending}} = state
       )
       when map_size(pending) == 0 do
    cond do
      attempt.interrupt ->
        # No response.create was sent, so there will be no response.done event
        # to return the call to listening after barge-in during history sync.
        state = finish_attempt(state, %{type: :response_interrupted, reason: attempt.interrupt})
        if state.phase == :responding, do: publish(%{state | phase: :listening}), else: state

      not is_nil(state.speaking) ->
        state

      true ->
        event =
          Protocol.response(
            attempt.token,
            attempt.instructions,
            attempt.tools,
            Enum.take(state.sync.items, -100)
          )

        case wire(state, event) do
          :ok -> state |> put_in([:attempt, :dispatched], true) |> Map.put(:microphone, nil)
          _ -> disconnect(state, :realtime_response_write_failed)
        end
    end
  end

  defp dispatch_response(state), do: state

  defp offer_input(
         %{
           phase: :responding,
           attempt: %{owner: nil, item: item, interrupt: reason},
           run_phase: run
         } = state
       )
       when run in [:idle, :waiting] and reason != "voice_context_changed" do
    # The previous native run has retired. Attach the new one to the reply
    # already on the wire without requesting another response for this item.
    microphone = if state.microphone == item, do: nil, else: state.microphone

    offer(
      %{state | preparing_audio: item, microphone: microphone},
      History.microphone_prompt(item, state.connection_generation),
      %{},
      run
    )
  end

  defp offer_input(%{phase: :listening, run_phase: run} = state) when run in [:idle, :waiting] do
    case state.microphone do
      item when is_binary(item) ->
        input = History.microphone_prompt(item, state.connection_generation)
        offer(%{state | microphone: nil, preparing_audio: item}, input, %{}, run)

      nil ->
        case :queue.out(state.inputs) do
          {{:value, {input, images}}, inputs} ->
            offer(
              %{state | inputs: inputs, preparing_audio: nil, speech_catalog: nil},
              input,
              images,
              run
            )

          {:empty, _} ->
            state
        end
    end
  end

  defp offer_input(state), do: state

  defp offer(state, input, images, run) do
    if run == :waiting do
      SessionAdapter.voice_input(state.adapter, input)
    else
      context = Map.put(state.context, :native_history, state.canonical)
      SessionAdapter.prompt(state.adapter, context, input)
    end

    next =
      start_live_reply(%{
        state
        | run_phase: :busy,
          image_payloads: Map.merge(state.image_payloads, images)
      })

    if next.reason in [
         :realtime_response_failed,
         :invalid_function_call,
         :realtime_duplicate_call_id
       ],
       do: publish(%{next | reason: nil}),
       else: next
  end

  # Put recovered items on the wire before the first live item. The provider
  # attempt still waits for all created history items to be acknowledged.
  defp sync_microphone_history(%{sync: %{items: []}} = state) do
    # Include every archived speech segment, even ones that shared a reply.
    {history, [], images} =
      ProviderMessages.reference_images(History.initial(state.chat_messages), [])

    case Sync.stage(state.sync, history, state.connection_generation, state.confirmed, images) do
      {events, sync} when is_list(events) ->
        if map_size(sync.pending) <= 128 and Enum.all?(events, &(wire(state, &1) == :ok)),
          do: %{state | sync: sync},
          else: disconnect(state, :realtime_sync_failed)

      {:error, reason} ->
        disconnect(state, reason)
    end
  end

  defp sync_microphone_history(state), do: state

  defp host_event(state, {:ready, info}) do
    # A mute command can arrive while the helper is opening the devices.
    case mute_endpoint(state.endpoint, state.muted) do
      :ok -> ready(%{state | endpoint_info: info})
      {:error, reason} -> disconnect(state, reason)
    end
  end

  defp host_event(state, {:capture, pcm}), do: collect(state, pcm)
  defp host_event(state, {:cursor, cursor}), do: update_cursor(state, cursor)
  defp host_event(state, {:error, reason}), do: hangup(state, reason)

  defp collect(%{phase: phase, muted: false, socket: socket} = state, pcm)
       when not is_nil(socket) and phase in [:listening, :responding] do
    if valid_capture?(pcm) and wire(state, Protocol.append(pcm)) == :ok do
      %{state | capture_bytes: min(9_600, state.capture_bytes + byte_size(pcm))}
    else
      disconnect(state, :realtime_capture_failed)
    end
  end

  defp collect(state, _), do: state

  defp valid_capture?(pcm),
    do: is_binary(pcm) and byte_size(pcm) in 2..@max_capture_bytes and rem(byte_size(pcm), 2) == 0

  defp play(%{flush: flush} = state, _, _) when not is_nil(flush), do: state

  defp play(state, pcm, metadata) do
    key = {metadata.item_id, metadata.content_index}

    item =
      Map.get(
        state.playback,
        key,
        Map.merge(metadata, %{
          samples: 0,
          cursor: nil,
          generated: false,
          order: state.playback_order
        })
      )

    item = %{item | samples: item.samples + div(byte_size(pcm), 2)}

    case playback_frame(state, pcm, metadata) do
      {:ok, next} ->
        emit(state.attempt, %{type: :response_activity})

        put_in(next.playback[key], item)
        |> Map.update!(:playback_order, &(&1 + 1))
        |> schedule_status()

      {:error, reason} ->
        hangup(state, reason)
    end
  end

  defp playback_frame(%{endpoint: :browser} = state, pcm, metadata)
       when state.output_seq - state.output_ack < @max_waiting_frames do
    seq = state.output_seq + 1
    send(state.controller, {:voice_pcm, state.generation, seq, metadata, pcm})
    {:ok, %{state | output_seq: seq}}
  end

  defp playback_frame(%{endpoint: {:host, pid}} = state, pcm, metadata) do
    case endpoint_call(fn -> Host.play(pid, pcm, metadata) end) do
      :ok -> {:ok, state}
      error -> error
    end
  end

  defp playback_frame(_, _, _), do: {:error, :audio_playback_backpressure}

  defp update_cursor(state, %{
         "item_id" => item,
         "content_index" => index,
         "response_id" => response,
         "audio_end_ms" => ms,
         "accurate" => true
       })
       when is_integer(ms) and ms >= 0 do
    key = {item, index}

    case state.playback[key] do
      %{response_id: ^response, samples: samples, cursor: cursor, order: order} = position ->
        value = max(cursor || 0, min(ms, div(samples, 24)))

        playback =
          Map.new(state.playback, fn
            {^key, _} ->
              {key, %{position | cursor: value}}

            {key, %{order: prior} = earlier} when prior < order ->
              {key, %{earlier | cursor: div(earlier.samples, 24)}}

            entry ->
              entry
          end)

        next = archive_played(%{state | playback: playback})
        if next.playback == state.playback, do: next, else: schedule_status(next)

      _ ->
        state
    end
  end

  defp update_cursor(state, _), do: state

  defp mark_generated(state, id) do
    playback =
      Map.new(state.playback, fn {key, item} ->
        {key, if(item.response_id == id, do: %{item | generated: true}, else: item)}
      end)

    archive_played(%{state | playback: playback})
  end

  defp archive_played(state) do
    Enum.reduce(state.playback, state, fn {{item_id, index} = key, item}, acc ->
      if fully_played?(item) do
        acc
        |> archive_playback(item_id, index, item, false)
        |> Map.update!(:playback, &Map.delete(&1, key))
      else
        acc
      end
    end)
  end

  defp fully_played?(item),
    do: item.generated and is_integer(item.cursor) and item.cursor >= div(item.samples, 24)

  defp archive_playback(state, item_id, index, item, interrupted) do
    record_fact(
      state,
      :voice_playback,
      state.connection_generation <> ":" <> item_id <> ":" <> Integer.to_string(index),
      Map.merge(item, %{interrupted: interrupted, endpoint_generation: state.generation})
    )
  end

  defp interrupt(state, reason) do
    # Stop the playback device before sending the upstream cancellation.
    state = flush_endpoint(state, reason in ["audio_endpoint_changed", "hangup"])

    if state.attempt do
      state = update_in(state.attempt.interrupt, &(&1 || reason))
      if state.attempt.dispatched, do: request_cancel(state), else: dispatch_response(state)
    else
      state
    end
  end

  defp request_cancel(%{attempt: %{done: done}} = state) when not is_nil(done), do: state

  defp request_cancel(%{attempt: %{id: id, cancel_sent: false}} = state) when is_binary(id) do
    case wire(state, Protocol.cancel(id)) do
      :ok -> put_in(state.attempt.cancel_sent, true)
      _ -> disconnect(state, :realtime_cancel_unconfirmed)
    end
  end

  defp request_cancel(state), do: state

  defp flush_endpoint(%{flush: flush} = state, _) when not is_nil(flush), do: state

  defp flush_endpoint(
         %{endpoint: :browser, controller: owner, playback: playback} = state,
         release
       )
       when is_pid(owner) and (release or map_size(playback) > 0) do
    token = Ecto.UUID.generate()
    send(owner, {:voice_flush, state.generation, token, release})
    Process.send_after(self(), {:flush_timeout, token}, 800)
    %{state | flush: %{token: token, after: nil}}
  end

  defp flush_endpoint(%{playback: playback} = state, _) when map_size(playback) == 0, do: state

  defp flush_endpoint(%{endpoint: {:host, pid}} = state, _) do
    state =
      case endpoint_call(fn -> Host.stop_playback(pid) end) do
        {:ok, cursor} -> update_cursor(state, cursor)
        _ -> state
      end

    finalize_flush(state)
  end

  defp flush_endpoint(state, _), do: finalize_flush(state)

  defp finalize_flush(state) do
    action = state.flush && state.flush.after

    state =
      Enum.reduce(state.playback, state, fn {{item_id, index}, item}, acc ->
        acc =
          if acc.socket && not fully_played?(item) do
            event =
              Protocol.truncate(%{
                item_id: item_id,
                content_index: index,
                audio_end_ms: item.cursor || 0
              })

            case Connection.send_event(acc.socket, event) do
              {:ok, ref} -> Map.update!(acc, :truncation_writes, &MapSet.put(&1, ref))
              _ -> %{acc | reason: :realtime_truncation_unconfirmed}
            end
          else
            acc
          end

        archive_playback(acc, item_id, index, item, not fully_played?(item))
      end)

    next = %{state | flush: nil, playback: %{}} |> schedule_status()

    case action do
      {:switch, options} -> switch_endpoint(next, options)
      _ -> next |> dispatch_response() |> close_when_settled()
    end
  end

  defp close_when_settled(%{phase: :ending, attempt: nil, flush: nil} = state) do
    if MapSet.size(state.truncation_writes) == 0,
      do: disconnect(state, state.reason),
      else: state
  end

  defp close_when_settled(state), do: state

  defp hangup(%{phase: phase} = state, _) when phase in [:offline, :error, :ending], do: state

  defp hangup(state, reason) do
    state = %{state | phase: :ending, reason: reason} |> interrupt("hangup")

    if state.socket do
      Process.send_after(self(), {:hangup_timeout, state.connection_generation}, 2_500)
      close_endpoint(state.endpoint)
      if state.controller, do: send(state.controller, {:voice_browser_close, state.generation})
      %{state | endpoint: nil} |> close_when_settled() |> publish()
    else
      disconnect(state, reason)
    end
  end

  defp disconnect(state, reason) do
    state =
      Enum.reduce(state.playback, state, fn {{id, index}, item}, acc ->
        archive_playback(acc, id, index, item, not fully_played?(item))
      end)

    state =
      case state do
        %{attempt: nil} ->
          state

        %{run_phase: :failed} ->
          finish_attempt(state, %{type: :response_failed, error: "Voice runtime failed"})

        %{attempt: attempt} when reason not in [:voice_storage_failed, :runtime_unavailable] ->
          # This attempt can no longer deliver a terminal reply. Retire it while
          # preserving the Conversation and its previously admitted work.
          finish_attempt(state, %{
            type: :response_interrupted,
            reason: attempt.interrupt || "media_unavailable"
          })

        _ ->
          finish_attempt(state, %{type: :response_failed, error: "Voice runtime unavailable"})
      end

    close_endpoint(state.endpoint)
    close_socket(state)
    if state.controller, do: send(state.controller, {:voice_browser_close, state.generation})
    if state.controller_ref, do: Process.demonitor(state.controller_ref, [:flush])
    if state.socket_ref, do: Process.demonitor(state.socket_ref, [:flush])

    next = %{
      state
      | phase: if(reason, do: :error, else: :offline),
        reason: reason,
        endpoint: nil,
        endpoint_info: nil,
        controller: nil,
        controller_ref: nil,
        socket_ref: nil,
        socket: nil,
        session_ready: false,
        playback: %{},
        flush: nil,
        inputs: :queue.new(),
        microphone: nil,
        preparing_audio: nil,
        speech_catalog: nil,
        speaking: nil,
        truncation_writes: MapSet.new(),
        capture_bytes: 0,
        connection_generation: nil,
        generation: nil
    }

    if next.device_call, do: schedule_reconnect(next, reason), else: publish(next)
  end

  defp associate_generation(%{message: %{content: blocks}} = terminal, generation)
       when is_list(blocks) do
    put_in(
      terminal.message.content,
      Enum.map(blocks, fn
        %{type: :spoken_audio} = block -> Map.put(block, :connection_generation, generation)
        block -> block
      end)
    )
  end

  defp associate_generation(terminal, _), do: terminal

  defp finish_attempt(%{attempt: attempt} = state, terminal) do
    {terminal, reply} =
      case terminal do
        %{type: :response_completed, message: %{content: [_ | _]}} ->
          {put_in(terminal.message[:id], attempt.chat_id), state.chat_reply}

        _ ->
          {terminal, nil}
      end

    emit(attempt, terminal)
    if attempt.monitor, do: Process.demonitor(attempt.monitor, [:flush])
    %{state | attempt: nil, preparing_audio: nil, chat_reply: reply}
  end

  defp emit(%{owner: nil}, _event), do: :ok
  defp emit(attempt, event), do: send(attempt.owner, {:voice_response, attempt.ref, event})

  defp wire(%{socket: nil}, _), do: {:error, :voice_offline}

  defp wire(state, event) do
    case Connection.send_event(state.socket, event) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp close_socket(%{socket: nil}), do: :ok
  defp close_socket(state), do: Connection.close(state.socket)

  defp endpoint_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :audio_endpoint_unavailable}
  end

  defp close_endpoint({:host, pid}), do: endpoint_call(fn -> Host.close(pid) end)
  defp close_endpoint(_), do: :ok

  defp mute_endpoint({:host, pid}, value) do
    case endpoint_call(fn -> Host.mute(pid, value) end) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp mute_endpoint(_, _), do: :ok

  defp checkpoint(state, messages) do
    %{state | canonical: messages}
    |> append_chat(messages)
    |> archive_chat()
    |> publish_chat()
  end

  defp append_chat(state, canonical) do
    messages = History.project(state.session.id, canonical, state.image_payloads, state.chat_ids)
    ids = Enum.reduce(messages, state.chat_ids, &MapSet.put(&2, &1.id))

    reply =
      case state.chat_reply do
        %{id: id} = reply -> if MapSet.member?(ids, id), do: nil, else: reply
        nil -> nil
      end

    %{
      state
      | chat_messages: state.chat_messages ++ messages,
        chat_ids: ids,
        chat_reply: reply,
        unarchived: state.unarchived ++ messages
    }
  end

  defp archive_chat(%{unarchived: []} = state), do: state

  defp archive_chat(state) do
    if :queue.len(state.projection_queue) < 128,
      do: project_later(%{state | unarchived: []}, {:history, state.unarchived}),
      else: state
  end

  defp record_fact(state, type, key, data) do
    state
    |> put_in([:confirmed, type, key], data)
    |> project_later({:fact, type, key, data})
    |> publish_chat()
  end

  defp project_later(state, operation) do
    if :queue.len(state.projection_queue) < 128 do
      %{state | projection_queue: :queue.in(operation, state.projection_queue)} |> project()
    else
      publish(%{state | reason: :voice_projection_queue_full})
    end
  end

  defp project(%{projection: nil} = state) do
    case :queue.out(state.projection_queue) do
      {{:value, operation}, queue} ->
        id = state.session.id

        task =
          Task.Supervisor.async_nolink(Synapsis.Tool.TaskSupervisor, fn ->
            case operation do
              {:history, messages} ->
                History.append_messages(id, messages)

              {:fact, type, key, data} ->
                History.save_fact(id, type, key, data)

              {:child_result, namespace, run_id} ->
                {:child_result, run_id, History.final_result(namespace, run_id)}
            end
          end)

        %{state | projection: task, projection_queue: queue}

      {:empty, _} ->
        state
    end
  end

  defp project(state), do: state

  defp public(state) do
    %{
      session_id: state.session.id,
      phase: state.phase,
      reason: state.reason,
      endpoint: state.options,
      endpoint_info: state.endpoint_info,
      generation: state.generation,
      manual: state.context && state.context.agent.voice_turn_detection == "manual",
      device_call: state.device_call != nil,
      muted: state.muted,
      playback: playback_status(state.playback),
      host: to_string(:net_adm.localhost()),
      tasks:
        Enum.map(state.roster.agents, fn agent ->
          agent
          |> Map.take([:agent_id, :run_id, :name, :status, :result_delivery, :cleanup])
          |> Map.put(:final, state.child_results[agent.run_id])
        end)
    }
  end

  defp playback_status(playback) when map_size(playback) == 0, do: nil

  defp playback_status(playback) do
    {_key, position} = Enum.min_by(playback, fn {_key, item} -> item.order end)
    %{played_ms: position.cursor}
  end

  defp schedule_status(%{status_timer: true} = state), do: state

  defp schedule_status(state) do
    Process.send_after(self(), :publish_voice_status, 120)
    %{state | status_timer: true}
  end

  defp publish(state) do
    Phoenix.PubSub.broadcast(
      Synapsis.PubSub,
      topic(state.session.id),
      {:voice_status, state.controller, public(state)}
    )

    publish_chat(state)
  end

  defp chat_view(state) do
    %{
      phase: state.phase,
      busy: state.run_phase == :busy,
      queued: :queue.len(state.inputs),
      messages: state.chat_messages,
      facts: state.confirmed,
      reply: state.chat_reply
    }
  end

  defp current_chat_snapshot(state),
    do: state.chat_snapshot || Map.put(chat_view(state), :revision, 0)

  defp publish_chat(state) do
    view = chat_view(state)

    if Map.delete(state.chat_snapshot || %{}, :revision) == view do
      state
    else
      snapshot = Map.put(view, :revision, System.unique_integer([:positive, :monotonic]))
      id = state.session.id
      Phoenix.PubSub.broadcast(Synapsis.PubSub, chat_topic(id), {:voice_chat, id, snapshot})
      %{state | chat_snapshot: snapshot}
    end
  end
end
