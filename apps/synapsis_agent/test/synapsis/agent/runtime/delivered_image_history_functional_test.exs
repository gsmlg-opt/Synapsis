defmodule Synapsis.Agent.Runtime.DeliveredImageHistoryFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.TestSupport.ResponsesFixture
  @moduletag :functional

  alias Synapsis.Agent.Runtime.{ProviderAdapter, ProviderMessages}
  alias Synapsis.Session.{Snapshot, Store}
  alias Synapsis.{Message, Part}

  test "durable assistant image remains rich while ordinary runtime history uses bounded text" do
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(id) end)
    image = delivered_image()

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: id,
      role: "assistant",
      parts: [image]
    }

    encoded = Snapshot.encode_message(message)

    assert [
             %{
               type: "delivered_image",
               descriptor: descriptor,
               delivery: delivery,
               name: "Result 🙂.png"
             }
           ] =
             encoded.parts

    assert descriptor == image.descriptor
    assert delivery == image.delivery
    assert :ok = Store.commit_turn(id, 0, encoded, %{status: "idle"})
    assert {:ok, %{turns: [^encoded]}} = Snapshot.rehydrate(id)
    assert [%Message{parts: [^image]} = loaded] = Message.list_by_session(id)

    assert {:ok, [%{role: :assistant, content: [%{type: :text, text: text}]}] = runtime} =
             ProviderMessages.from_host([loaded])

    assert text == Part.DeliveredImage.summary(image)
    assert byte_size(text) <= 2048
    assert text =~ "synapsis-media://image/"

    assert {:ok, [%{role: :assistant, parts: [%Part.Text{content: ^text}]}]} =
             ProviderMessages.to_host(runtime)

    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    observer = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(observer, {:delivered_image_wire, Jason.decode!(body)})

      ResponsesFixture.send_sse(conn, [
        ResponsesFixture.text_delta("Observed image"),
        ResponsesFixture.completed()
      ])
    end)

    request = %{
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      turn_id: "t",
      step_id: "s",
      attempt_id: "a",
      catalog_revision: 1,
      tools: [],
      messages: runtime
    }

    context = %{
      provider_config: %{
        type: "openai",
        api_key: "fixture",
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      },
      request_options: %{model: "fixture"},
      stream_timeout: 2_000
    }

    events = request |> ProviderAdapter.stream(context) |> Enum.to_list()
    assert_receive {:delivered_image_wire, wire}, 2_000

    assert [
             %{"role" => "assistant", "content" => [%{"type" => "output_text", "text" => ^text}]}
           ] = wire["input"]

    assert List.last(events) == %{
             type: :response_completed,
             message: %{role: :assistant, content: [%{type: :text, text: "Observed image"}]}
           }

    # Projection never rewrites the durable rich history.
    assert [%Message{parts: [^image]}] = Message.list_by_session(id)
  end

  defp delivered_image do
    struct(Part.DeliveredImage,
      name: "Result 🙂.png",
      descriptor: %{
        "uri" => "synapsis-media://image/" <> String.duplicate("a", 64) <> ".png",
        "sha256" => String.duplicate("a", 64),
        "byte_size" => 1234,
        "format" => "png",
        "mime_type" => "image/png"
      },
      delivery: %{
        "version" => 1,
        "session_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate()
      }
    )
  end
end
