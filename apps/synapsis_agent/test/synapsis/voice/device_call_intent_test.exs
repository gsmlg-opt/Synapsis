defmodule Synapsis.Voice.DeviceCallIntentTest do
  use ExUnit.Case, async: false

  alias Synapsis.Session.Store
  alias Synapsis.Voice.DeviceCallIntent

  setup do
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(id) end)
    %{id: id}
  end

  test "connection intent retains explicit devices and microphone state until user stop", %{
    id: id
  } do
    assert :not_found = DeviceCallIntent.load(id)
    options = [mode: "host", input_device: "virtual-microphone", output_device: nil]

    assert {:ok, active} = DeviceCallIntent.save(id, true, true, options)
    assert active == %{active: true, muted: true, options: Keyword.delete(options, :mode)}
    assert {:ok, ^active} = DeviceCallIntent.load(id)

    assert {:ok, stopped} = DeviceCallIntent.save(id, false, true, active.options)
    assert stopped.active == false
    assert {:ok, ^stopped} = DeviceCallIntent.load(id)
  end

  test "malformed persisted intent is reported instead of activating devices", %{id: id} do
    assert :ok =
             Store.put_value(id, "device_voice_call", %{
               active: true,
               muted: true,
               options: [mode: "browser"]
             })

    assert {:error, :invalid_device_call_intent} = DeviceCallIntent.load(id)
    assert {:ok, %{active: false}} = DeviceCallIntent.save(id, false, true, [])
  end

  test "intent only stores host device overrides", %{id: id} do
    assert {:error, :invalid_device_call_intent} =
             DeviceCallIntent.save(id, true, false, api_key: "invalid-option")

    assert {:error, :invalid_device_call_intent} =
             DeviceCallIntent.save(id, true, false, input_device: "a", input_device: "b")

    assert :not_found = DeviceCallIntent.load(id)
  end
end
