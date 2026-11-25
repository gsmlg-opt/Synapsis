defmodule SynapsisWeb.AgentLive.VoiceAgentsTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{AgentConfigs, Config.Store}
  alias Synapsis.Provider.Registry
  alias Synapsis.Voice.History

  test "voice setup shows required fields first and validates them before save", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")
    react_form_change(view, "agent-config-form", %{"agent" => %{"kind" => "voice"}})

    assert has_element?(view, "[data-form-id='agent-config-form'][phx-change='validate']")
    assert has_element?(view, "[data-voice-required] input[name='agent[name]'][required]")

    assert has_element?(
             view,
             "[data-voice-required] select[name='agent[voice_provider]'][aria-required='true']"
           )

    assert has_element?(view, "[data-voice-required] input[name='agent[voice_model]'][required]")
    refute has_element?(view, "[data-voice-required] [name='agent[description]']")
    assert field_errors(view) == %{}

    react_form_change(view, "agent-config-form", %{
      "agent" => %{"name" => "Bad Name", "voice_model" => "gpt-realtime"}
    })

    assert field_errors(view)["agent-voice-name"] =~ "lowercase"
    assert field_errors(view)["agent-voice-model"] =~ "qualified Realtime provider/model"
    refute Map.has_key?(field_errors(view), "agent-voice-provider")

    react_form_change(view, "agent-config-form", %{
      "agent" => %{"name" => "voice-validate", "voice_model" => "openai/gpt-realtime"}
    })

    assert field_errors(view) == %{}
    assert AgentConfigs.get_by_name("voice-validate") == nil

    react_form_change(view, "agent-config-form", %{"agent" => %{"voice_model" => ""}})
    assert field_errors(view)["agent-voice-model"] == "Enter a Realtime model."
  end

  test "new and edit forms persist voice settings through the existing Agent editor", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")
    assert has_element?(view, "select[name='agent[kind]']")
    assert has_element?(view, "[data-agent-editor='standard'] #agent-provider-model-picker")
    refute has_element?(view, "[data-voice-settings]")

    react_form_change(view, "agent-config-form", %{
      "agent" => %{
        "kind" => "voice",
        "name" => "voice-helper",
        "label" => "Voice helper",
        "voice_provider" => "backplane",
        "voice_model" => "openai/gpt-realtime"
      }
    })

    assert has_element?(view, "[data-agent-editor='voice'] h2", "New Voice Agent")
    assert has_element?(view, "[data-voice-settings] h4", "Realtime conversation")
    refute has_element?(view, "[data-voice-settings] [name='agent[audio_mode]']")
    assert has_element?(view, "select[name='agent[voice_provider]']")
    assert has_element?(view, "select[name='agent[audio_mode]']")
    refute has_element?(view, "#agent-provider-model-picker")
    refute has_element?(view, "#agent-backup-model-picker")
    refute has_element?(view, "select[name='agent[reasoning_effort]']")
    refute has_element?(view, "button[phx-value-tab='runtime']")

    view |> element("button[phx-value-tab='audio']", "Audio") |> render_click()

    for {mode, max} <- [{"host", 150}, {"browser", 200}] do
      profile = "[data-voice-audio-settings]:not(.hidden) [data-voice-audio-profile='#{mode}']"

      assert has_element?(
               view,
               "#{profile} select[name='agent[#{mode}_audio_input_device]'] option[value='']",
               "System default"
             )

      assert has_element?(
               view,
               "#{profile} input[type='range'][max='#{max}'][data-voice-volume-range]"
             )

      assert has_element?(view, "#{profile} [data-voice-test='microphone']", "Test microphone")
      assert has_element?(view, "#{profile} [data-voice-test='speaker']", "Test speaker")
      assert has_element?(view, "#{profile} progress[data-voice-test-meter]")
      assert has_element?(view, "#{profile} [role='status'] [data-voice-test-status]")
    end

    view |> element("button[phx-value-tab='tools']", "Tools & delegation") |> render_click()
    assert has_element?(view, "section:not(.hidden) select[name='agent[voice_delegate]']")

    react_form_submit(view, "agent-config-form", %{
      "agent" => %{
        "audio_mode" => "host",
        "host_audio_input_device" => "host-mic",
        "host_audio_input_volume" => "80",
        "host_audio_output_volume" => "65",
        "browser_audio_input_device" => "web-mic",
        "browser_audio_output_volume" => "185",
        "voice" => "cedar",
        "voice_delegate" => "main"
      }
    })

    agent = AgentConfigs.get_by_name("voice-helper")
    assert agent.kind == :voice
    assert agent.provider == "backplane"
    assert agent.voice_model == "openai/gpt-realtime"
    assert agent.audio_mode == "host"
    assert {agent.host_audio_input_volume, agent.host_audio_output_volume} == {80, 65}
    assert agent.host_audio_input_device == "host-mic"
    assert agent.browser_audio_input_device == "web-mic"
    assert agent.browser_audio_output_volume == 185
    assert agent.voice == "cedar"
    assert agent.voice_delegate == "main"

    assert :ok = Store.reload(:agent)
    {:ok, edit, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    assert html =~ "Voice Agent"
    assert has_element?(edit, "[data-agent-editor='voice'] [data-voice-settings]:not(.hidden)")
    refute has_element?(edit, "#agent-provider-model-picker")
    react_form_submit(edit, "agent-config-form", %{"agent" => %{"audio_mode" => "browser"}})
    updated = AgentConfigs.get(agent.id)
    assert updated.audio_mode == "browser"
    assert updated.host_audio_input_device == "host-mic"
    assert updated.browser_audio_input_device == "web-mic"
  end

  test "a failed Realtime catalog still allows saving a known model and explains invalid inputs",
       %{conn: conn} do
    provider = "unavailable-realtime-catalog"
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.expect_once(
      fixture,
      "GET",
      "/v1/realtime/models",
      &Plug.Conn.send_resp(&1, 500, "")
    )

    :ok =
      Registry.register(provider, %{type: "openai_responses", base_url: Gaoxy.Test.url(fixture)})

    on_exit(fn -> Registry.unregister(provider) end)

    {:ok, view, _} = live(conn, ~p"/agent/agents/new")
    react_form_change(view, "agent-config-form", %{"agent" => %{"kind" => "voice"}})

    assert react_form_submit(view, "agent-config-form", %{"agent" => %{"name" => "Voice Test"}}) =~
             "Name must start with a letter or digit"

    assert react_form_submit(view, "agent-config-form", %{"agent" => %{"name" => "voice-test"}}) =~
             "Select a Backplane connection."

    react_form_change(view, "agent-config-form", %{"agent" => %{"voice_provider" => provider}})
    view |> element("[phx-click='refresh_realtime_models']") |> render_click()

    assert render_async(view) =~ "Backplane returned HTTP 500"

    assert react_form_submit(view, "agent-config-form", %{"agent" => %{"voice_model" => ""}}) =~
             "Enter a Realtime model in provider/model format"

    assert react_form_submit(view, "agent-config-form", %{
             "agent" => %{"voice_model" => "gpt-realtime"}
           }) =~ "Enter a Realtime model in provider/model format"

    react_form_submit(view, "agent-config-form", %{
      "agent" => %{"voice_model" => "openai/gpt-realtime"}
    })

    assert %{kind: :voice, provider: ^provider, voice_model: "openai/gpt-realtime"} =
             AgentConfigs.get_by_name("voice-test")
  end

  test "a saved voice session displays live and persisted transcripts without opening media",
       %{conn: conn} do
    {:ok, agent} =
      AgentConfigs.create(%{
        name: "host-audio-agent",
        kind: :voice,
        provider: "backplane",
        voice_model: "openai/gpt-realtime",
        audio_mode: "host",
        tool_contract_version: 1,
        tools: []
      })

    {:ok, session} = Synapsis.Sessions.create(agent.name)
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)

    {:ok, view, _html} = live(conn, ~p"/agent/agents/#{agent.name}/sessions/#{session.id}")

    assert has_element?(
             view,
             "[data-session='#{session.id}'][phx-hook='VoiceControls'][data-mode='host']"
           )

    assert has_element?(view, "button[data-action='start'][disabled]", "Start call")
    refute has_element?(view, "button[data-action='start'].pointer-events-none")
    refute has_element?(view, "button[data-action='start'][aria-disabled='true']")
    assert has_element?(view, "[data-action='stop']", "Hang up")
    assert has_element?(view, "[data-voice-error][role='alert'][hidden]")

    refute has_element?(view, "[data-voice-caption]")
    assert has_element?(view, "select[data-voice-endpoint] option[value='host'][selected]")
    assert has_element?(view, "select[data-voice-endpoint] option[value='browser']")
    assert has_element?(view, "[phx-hook='SynapsisReactChat']")
    assert {:ok, %{phase: :offline}} = Synapsis.VoiceSession.status(session.id)

    generation = Ecto.UUID.generate()
    item = "item_user_audio"

    assert :ok =
             History.append(session.id, [
               %{id: item, role: :user, content: History.audio_input(item, generation)}
             ])

    assert :ok =
             History.save_fact(
               session.id,
               :voice_transcript,
               generation <> ":" <> item,
               "Persisted voice transcript fixture"
             )

    {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.name}/sessions/#{session.id}")
    assert html =~ "Persisted voice transcript fixture"

    snapshot = Synapsis.VoiceSession.chat_snapshot(session.id)
    pending = %{snapshot | revision: 1, phase: :responding, reply: %{id: "reply", text: "Draft"}}
    send(view.pid, {:voice_chat, session.id, pending})

    assert [%{id: ^item}, %{id: "reply", content: "Draft", status: "streaming"}] =
             :sys.get_state(view.pid).socket.assigns.react_chat.messages

    final = %Synapsis.Message{
      id: "reply",
      role: "assistant",
      parts: [%Synapsis.Part.Text{content: "Draft answer"}],
      inserted_at: DateTime.utc_now()
    }

    completed = %{
      pending
      | revision: 2,
        phase: :listening,
        messages: pending.messages ++ [final],
        reply: nil
    }

    send(view.pid, {:voice_chat, session.id, completed})
    send(view.pid, {:voice_chat, session.id, pending})

    assert [%{id: ^item}, %{id: "reply", content: "Draft answer", status: "complete"}] =
             :sys.get_state(view.pid).socket.assigns.react_chat.messages
  end

  test "image-heavy voice history reopens and syncs with individually fetchable images", %{
    conn: conn
  } do
    {:ok, agent} =
      AgentConfigs.create(%{
        name: "voice-image-history",
        kind: :voice,
        provider: "backplane",
        voice_model: "openai/gpt-realtime",
        tools: []
      })

    {:ok, session} = Synapsis.Sessions.create(agent.name)
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)

    bytes = :binary.copy(<<42>>, 1_290_000)
    data = Base.encode64(bytes)

    for _ <- 1..12 do
      assert :ok =
               History.append(session.id, [
                 %{
                   id: Ecto.UUID.generate(),
                   role: :user,
                   content: [
                     %{type: :text, text: "Image prompt"},
                     %{type: :image, media_type: "image/png", data: data}
                   ]
                 }
               ])
    end

    {:ok, view, html} = live(conn, ~p"/agent/agents/#{agent.name}/sessions/#{session.id}")
    refute String.contains?(html, binary_part(data, 0, 100))
    session_id = session.id

    render_hook(view, "chat.sync", %{id: "agent-chat-#{session_id}", conversation_id: session_id})

    assert_push_event(view, "chat:event", %{
      type: "chat.snapshot",
      conversation_id: ^session_id,
      messages: messages
    })

    assert length(messages) == 12
    assert byte_size(JSON.encode!(messages)) < 64_000

    for message <- [hd(messages), List.last(messages)] do
      assert [_, %{type: "image", src: src}] = message.metadata.parts
      attachment = get(recycle(conn), src)
      assert response(attachment, 200) == bytes
      assert get_resp_header(attachment, "content-type") == ["image/png"]

      wrong_message = String.replace(src, "/#{message.id}?", "/#{Ecto.UUID.generate()}?")
      assert recycle(conn) |> get(wrong_message) |> response(404) == ""
      assert recycle(conn) |> get(URI.parse(src).path) |> response(404) == ""
    end
  end

  test "chat sync retains the last live view when the owner times out", %{conn: conn} do
    {:ok, agent} =
      AgentConfigs.create(%{
        name: "voice-chat-timeout",
        kind: :voice,
        provider: "backplane",
        voice_model: "openai/gpt-realtime",
        tools: []
      })

    {:ok, session} = Synapsis.Sessions.create(agent.name)
    on_exit(fn -> Synapsis.Sessions.delete(session.id) end)
    session_id = session.id
    {:ok, view, _} = live(conn, ~p"/agent/agents/#{agent.name}/sessions/#{session_id}")

    pending = %{
      Synapsis.VoiceSession.chat_snapshot(session_id)
      | revision: 1,
        phase: :responding,
        reply: %{id: "live-reply", text: "In flight"}
    }

    send(view.pid, {:voice_chat, session_id, pending})
    socket = :sys.get_state(view.pid).socket
    parent = self()

    owner =
      spawn_link(fn ->
        {:ok, _} = Elixir.Registry.register(Synapsis.Voice.Registry, session_id, nil)
        send(parent, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered

    try do
      assert {:reply, %{status: "ok"}, synced} =
               SynapsisWeb.AgentLive.Sessions.handle_event(
                 "chat.sync",
                 %{"id" => "agent-chat-#{session_id}", "conversation_id" => session_id},
                 socket
               )

      assert synced.assigns.voice_chat == pending
      assert synced.assigns.react_chat.admission.canSubmit
      assert [%{id: "live-reply", content: "In flight"}] = synced.assigns.react_chat.messages
    after
      send(owner, :stop)
    end
  end

  test "type changes preserve unsubmitted text and voice fields", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")

    react_form_change(view, "agent-config-form", %{
      "agent" => %{
        "kind" => "voice",
        "provider" => "text-provider",
        "voice_provider" => "voice-gateway",
        "label" => "Keep my draft",
        "voice_model" => "openai/gpt-realtime",
        "browser_audio_input_device" => "browser-input"
      }
    })

    react_form_change(view, "agent-config-form", %{"agent" => %{"kind" => "standard"}})
    assert has_element?(view, "#agent-provider-hidden[value='text-provider']")
    refute has_element?(view, "[data-voice-settings]")

    react_form_change(view, "agent-config-form", %{"agent" => %{"kind" => "voice"}})

    assert has_element?(
             view,
             "select[name='agent[voice_provider]'] option[value='voice-gateway'][selected]"
           )

    assert has_element?(view, "input[name='agent[voice_model]'][value='openai/gpt-realtime']")

    assert has_element?(
             view,
             "select[name='agent[browser_audio_input_device]'] option[value='browser-input'][selected]"
           )

    assert render(view) =~ "Keep my draft"
  end

  defp field_errors(view) do
    view
    |> element("[data-form-id='agent-config-form']")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-native-field-errors")
    |> hd()
    |> Formata.JSON.decode!()
  end
end
