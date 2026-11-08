defmodule Synapsis.SessionCoupledPublicationFunctionalTest do
  use ExUnit.Case, async: false

  alias Concord.{KV, Turso}
  alias Concord.KV.Record
  alias Synapsis.{Message, Session}
  alias Synapsis.Session.{Fork, Sharing, Store}

  @timeout 5_000

  setup do
    assert :ok = Store.ensure_started()
    :ok
  end

  for count <- [0, 500] do
    @count count
    test "fork publishes metadata and #{@count} copied turns at one destination revision" do
      count = @count
      source = source_session()
      register_cleanup(source.id)
      assert :ok = Store.put_meta(source.id, Session.to_meta(source))
      messages = source_messages(source.id, count)
      assert :ok = Message.persist_list(source.id, messages)
      before = revision()

      assert {:ok, destination} = Fork.fork(source.id)
      register_cleanup(destination.id)
      assert destination.id != source.id
      assert destination.title == "Fork of source 雪"
      assert destination.provider == source.provider
      assert destination.model == source.model
      assert destination.agent == source.agent
      assert destination.config == source.config
      assert destination.status == "idle"
      assert %DateTime{} = destination.inserted_at
      assert destination.updated_at == destination.inserted_at
      expected = copied_turns(messages)
      assert_destination(destination, expected, before)
      assert Message.list_by_session(source.id) == messages
    end
  end

  test "fork at_message includes the target and preserves the existing copy field selection" do
    source = source_session()
    register_cleanup(source.id)
    assert :ok = Store.put_meta(source.id, Session.to_meta(source))
    messages = source_messages(source.id, 3)
    assert :ok = Message.persist_list(source.id, messages)
    target = Enum.at(messages, 1)
    before = revision()

    assert {:ok, destination} = Fork.fork(source.id, at_message: target.id)
    register_cleanup(destination.id)
    assert_destination(destination, copied_turns(Enum.take(messages, 2)), before)
    assert length(Message.list_by_session(destination.id)) == 2
    assert Message.list_by_session(source.id) == messages
  end

  for count <- [0, 500] do
    @count count
    test "import publishes metadata and #{@count} converted turns with agent override in one revision" do
      count = @count

      incoming =
        Enum.map(indices(count), fn n ->
          %{
            "role" => if(rem(n, 2) == 0, do: "user", else: "assistant"),
            "token_count" => n + 1,
            "parts" => [
              %{"type" => "text", "content" => "import #{n} 雪"},
              %{"type" => "reasoning", "content" => "reason #{n}", "signature" => "sig-#{n}"},
              %{"type" => "file", "path" => "ordinary/#{n}.txt", "content" => "file #{n}"}
            ]
          }
        end)

      json =
        Jason.encode!(%{
          "session" => %{
            "title" => "shared 雪",
            "agent" => "export-agent",
            "provider" => "ordinary-provider",
            "model" => "ordinary-model"
          },
          "messages" => incoming
        })

      before = revision()

      assert {:ok, destination} = Sharing.import_session(json, "chosen-agent")
      register_cleanup(destination.id)
      assert destination.title == "[Imported] shared 雪"
      assert destination.agent == "chosen-agent"
      assert destination.provider == "ordinary-provider"
      assert destination.model == "ordinary-model"
      assert destination.config == %{}
      assert destination.status == "idle"
      assert %DateTime{} = destination.inserted_at
      assert destination.updated_at == destination.inserted_at

      expected =
        Enum.map(indices(count), fn n ->
          %{
            id: nil,
            role: if(rem(n, 2) == 0, do: "user", else: "assistant"),
            token_count: n + 1,
            inserted_at: nil,
            parts: [
              %{type: "text", text: "import #{n} 雪"},
              %{
                type: "reasoning",
                content: "reason #{n}",
                signature: "sig-#{n}",
                provider_states: []
              },
              %{type: "file", path: "ordinary/#{n}.txt", content: "file #{n}"}
            ]
          }
        end)

      assert_destination(destination, expected, before)
    end
  end

  test "import retains ordinary title agent and message defaults" do
    json =
      Jason.encode!(%{
        "session" => %{"provider" => "ordinary-provider", "model" => "ordinary-model"},
        "messages" => [%{}, %{"parts" => [%{"type" => "legacy"}]}]
      })

    before = revision()

    assert {:ok, destination} = Sharing.import_session(json)
    register_cleanup(destination.id)
    assert destination.title == "[Imported] session"
    assert destination.agent == "main"

    expected = [
      %{id: nil, role: "user", token_count: 0, inserted_at: nil, parts: []},
      %{
        id: nil,
        role: "user",
        token_count: 0,
        inserted_at: nil,
        parts: [%{type: "text", text: "[imported content]"}]
      }
    ]

    assert_destination(destination, expected, before)
  end

  defp source_session do
    %Session{
      id: Ecto.UUID.generate(),
      title: "source 雪",
      provider: "ordinary-provider",
      model: "ordinary-model",
      agent: "source-agent",
      status: "idle",
      config: %{"nested" => %{"chosen" => true}},
      debug: true,
      inserted_at: ~U[2026-11-06 00:00:00.000000Z],
      updated_at: ~U[2026-11-06 00:00:00.000000Z]
    }
  end

  defp source_messages(id, count) do
    Enum.map(indices(count), fn n ->
      %Message{
        id: Ecto.UUID.generate(),
        session_id: id,
        role: if(rem(n, 2) == 0, do: "user", else: "assistant"),
        token_count: n + 2,
        inserted_at: ~U[2026-11-06 00:00:00.000000Z],
        input_provenance: %{"source" => "source-only"},
        internal_turn_source: "source-only",
        reply_presentation: %{"phase" => "final"},
        parts: [%Synapsis.Part.Text{content: "source #{n} 雪"}]
      }
    end)
  end

  defp copied_turns(messages) do
    Enum.map(messages, fn message ->
      [%Synapsis.Part.Text{content: text}] = message.parts

      %{
        id: nil,
        inserted_at: nil,
        role: message.role,
        token_count: message.token_count,
        parts: [%{type: "text", text: text}]
      }
    end)
  end

  defp assert_destination(session, expected_turns, before) do
    published = revision()
    assert published == before + 1

    expected_meta = %{
      id: session.id,
      title: session.title,
      provider: session.provider,
      model: session.model,
      agent: session.agent,
      config: session.config,
      status: "idle",
      debug: false,
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }

    assert {:ok, ^expected_meta} = Store.get_meta(session.id)
    assert {:ok, ^expected_turns} = Store.list_turns(session.id)
    meta_key = Store.meta_key(session.id)

    assert {:ok,
            [
              %Record{
                value: ^expected_meta,
                create_revision: ^published,
                mod_revision: ^published,
                version: 1
              }
            ],
            %{has_more: false}} =
             KV.list(
               engine: :turso,
               range: {meta_key, meta_key <> <<0>>},
               limit: 1,
               revision: published,
               timeout: @timeout
             )

    assert {:ok, [], %{has_more: false}} =
             KV.list(
               engine: :turso,
               prefix: "sessions/" <> session.id <> "/",
               revision: before,
               limit: 500,
               timeout: @timeout
             )

    assert {:ok, records, %{has_more: false}} =
             KV.list(
               engine: :turso,
               prefix: Store.turns_prefix(session.id),
               revision: published,
               limit: 500,
               timeout: @timeout
             )

    expected_pairs =
      expected_turns
      |> Enum.with_index()
      |> Enum.map(fn {turn, n} -> {Store.turn_key(session.id, n), turn} end)

    assert Enum.map(records, &{&1.key, &1.value}) == expected_pairs

    assert Enum.all?(records, fn row ->
             row.create_revision == published and row.mod_revision == published and
               row.version == 1
           end)
  end

  defp revision do
    assert {:ok, revision} = Turso.revision(timeout: @timeout)
    revision
  end

  defp indices(0), do: []
  defp indices(count), do: 0..(count - 1)

  defp register_cleanup(id), do: on_exit(fn -> assert :ok = Store.delete_session(id) end)
end
