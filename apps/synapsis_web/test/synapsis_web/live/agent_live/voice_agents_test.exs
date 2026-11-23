defmodule SynapsisWeb.AgentLive.VoiceAgentsTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{AgentConfigs, Config.Store}

  test "new and edit forms persist voice settings through the existing Agent editor", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")
    assert has_element?(view, "select[name='agent[kind]']")

    react_form_change(view, "agent-config-form", %{
      "agent" => %{
        "kind" => "voice",
        "name" => "voice-helper",
        "label" => "Voice helper",
        "provider" => "backplane",
        "voice_model" => "openai/gpt-realtime"
      }
    })

    assert has_element?(view, "[data-voice-settings]")
    assert has_element?(view, "select[name='agent[audio_mode]']")

    react_form_submit(view, "agent-config-form", %{
      "agent" => %{"audio_mode" => "host", "voice" => "cedar", "voice_delegate" => "main"}
    })

    agent = AgentConfigs.get_by_name("voice-helper")
    assert agent.kind == :voice
    assert agent.voice_model == "openai/gpt-realtime"
    assert agent.audio_mode == "host"
    assert agent.voice == "cedar"
    assert agent.voice_delegate == "main"

    assert :ok = Store.reload(:agent)
    {:ok, edit, html} = live(conn, ~p"/agent/agents/#{agent.id}/config")
    assert html =~ "Voice Agent"
    react_form_submit(edit, "agent-config-form", %{"agent" => %{"audio_mode" => "browser"}})
    assert AgentConfigs.get(agent.id).audio_mode == "browser"
  end

  test "a saved voice session renders call controls without opening a media lease", %{conn: conn} do
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

    assert has_element?(view, "[data-action='start']", "Start call")
    assert has_element?(view, "[data-action='stop']", "Hang up")
    refute has_element?(view, "[phx-hook='SynapsisReactChat']")
    assert {:ok, %{phase: :offline}} = Synapsis.VoiceSession.status(session.id)
  end

  test "type changes preserve unsubmitted text and voice fields", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/agent/agents/new")

    react_form_change(view, "agent-config-form", %{
      "agent" => %{
        "kind" => "voice",
        "label" => "Keep my draft",
        "voice_model" => "openai/gpt-realtime",
        "audio_input_device" => "browser-input"
      }
    })

    react_form_change(view, "agent-config-form", %{"agent" => %{"kind" => "standard"}})
    react_form_change(view, "agent-config-form", %{"agent" => %{"kind" => "voice"}})
    assert has_element?(view, "input[name='agent[voice_model]'][value='openai/gpt-realtime']")
    assert has_element?(view, "input[name='agent[audio_input_device]'][value='browser-input']")
    assert render(view) =~ "Keep my draft"
  end
end
