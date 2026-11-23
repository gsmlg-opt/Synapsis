defmodule SynapsisServer.VoiceChannel do
  @moduledoc "Session-bound control and binary PCM transport for voice media."
  use Phoenix.Channel

  alias Synapsis.{Sessions, VoiceSession}

  @token_salt "voice-media"
  @max_token_age 3_600

  def token(session_id), do: Phoenix.Token.sign(SynapsisServer.Endpoint, @token_salt, session_id)

  @impl true
  def join("voice:" <> id, %{"token" => token}, socket) when is_binary(token) do
    with {:ok, ^id} <-
           Phoenix.Token.verify(SynapsisServer.Endpoint, @token_salt, token,
             max_age: @max_token_age
           ),
         {:ok, session} <- Sessions.get(id),
         true <- Sessions.voice?(session),
         {:ok, status} <- VoiceSession.status(id) do
      :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, VoiceSession.topic(id))
      {:ok, status, assign(socket, :voice_session, id)}
    else
      _ -> {:error, %{reason: "voice_session_unavailable"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "voice_session_unavailable"}}

  @impl true
  def handle_in("start", params, socket),
    do: voice_reply(VoiceSession.start(id(socket), endpoint_options(params)), socket)

  def handle_in("switch", params, socket),
    do: voice_reply(VoiceSession.switch(id(socket), endpoint_options(params)), socket)

  def handle_in("stop", _, socket), do: voice_reply(VoiceSession.stop(id(socket)), socket)

  def handle_in("stop_playback", _, socket),
    do: voice_reply(VoiceSession.stop_playback(id(socket)), socket)

  def handle_in("mute", %{"muted" => value}, socket) when is_boolean(value),
    do: voice_reply(VoiceSession.mute(id(socket), value), socket)

  def handle_in("commit_audio", _, socket),
    do: voice_reply(VoiceSession.commit(id(socket)), socket)

  def handle_in("host_devices", _, socket), do: voice_reply(VoiceSession.devices(:host), socket)

  def handle_in("cancel_task", %{"agent_id" => agent, "run_id" => run}, socket)
      when is_binary(agent) and byte_size(agent) <= 128 and is_binary(run) and
             byte_size(run) <= 128,
      do: voice_reply(VoiceSession.cancel_task(id(socket), agent, run), socket)

  def handle_in("browser_ready", %{"generation" => generation, "info" => info}, socket)
      when is_binary(generation) and is_map(info) do
    if byte_size(:erlang.term_to_binary(info)) <= 4_096 do
      voice_reply(VoiceSession.browser_ready(id(socket), generation, info), socket)
    else
      voice_reply({:error, :invalid_device_information}, socket)
    end
  end

  def handle_in("pcm", {:binary, <<generation::binary-size(36), seq::32, pcm::binary>>}, socket)
      when byte_size(pcm) in 2..1_920,
      do: voice_reply(VoiceSession.capture(id(socket), generation, seq, pcm), socket)

  def handle_in("playback_ack", %{"generation" => generation, "seq" => seq}, socket) do
    VoiceSession.playback_ack(id(socket), generation, seq)
    {:noreply, socket}
  end

  def handle_in("cursor", %{"generation" => generation, "position" => position}, socket) do
    VoiceSession.cursor(id(socket), generation, position)
    {:noreply, socket}
  end

  def handle_in(
        "flushed",
        %{"generation" => generation, "token" => token, "position" => position},
        socket
      ) do
    VoiceSession.flushed(id(socket), generation, token, position)
    {:noreply, socket}
  end

  def handle_in("browser_error", %{"generation" => generation, "reason" => reason}, socket) do
    VoiceSession.browser_error(id(socket), generation, reason)
    {:noreply, socket}
  end

  def handle_in(_, _, socket), do: voice_reply({:error, :invalid_voice_operation}, socket)

  @impl true
  def handle_info({:voice_status, status}, socket) do
    push(socket, "status", status)
    {:noreply, socket}
  end

  def handle_info({:voice_browser_open, generation, options}, socket) do
    push(socket, "browser_open", Map.put(options, :generation, generation))
    {:noreply, socket}
  end

  def handle_info({:voice_browser_close, generation}, socket) do
    push(socket, "browser_close", %{generation: generation})
    {:noreply, socket}
  end

  def handle_info({:voice_flush, generation, token, release}, socket) do
    push(socket, "flush", %{generation: generation, token: token, release: release})
    {:noreply, socket}
  end

  def handle_info({:voice_transcript, item, transcript}, socket) do
    push(socket, "transcript", %{item_id: item, transcript: transcript})
    {:noreply, socket}
  end

  def handle_info({:voice_pcm, generation, seq, metadata, pcm}, socket) do
    header = JSON.encode!(Map.merge(metadata, %{generation: generation, seq: seq}))
    push(socket, "pcm", {:binary, <<byte_size(header)::16, header::binary, pcm::binary>>})
    {:noreply, socket}
  end

  defp endpoint_options(params) when is_map(params) do
    for {key, atom} <- [
          {"mode", :mode},
          {"input_device", :input_device},
          {"output_device", :output_device}
        ],
        Map.has_key?(params, key),
        do: {atom, if(params[key] == "", do: nil, else: params[key])}
  end

  defp endpoint_options(_), do: []

  defp id(socket), do: socket.assigns.voice_session

  defp voice_reply(:ok, socket), do: {:reply, :ok, socket}
  defp voice_reply({:ok, info}, socket), do: {:reply, {:ok, info}, socket}

  defp voice_reply({:error, reason}, socket) when is_atom(reason) or is_binary(reason),
    do: {:reply, {:error, %{reason: reason}}, socket}

  defp voice_reply(_, socket), do: {:reply, {:error, %{reason: "voice_unavailable"}}, socket}
end
