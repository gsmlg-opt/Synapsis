defmodule Synapsis.MessagePartTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.MessagePart

  test "changeset accepts a valid text part row" do
    changeset =
      MessagePart.changeset(%MessagePart{}, %{
        session_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        ordinal: 0,
        type: "text",
        data: %{"content" => "hello"}
      })

    assert changeset.valid?
  end

  test "changeset rejects unknown part type" do
    changeset =
      MessagePart.changeset(%MessagePart{}, %{
        session_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        ordinal: 0,
        type: "unknown",
        data: %{}
      })

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:type]
  end
end
