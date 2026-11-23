defmodule Synapsis.Voice.AudioEndpointTest do
  use ExUnit.Case, async: true

  alias Synapsis.Voice.AudioEndpoint.Host

  test "rejects invalid PCM before opening any device" do
    assert {:error, :invalid_audio} = Host.validate_audio(<<0>>, %{})
    assert {:error, :invalid_audio} = Host.validate_audio(:invalid, %{})
    assert {:error, :invalid_audio} = Host.validate_audio(:binary.copy(<<0>>, 96_002), %{})
  end

  test "playback requires response and item identity" do
    assert {:error, :invalid_audio} = Host.validate_audio(<<0, 0>>, %{})

    assert :ok =
             Host.validate_audio(<<0, 0>>, %{
               response_id: "response",
               item_id: "item",
               content_index: 0
             })
  end
end
