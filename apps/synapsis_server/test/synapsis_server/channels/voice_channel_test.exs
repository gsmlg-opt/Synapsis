defmodule SynapsisServer.VoiceChannelTest do
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  alias Synapsis.{AgentConfigs, Sessions}
  alias SynapsisServer.{UserSocket, VoiceChannel}

  @endpoint SynapsisServer.Endpoint

  test "the binary media channel requires a token for the exact saved voice session" do
    suffix = System.unique_integer([:positive])

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "voice-channel-#{suffix}",
        kind: :voice,
        provider: "backplane",
        voice_model: "openai/gpt-realtime",
        tools: [],
        tool_contract_version: 1
      })

    {:ok, session} = Sessions.create(agent.name)

    on_exit(fn ->
      Sessions.delete(session.id)
      AgentConfigs.delete(agent)
    end)

    assert {:ok, socket} = connect(UserSocket, %{})

    assert {:error, %{reason: "voice_session_unavailable"}} =
             subscribe_and_join(socket, "voice:#{session.id}", %{"token" => "forged"})

    assert {:error, %{reason: "voice_session_unavailable"}} =
             subscribe_and_join(socket, "voice:#{session.id}", %{
               "token" => VoiceChannel.token("different-session")
             })

    assert {:ok, %{phase: :offline}, channel} =
             subscribe_and_join(socket, "voice:#{session.id}", %{
               "token" => VoiceChannel.token(session.id)
             })

    generation = Ecto.UUID.generate()
    ref = push(channel, "pcm", {:binary, <<generation::binary, 1::32, 0::16>>})
    assert_reply ref, :error, %{reason: :voice_offline}
    ref = push(channel, "pcm", {:binary, <<generation::binary, 1::32, 0::16_000>>})
    assert_reply ref, :error, %{reason: :invalid_voice_operation}
  end
end
