defmodule Synapsis.Session.NativePdfProjectionTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Part.{ToolResult, ToolUse}
  alias Synapsis.Provider.Adapter
  alias Synapsis.{Message, Part, Session.Store}

  @pdf_url "https://example.test/reports/annual.pdf"
  @link_url "https://example.test/reports/quarterly.pdf"
  @link_name "Quarterly report.pdf"

  for is_error <- [false, true] do
    @is_error is_error

    test "canonical PDF results with is_error=#{is_error} survive reload and Anthropic HTTP" do
      is_error = @is_error
      call_id = "pdf-call-#{is_error}"

      content = [
        text("before PDFs"),
        %{
          "type" => "resource",
          "data" => %{"uri" => @pdf_url, "mime_type" => "application/pdf"},
          "extensions" => %{}
        },
        %{
          "type" => "resource_link",
          "data" => %{
            "uri" => @link_url,
            "mime_type" => "application/pdf",
            "name" => @link_name
          },
          "extensions" => %{}
        },
        text("after PDFs")
      ]

      runtime = [
        %{
          role: :assistant,
          content: [
            %{type: :tool_call, id: call_id, name: "pdf_fixture", arguments: %{}}
          ]
        },
        %{role: :tool, tool_call_id: call_id, result: %{content: content, is_error: is_error}}
      ]

      assert {:ok,
              [
                %{role: :assistant, parts: [call]},
                %{role: :tool, parts: [%ToolResult{} = part]}
              ] = host} = ProviderMessages.to_host(runtime)

      assert call == %ToolUse{tool_use_id: call_id, tool: "pdf_fixture", input: %{}}
      assert part.tool_use_id == call.tool_use_id
      assert part.is_error === is_error
      assert part.content == "before PDFs\nafter PDFs"

      assert part.projection === %{
               "version" => 1,
               "result" => %{"content" => content, "is_error" => is_error}
             }

      assert {:ok, dumped} = Part.dump(part)
      assert {:ok, ^part} = dumped |> Jason.encode!() |> Jason.decode!() |> Part.load()

      reloaded = persist_and_reload(host)

      assert [
               %Message{role: "assistant", parts: [^call]},
               %Message{role: "tool", parts: [^part]}
             ] = reloaded

      assert {:ok, replay} = ProviderMessages.from_host(reloaded)
      assert replay === runtime
      assert {:ok, replay_host} = ProviderMessages.to_host(replay)
      assert replay_host === host

      assert {:ok, request} =
               Adapter.format_request(reloaded, [], %{provider_type: :anthropic, model: "fixture"})

      expected_messages = [
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => call_id,
              "name" => "pdf_fixture",
              "input" => %{}
            }
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => call_id,
              "is_error" => is_error,
              "content" => [
                text("before PDFs"),
                %{"type" => "document", "source" => %{"type" => "url", "url" => @pdf_url}},
                %{
                  "type" => "document",
                  "source" => %{"type" => "url", "url" => @link_url},
                  "title" => @link_name
                },
                text("after PDFs")
              ]
            }
          ]
        }
      ]

      assert request["messages"] === expected_messages

      fixture = Gaoxy.Test.open()
      owner = self()

      Gaoxy.Test.expect_once(fixture, "POST", "/v1/messages", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(owner, {:pdf_request, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "stop_reason" => "end_turn",
            "content" => [%{"type" => "text", "text" => "PDFs received"}]
          })
        )
      end)

      config = %{
        type: "anthropic",
        api_key: "fixture",
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/")
      }

      assert {:ok, "PDFs received"} = Adapter.complete(request, config)
      assert_receive {:pdf_request, wire}, 1_000
      assert wire["messages"] === expected_messages
    end
  end

  defp persist_and_reload(host) do
    Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)

    Enum.with_index(host, fn message, index ->
      stored = %Message{
        id: Ecto.UUID.generate(),
        session_id: session_id,
        role: Atom.to_string(message.role),
        parts: message.parts,
        inserted_at: DateTime.utc_now()
      }

      assert :ok = Store.commit_turn(session_id, index, Message.encode(stored), %{})
    end)

    Message.list_by_session(session_id)
  end

  defp text(value), do: %{"type" => "text", "text" => value}
end
