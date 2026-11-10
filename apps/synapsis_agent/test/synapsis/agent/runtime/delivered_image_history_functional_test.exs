defmodule Synapsis.Agent.Runtime.DeliveredImageHistoryFunctionalTest do
  use ExUnit.Case, async: false
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

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(observer, {:delivered_image_wire, Jason.decode!(body)})

      chunks = [
        %{
          "id" => "image-history",
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "Observed image"}, "finish_reason" => nil}
          ]
        },
        %{
          "id" => "image-history",
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
        }
      ]

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.resp(
        200,
        Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <>
          "data: [DONE]\n\n"
      )
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

    assert wire["messages"] == [
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
           ]

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
