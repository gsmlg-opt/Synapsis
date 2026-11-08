defmodule SynapsisWeb.ProviderLive.Show do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents
  require Logger

  alias SynapsisWeb.ChatBridge

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Synapsis.Providers.subscribe()

    case Synapsis.Providers.get(id) do
      {:ok, provider} ->
        {:ok, credentials} = Synapsis.Credentials.list()
        all_models = fetch_models(provider)
        default_model = if all_models != [], do: hd(all_models).id, else: nil

        {:ok,
         assign(socket,
           provider: provider,
           credentials: credentials,
           fish_voices: [],
           fish_voice_loading: false,
           fish_voice_status: "Refresh voices to load the catalog.",
           fish_reference_id: fish_reference(provider),
           google_selection: google_selection(provider),
           xiaomi_selection: xiaomi_selection(provider),
           clawrouter_selection: clawrouter_selection(provider),
           openai_speech_selection: openai_speech_selection(provider),
           openai_speech_custom_options: openai_speech_custom_options(provider),
           inworld_speech_draft: inworld_speech_fields(provider),
           inworld_speech_baseline: inworld_speech_fields(provider),
           inworld_voices: [],
           inworld_voice_loading: false,
           inworld_voice_status: "Refresh voices to load the catalog.",
           elevenlabs_speech_draft: elevenlabs_speech_fields(provider),
           elevenlabs_speech_baseline: elevenlabs_speech_fields(provider),
           elevenlabs_voices: [],
           elevenlabs_voice_loading: false,
           elevenlabs_voice_status: "Refresh voices to load the catalog.",
           azure_voices: [],
           azure_voice_loading: false,
           azure_voice_status: "Refresh voices to load the catalog.",
           azure_selection: azure_selection(provider),
           page_title: provider.name,
           all_models: all_models,
           # Test chat state
           chat_open: false,
           chat_model: default_model,
           chat_messages: [],
           chat_streaming: false,
           chat_stream_text: "",
           chat_stream_ref: nil,
           chat_stream_message_id: nil,
           # OAuth device flow state
           oauth_state: :idle,
           oauth_user_code: nil,
           oauth_verification_url: nil,
           oauth_device_auth_id: nil,
           oauth_error: nil,
           oauth_poll_timer: nil
         )
         |> start_chat_bridge()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Provider not found")
         |> push_navigate(to: ~p"/settings/providers")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_provider_form", _params, socket), do: {:noreply, socket}

  def handle_event("update_provider", params, socket) do
    attrs =
      %{
        base_url: params["base_url"],
        enabled: params["enabled"] == "true"
      }
      |> then(fn attrs ->
        if oauth_settings?(socket.assigns.provider) or not Map.has_key?(params, "credential_id"),
          do: attrs,
          else: Map.put(attrs, :credential_id, blank_to_nil(params["credential_id"]))
      end)

    case Synapsis.Providers.update(socket.assigns.provider.id, attrs) do
      {:ok, provider} ->
        {:noreply,
         socket
         |> assign(provider: provider)
         |> reset_react_form("edit-provider-form", provider_form_values(provider))
         |> put_flash(:info, "Provider updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update provider")}
    end
  end

  def handle_event("clear_api_key", _params, socket) do
    case Synapsis.Providers.clear_api_key(socket.assigns.provider.id) do
      {:ok, provider} ->
        values =
          provider_form_values(provider)
          |> Map.merge(
            Map.take(react_form_draft(socket.assigns, "edit-provider-form") || %{}, [
              "base_url",
              "enabled"
            ])
          )

        {:noreply,
         socket
         |> assign(provider: provider)
         |> reset_react_form("edit-provider-form", values)
         |> put_flash(:info, "Access token cleared")}

      {:error, :oauth_provider} ->
        socket =
          case Synapsis.Providers.get(socket.assigns.provider.id) do
            {:ok, provider} -> assign(socket, provider: provider)
            {:error, _} -> socket
          end

        {:noreply,
         put_flash(socket, :error, "OAuth credentials must be managed through OAuth login")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear access token")}
    end
  end

  def handle_event("refresh_models", _params, socket) do
    case Synapsis.Providers.refresh_models(socket.assigns.provider.id) do
      {:ok, provider} ->
        all_models = Synapsis.Providers.cached_models(provider)

        {:noreply,
         socket
         |> assign(
           provider: provider,
           all_models: all_models,
           chat_model: default_chat_model(all_models, socket.assigns.chat_model)
         )
         |> reset_react_form("provider-chat-model-form", %{
           "model" => default_chat_model(all_models, socket.assigns.chat_model)
         })
         |> put_flash(:info, "Models refreshed")}

      {:error, reason} ->
        Logger.warning("provider_models_refresh_failed",
          provider_id: socket.assigns.provider.id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, "Failed to refresh models")}
    end
  end

  def handle_event("azure_refresh_voices", _params, socket) do
    if socket.assigns.provider.type == "azure_speech" and not socket.assigns.azure_voice_loading do
      id = socket.assigns.provider.id

      {:noreply,
       socket
       |> assign(azure_voice_loading: true, azure_voice_status: "Refreshing voices…")
       |> start_async({:azure_voices, id}, fn ->
         with {:ok, prepared} <- Synapsis.Providers.azure_speech_config(id) do
           Synapsis.Provider.Speech.Azure.list_voices(
             %{timeout_ms: prepared.timeout_ms},
             prepared.config
           )
         end
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("azure_selection_change", params, socket) do
    if socket.assigns.provider.type == "azure_speech" do
      {:noreply,
       assign(socket,
         azure_selection: Map.merge(socket.assigns.azure_selection, Map.take(params, ["voice"]))
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("azure_selection_save", params, socket) do
    with {:ok, %{type: "azure_speech"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         voice when is_binary(voice) <- params["voice"] do
      normalized =
        Synapsis.Provider.Speech.Azure.resolve_config(%{
          "providers" => %{"azure-speech" => %{"voice" => voice}}
        })

      config =
        (provider.config || %{})
        |> Map.drop(["voice", "voiceId", "voice_id", :voice, :voiceId, :voice_id])
        |> Map.put("voice", normalized.voice)

      case Synapsis.Providers.update(provider.id, %{config: config}) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(provider: provider, azure_selection: azure_selection(provider))
           |> put_flash(:info, "Voice saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save voice")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to save voice")}
    end
  end

  def handle_event("openai_speech_selection_change", params, socket) do
    if socket.assigns.provider.type == "openai_speech" do
      selection =
        Map.merge(
          socket.assigns.openai_speech_selection,
          Map.take(params, ~w(model voice custom_model custom_voice))
        )

      {:noreply, assign(socket, openai_speech_selection: selection)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("openai_speech_selection_save", params, socket) do
    with {:ok, %{type: "openai_speech"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         {:ok, model, voice} <-
           openai_speech_values(provider, params, socket.assigns.openai_speech_custom_options) do
      # Selection saves reread the current UUID and touch only these two fields.
      # Talk aliases and advanced operator settings retain their own meaning.
      config =
        (provider.config || %{})
        |> Map.drop([:model, :voice])
        |> Map.put("model", model)
        |> Map.put("voice", voice)

      case Synapsis.Providers.update(provider.id, %{config: config}) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(
             provider: provider,
             openai_speech_selection: openai_speech_selection(provider),
             openai_speech_custom_options: openai_speech_custom_options(provider)
           )
           |> put_flash(:info, "Speech settings saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid speech settings")}
    end
  end

  def handle_event("change_inworld_speech", params, socket) do
    if socket.assigns.provider.type == "inworld_speech" do
      {:noreply,
       assign(socket,
         inworld_speech_draft:
           Map.merge(socket.assigns.inworld_speech_draft, inworld_speech_params(params))
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_inworld_speech", params, socket) do
    draft = Map.merge(socket.assigns.inworld_speech_draft, inworld_speech_params(params))
    socket = assign(socket, inworld_speech_draft: draft)

    with {:ok, %{type: "inworld_speech"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         {:ok, config} <-
           inworld_speech_changes(
             provider.config || %{},
             socket.assigns.inworld_speech_baseline,
             draft
           ),
         {:ok, provider} <- Synapsis.Providers.update(provider.id, %{config: config}) do
      fields = inworld_speech_fields(provider)

      {:noreply,
       socket
       |> assign(
         provider: provider,
         inworld_speech_draft: fields,
         inworld_speech_baseline: fields
       )
       |> put_flash(:info, "Speech settings saved")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
    end
  end

  def handle_event("refresh_inworld_voices", _params, socket) do
    if socket.assigns.provider.type == "inworld_speech" and
         not socket.assigns.inworld_voice_loading do
      id = socket.assigns.provider.id

      {:noreply,
       socket
       |> assign(inworld_voice_loading: true, inworld_voice_status: "Refreshing voices…")
       |> start_async({:inworld_voices, id}, fn ->
         with {:ok, prepared} <- Synapsis.Providers.inworld_speech_config(id) do
           Synapsis.Provider.Speech.Inworld.list_voices(
             %{timeout_ms: prepared.timeout_ms},
             prepared.config
           )
         end
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("change_elevenlabs_speech", params, socket) do
    if socket.assigns.provider.type == "elevenlabs" do
      {:noreply,
       assign(socket,
         elevenlabs_speech_draft:
           Map.merge(socket.assigns.elevenlabs_speech_draft, elevenlabs_speech_params(params))
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_elevenlabs_speech", params, socket) do
    draft = Map.merge(socket.assigns.elevenlabs_speech_draft, elevenlabs_speech_params(params))
    socket = assign(socket, elevenlabs_speech_draft: draft)

    with {:ok, %{type: "elevenlabs"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         {:ok, config} <-
           elevenlabs_speech_changes(
             provider.config || %{},
             socket.assigns.elevenlabs_speech_baseline,
             draft
           ),
         {:ok, provider} <- Synapsis.Providers.update(provider.id, %{config: config}) do
      fields = elevenlabs_speech_fields(provider)

      {:noreply,
       socket
       |> assign(
         provider: provider,
         elevenlabs_speech_draft: fields,
         elevenlabs_speech_baseline: fields
       )
       |> put_flash(:info, "Speech settings saved")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
    end
  end

  def handle_event("refresh_elevenlabs_voices", _params, socket) do
    if socket.assigns.provider.type == "elevenlabs" and
         not socket.assigns.elevenlabs_voice_loading do
      id = socket.assigns.provider.id

      {:noreply,
       socket
       |> assign(elevenlabs_voice_loading: true, elevenlabs_voice_status: "Refreshing voices…")
       |> start_async({:elevenlabs_voices, id}, fn ->
         with {:ok, prepared} <- Synapsis.Providers.elevenlabs_speech_config(id) do
           Synapsis.Provider.Speech.ElevenLabs.list_voices(
             %{timeout_ms: prepared.timeout_ms},
             prepared.config
           )
         end
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clawrouter_selection_change", params, socket) do
    if socket.assigns.provider.type == "clawrouter_speech" do
      selection =
        Map.merge(socket.assigns.clawrouter_selection, Map.take(params, ["model", "voice"]))

      {:noreply, assign(socket, clawrouter_selection: selection)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clawrouter_selection_save", params, socket) do
    with {:ok, %{type: "clawrouter_speech"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         model when model in ["openai/tts-1"] <- params["model"],
         voice when voice in ~w(alloy echo fable onyx nova shimmer) <- params["voice"] do
      # Re-read the UUID and replace only the selection aliases, preserving the
      # current route, referenced credential and all advanced operator settings.
      aliases =
        ~w(model modelId model_id speakerVoice speakerVoiceId speaker_voice speaker_voice_id voice voiceId voice_id)

      atom_aliases =
        ~w(model modelId model_id speakerVoice speakerVoiceId speaker_voice speaker_voice_id voice voiceId voice_id)a

      config =
        (provider.config || %{})
        |> Map.drop(aliases ++ atom_aliases)
        |> Map.put("model", model)
        |> Map.put("voice", voice)

      case Synapsis.Providers.update(provider.id, %{config: config}) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(provider: provider, clawrouter_selection: clawrouter_selection(provider))
           |> put_flash(:info, "Speech settings saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Invalid speech settings")}
    end
  end

  def handle_event("xiaomi_selection_change", params, socket) do
    if socket.assigns.provider.type == "xiaomi_speech" do
      selection = Map.merge(socket.assigns.xiaomi_selection, Map.take(params, ["model", "voice"]))
      {:noreply, assign(socket, xiaomi_selection: selection)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("xiaomi_selection_save", params, socket) do
    with {:ok, %{type: "xiaomi_speech"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         %{"model" => model, "voice" => voice} when is_binary(model) and is_binary(voice) <-
           params do
      normalized =
        Synapsis.Provider.Speech.Xiaomi.resolve_config(%{
          "providers" => %{"xiaomi" => %{"model" => model, "voice" => voice}}
        })

      # An explicit selection replaces only model/voice aliases, retaining the
      # operator's style, format, timeout and advanced TOML settings verbatim.
      aliases =
        ~w(model modelId model_id speakerVoice speakerVoiceId speaker_voice speaker_voice_id voice voiceId voice_id)

      atom_aliases =
        ~w(model modelId model_id speakerVoice speakerVoiceId speaker_voice speaker_voice_id voice voiceId voice_id)a

      config =
        (provider.config || %{})
        |> Map.drop(aliases ++ atom_aliases)
        |> Map.put("model", normalized.model)
        |> Map.put("voice", normalized.voice)

      case Synapsis.Providers.update(provider.id, %{config: config}) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(provider: provider, xiaomi_selection: xiaomi_selection(provider))
           |> put_flash(:info, "Speech settings saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
    end
  rescue
    _error in ArgumentError -> {:noreply, put_flash(socket, :error, "Invalid speech settings")}
  end

  def handle_event("google_selection_change", params, socket) do
    if socket.assigns.provider.type == "google_speech" do
      selection =
        Map.merge(socket.assigns.google_selection, Map.take(params, ["model", "voice_name"]))

      {:noreply, assign(socket, google_selection: selection)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("google_selection_save", params, socket) do
    with {:ok, %{type: "google_speech"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         %{"model" => model, "voice_name" => voice} when is_binary(model) and is_binary(voice) <-
           params do
      normalized =
        Synapsis.Provider.Speech.Google.resolve_config(%{
          "providers" => %{"google" => %{"model" => model, "voiceName" => voice}}
        })

      config =
        (provider.config || %{})
        |> Map.drop([
          "model",
          "model_id",
          "modelId",
          :model,
          :model_id,
          :modelId,
          "voiceName",
          "voice_name",
          "voice",
          :voiceName,
          :voice_name,
          :voice
        ])
        |> Map.put("model", normalized.model)
        |> Map.put("voice_name", normalized.voice_name)

      case Synapsis.Providers.update(provider.id, %{config: config}) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(provider: provider, google_selection: google_selection(provider))
           |> put_flash(:info, "Speech settings saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to save speech settings")}
    end
  rescue
    _error in ArgumentError -> {:noreply, put_flash(socket, :error, "Invalid speech settings")}
  end

  def handle_event("fish_refresh_voices", _params, socket) do
    if socket.assigns.provider.type == "fish_audio_speech" and
         not socket.assigns.fish_voice_loading do
      id = socket.assigns.provider.id

      {:noreply,
       socket
       |> assign(fish_voice_loading: true, fish_voice_status: "Refreshing voices…")
       |> start_async(:fish_voices, fn ->
         with {:ok, prepared} <- Synapsis.Providers.fish_audio_config(id),
              do:
                Synapsis.Provider.Speech.FishAudio.list_voices(
                  %{timeout_ms: prepared.timeout_ms},
                  prepared.config
                )
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("fish_select_voice", %{"voice_id" => id}, socket) do
    if Enum.any?(socket.assigns.fish_voices, &(&1.id == id)),
      do: {:noreply, assign(socket, fish_reference_id: id)},
      else: {:noreply, socket}
  end

  def handle_event("fish_save_voice", %{"reference_id" => reference}, socket) do
    with {:ok, %{type: "fish_audio_speech"} = provider} <-
           Synapsis.Providers.get(socket.assigns.provider.id),
         true <- is_binary(reference) do
      reference =
        Synapsis.Provider.Speech.FishAudio.resolve_talk_overrides(%{"referenceId" => reference})[
          :reference_id
        ] || ""

      config =
        (provider.config || %{})
        |> Map.drop([
          "speakerVoiceId",
          "speaker_voice_id",
          "voiceId",
          "voice_id",
          "referenceId",
          :speakerVoiceId,
          :speaker_voice_id,
          :voiceId,
          :voice_id,
          :referenceId,
          :reference_id
        ])
        |> Map.put("reference_id", reference)

      case Synapsis.Providers.update(provider.id, %{config: config}) do
        {:ok, provider} ->
          {:noreply,
           socket
           |> assign(provider: provider, fish_reference_id: reference)
           |> put_flash(:info, "Voice saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save voice")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Failed to save voice")}
    end
  end

  # -- Test Chat Events --

  def handle_event("toggle_chat", _params, socket) do
    socket = assign(socket, chat_open: !socket.assigns.chat_open)

    socket =
      if socket.assigns.chat_open do
        socket
        |> assign(:react_chat_initial, socket.assigns.react_chat)
        |> ChatBridge.snapshot()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("chat_select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, chat_model: model)}
  end

  def handle_event("chat_send", %{"message" => message}, socket) when message != "" do
    {socket, _reply} = admit_chat_message(socket, message)
    {:noreply, socket}
  end

  def handle_event("chat_send", _params, socket), do: {:noreply, socket}

  def handle_event("chat.send", params, socket) do
    request_id = params["request_id"]

    cond do
      not ChatBridge.valid_scope?(socket, params) ->
        {:reply, %{status: "error", message: "Conversation is no longer available"}, socket}

      not is_binary(request_id) or request_id == "" or byte_size(request_id) > 128 ->
        {:reply, %{status: "error", message: "Invalid request ID"}, socket}

      reply = ChatBridge.request_reply(socket, request_id) ->
        {:reply, reply, socket}

      params["images"] not in [nil, []] or params["attachments"] not in [nil, []] ->
        reply = %{status: "error", message: "Provider test chat does not support attachments"}
        {:reply, reply, ChatBridge.remember_request(socket, request_id, reply)}

      true ->
        {socket, reply} = admit_chat_message(socket, params["text"])
        {:reply, reply, ChatBridge.remember_request(socket, request_id, reply)}
    end
  end

  def handle_event("chat.sync", params, socket) do
    if ChatBridge.valid_scope?(socket, params) do
      {:reply, %{status: "ok"}, ChatBridge.snapshot(socket)}
    else
      {:reply, %{status: "error", message: "Conversation is no longer available"}, socket}
    end
  end

  def handle_event("chat.stop", params, socket) do
    if ChatBridge.valid_scope?(socket, params) do
      socket = cancel_chat_stream(socket, false)
      {:reply, %{status: "ok"}, sync_chat(socket)}
    else
      {:reply, %{status: "error", message: "Conversation is no longer available"}, socket}
    end
  end

  def handle_event("chat.retry", _params, socket) do
    {:reply, %{status: "error", message: "Send a new message to retry the provider"}, socket}
  end

  def handle_event("chat.action", _params, socket) do
    {:reply, %{status: "error", message: "Unsupported provider chat action"}, socket}
  end

  def handle_event("chat_clear", _params, socket) do
    socket = socket |> cancel_chat_stream(true) |> assign(chat_messages: []) |> sync_chat()
    {:noreply, socket}
  end

  # -- OAuth Device Flow Events --

  def handle_event("oauth_start", _params, socket) do
    case Synapsis.Provider.OAuth.OpenAI.request_user_code() do
      {:ok, device_info} ->
        timer = Process.send_after(self(), :oauth_poll, device_info.interval * 1000)

        {:noreply,
         assign(socket,
           oauth_state: :waiting_for_user,
           oauth_user_code: device_info.user_code,
           oauth_verification_url: Synapsis.Provider.OAuth.OpenAI.verification_url(),
           oauth_device_auth_id: device_info.device_auth_id,
           oauth_error: nil,
           oauth_poll_timer: timer,
           oauth_poll_interval: device_info.interval,
           oauth_poll_started_at: System.monotonic_time(:millisecond)
         )}

      {:error, :device_auth_not_enabled} ->
        {:noreply,
         assign(socket,
           oauth_state: :error,
           oauth_error: "Device code auth not enabled. Enable it in ChatGPT Settings > Security."
         )}

      {:error, reason} ->
        Logger.warning("oauth_start_failed", reason: inspect(reason))

        {:noreply,
         assign(socket,
           oauth_state: :error,
           oauth_error: "Failed to start OAuth flow"
         )}
    end
  end

  def handle_event("oauth_cancel", _params, socket) do
    if socket.assigns.oauth_poll_timer, do: Process.cancel_timer(socket.assigns.oauth_poll_timer)

    {:noreply,
     assign(socket,
       oauth_state: :idle,
       oauth_user_code: nil,
       oauth_device_auth_id: nil,
       oauth_error: nil,
       oauth_poll_timer: nil
     )}
  end

  def handle_event("oauth_refresh", _params, socket) do
    provider = socket.assigns.provider

    case Synapsis.Providers.refresh_oauth(provider.id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(provider: updated)
         |> put_flash(:info, "OAuth tokens refreshed")}

      {:error, :oauth_reauth_required} ->
        {:noreply, put_flash(socket, :error, "Token expired — please sign in again")}

      {:error, reason} ->
        Logger.warning("oauth_refresh_failed", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Refresh failed")}
    end
  end

  @impl true
  def handle_async({:inworld_voices, id}, {:ok, {:ok, voices}}, socket) do
    if socket.assigns.provider.id == id do
      {:noreply,
       assign(socket,
         inworld_voices: voices,
         inworld_voice_loading: false,
         inworld_voice_status:
           "#{length(voices)} voices loaded. Select a voice or enter a custom voice."
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:inworld_voices, id}, _result, socket) do
    if socket.assigns.provider.id == id,
      do:
        {:noreply,
         assign(socket,
           inworld_voice_loading: false,
           inworld_voice_status: "Voice refresh failed."
         )},
      else: {:noreply, socket}
  end

  def handle_async({:elevenlabs_voices, id}, {:ok, {:ok, voices}}, socket) do
    if socket.assigns.provider.id == id do
      {:noreply,
       assign(socket,
         elevenlabs_voices: voices,
         elevenlabs_voice_loading: false,
         elevenlabs_voice_status:
           "#{length(voices)} voices loaded. Select a voice or enter a custom voice."
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:elevenlabs_voices, id}, _result, socket) do
    if socket.assigns.provider.id == id,
      do:
        {:noreply,
         assign(socket,
           elevenlabs_voice_loading: false,
           elevenlabs_voice_status: "Voice refresh failed."
         )},
      else: {:noreply, socket}
  end

  def handle_async({:azure_voices, id}, {:ok, {:ok, voices}}, socket) do
    if socket.assigns.provider.id == id do
      {:noreply,
       assign(socket,
         azure_voices: voices,
         azure_voice_loading: false,
         azure_voice_status:
           "#{length(voices)} voices loaded. Select a voice or enter a custom voice."
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:azure_voices, id}, _result, socket) do
    if socket.assigns.provider.id == id,
      do:
        {:noreply,
         assign(socket, azure_voice_loading: false, azure_voice_status: "Voice refresh failed.")},
      else: {:noreply, socket}
  end

  def handle_async(:fish_voices, {:ok, {:ok, voices}}, socket) do
    {:noreply,
     assign(socket,
       fish_voices: voices,
       fish_voice_loading: false,
       fish_voice_status:
         "#{length(voices)} voices loaded. Select a voice or enter a reference ID."
     )}
  end

  def handle_async(:fish_voices, _result, socket) do
    {:noreply,
     assign(socket, fish_voice_loading: false, fish_voice_status: "Voice refresh failed.")}
  end

  # -- Streaming handle_info --

  @impl true
  def handle_info(
        {:provider_chunk, {:text_delta, text}},
        %{assigns: %{chat_streaming: true}} = socket
      ) do
    socket =
      socket
      |> assign(chat_stream_text: socket.assigns.chat_stream_text <> text)
      |> ChatBridge.delta(socket.assigns.chat_stream_message_id, text)

    {:noreply, socket}
  end

  def handle_info({:provider_chunk, _other_event}, socket) do
    # Ignore non-text events (reasoning, tool_use, etc.)
    {:noreply, socket}
  end

  def handle_info(:provider_done, %{assigns: %{chat_streaming: true}} = socket) do
    messages =
      socket.assigns.chat_messages ++
        [
          chat_message(
            "assistant",
            socket.assigns.chat_stream_text,
            socket.assigns.chat_stream_message_id
          )
        ]

    {:noreply,
     assign(socket,
       chat_messages: messages,
       chat_streaming: false,
       chat_stream_text: "",
       chat_stream_ref: nil,
       chat_stream_message_id: nil
     )
     |> sync_chat()}
  end

  def handle_info({:provider_error, reason}, %{assigns: %{chat_streaming: true}} = socket) do
    messages =
      socket.assigns.chat_messages ++
        [chat_message("error", "Error: #{chat_error_message(reason)}")]

    {:noreply,
     assign(socket,
       chat_messages: messages,
       chat_streaming: false,
       chat_stream_text: "",
       chat_stream_ref: nil,
       chat_stream_message_id: nil
     )
     |> sync_chat()}
  end

  def handle_info(:provider_done, socket), do: {:noreply, socket}
  def handle_info({:provider_error, _reason}, socket), do: {:noreply, socket}

  # Task completion messages
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case socket.assigns.chat_stream_ref do
      %{ref: ^ref} -> handle_info({:provider_error, "Provider stream stopped"}, socket)
      _ -> {:noreply, socket}
    end
  end

  # -- OAuth polling handle_info --

  def handle_info(:oauth_poll, %{assigns: %{oauth_state: :waiting_for_user}} = socket) do
    elapsed = System.monotonic_time(:millisecond) - socket.assigns.oauth_poll_started_at

    if elapsed > Synapsis.Provider.OAuth.OpenAI.max_poll_duration_ms() do
      {:noreply,
       assign(socket,
         oauth_state: :error,
         oauth_error: "Authorization timed out (15 minutes). Please try again.",
         oauth_poll_timer: nil
       )}
    else
      case Synapsis.Provider.OAuth.OpenAI.poll_device_token(
             socket.assigns.oauth_device_auth_id,
             socket.assigns.oauth_user_code
           ) do
        {:ok, auth_result} ->
          handle_oauth_authorized(socket, auth_result)

        {:pending, :authorization_pending} ->
          timer =
            Process.send_after(self(), :oauth_poll, socket.assigns.oauth_poll_interval * 1000)

          {:noreply, assign(socket, oauth_poll_timer: timer)}

        {:error, reason} ->
          Logger.warning("oauth_poll_error", reason: inspect(reason))

          {:noreply,
           assign(socket,
             oauth_state: :error,
             oauth_error: "Polling failed",
             oauth_poll_timer: nil
           )}
      end
    end
  end

  # Stale poll timer fired after oauth_cancel — ignore
  def handle_info(:oauth_poll, socket), do: {:noreply, socket}

  def handle_info({:provider_catalog_changed}, socket) do
    case Synapsis.Providers.get(socket.assigns.provider.id) do
      {:ok, provider} ->
        {:ok, credentials} = Synapsis.Credentials.list()

        {:noreply,
         assign(socket,
           provider: provider,
           credentials: credentials,
           all_models: Synapsis.Providers.cached_models(provider)
         )}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider was deleted")
         |> push_navigate(to: ~p"/settings/providers")}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if stream = socket.assigns[:chat_stream_ref], do: Synapsis.Provider.Adapter.cancel(stream)

    if timer = socket.assigns[:oauth_poll_timer] do
      Process.cancel_timer(timer)
    end

    :ok
  end

  # -- Private helpers --

  defp admit_chat_message(socket, message)
       when not is_binary(message) or message == "" do
    {socket, %{status: "error", message: "Enter a message"}}
  end

  defp admit_chat_message(socket, message) do
    cond do
      String.trim(message) == "" ->
        {socket, %{status: "error", message: "Enter a message"}}

      byte_size(message) > 256_000 ->
        {socket, %{status: "error", message: "Message too large"}}

      socket.assigns.chat_streaming ->
        {socket, %{status: "error", message: "Wait for the provider response"}}

      true ->
        start_chat_stream(socket, message)
    end
  end

  defp start_chat_stream(socket, message) do
    provider = socket.assigns.provider
    model = socket.assigns.chat_model

    messages =
      socket.assigns.chat_messages ++ [chat_message("user", message)]

    case Synapsis.Providers.runtime_config(provider.name) do
      {:ok, config} ->
        request = build_chat_request(config, model, messages)

        case Synapsis.Provider.Adapter.stream(request, config) do
          {:ok, ref} ->
            socket =
              assign(socket,
                chat_messages: messages,
                chat_streaming: true,
                chat_stream_text: "",
                chat_stream_ref: ref,
                chat_stream_message_id: Ecto.UUID.generate()
              )
              |> sync_chat()

            {socket, %{status: "ok"}}

          {:error, :model_unavailable} ->
            reject_chat(socket, messages, "Model is currently unavailable.")

          {:error, :provider_unavailable} ->
            reject_chat(socket, messages, "Provider is currently unavailable.")

          {:error, _reason} ->
            reject_chat(socket, messages, "Failed to start provider stream.")
        end

      {:error, :provider_unavailable} ->
        reject_chat(socket, messages, "Provider is currently unavailable.")

      {:error, _} ->
        reject_chat(socket, messages, "Provider not registered. Save and enable it first.")
    end
  end

  defp chat_message(role, content, id \\ Ecto.UUID.generate()) do
    message = %{id: id, role: role, content: content, status: "complete"}
    if role == "error", do: Map.merge(message, %{status: "error", error: content}), else: message
  end

  defp chat_error_message(%{message: message}) when is_binary(message), do: message
  defp chat_error_message(message) when is_binary(message), do: message
  defp chat_error_message({:stream_violation, message}) when is_binary(message), do: message
  defp chat_error_message(_reason), do: "Provider request failed"

  defp reject_chat(socket, messages, message) do
    socket =
      assign(socket, chat_messages: messages ++ [chat_message("error", message)]) |> sync_chat()

    {socket, %{status: "error", message: message}}
  end

  defp start_chat_bridge(socket) do
    ChatBridge.start(
      socket,
      "provider-chat-#{socket.assigns.provider.id}",
      socket.assigns.provider.id,
      chat_snapshot(socket.assigns)
    )
  end

  defp sync_chat(socket), do: ChatBridge.sync(socket, chat_snapshot(socket.assigns))

  defp chat_snapshot(assigns) do
    messages =
      if assigns.chat_streaming do
        assigns.chat_messages ++
          [
            %{
              id: assigns.chat_stream_message_id,
              role: "assistant",
              content: assigns.chat_stream_text,
              status: "streaming"
            }
          ]
      else
        assigns.chat_messages
      end

    %{
      messages: messages,
      metadata: %{kind: "provider", attachmentsAllowed: false, canStop: true},
      runtime: %{
        active: assigns.chat_streaming,
        phase: if(assigns.chat_streaming, do: "streaming", else: "idle")
      },
      admission: %{canSubmit: not assigns.chat_streaming, allowWhileStreaming: false}
    }
  end

  defp cancel_chat_stream(socket, clear?) do
    if stream = socket.assigns.chat_stream_ref do
      Synapsis.Provider.Adapter.cancel(stream)
      Process.demonitor(stream.ref, [:flush])
      drain_chat_stream_messages()
    end

    messages =
      if socket.assigns.chat_streaming and not clear? do
        socket.assigns.chat_messages ++
          [
            chat_message(
              "assistant",
              socket.assigns.chat_stream_text,
              socket.assigns.chat_stream_message_id
            )
            |> Map.put(:status, "cancelled")
          ]
      else
        socket.assigns.chat_messages
      end

    assign(socket,
      chat_messages: messages,
      chat_streaming: false,
      chat_stream_text: "",
      chat_stream_ref: nil,
      chat_stream_message_id: nil
    )
  end

  defp drain_chat_stream_messages do
    receive do
      {:provider_chunk, _event} -> drain_chat_stream_messages()
      {:provider_error, _reason} -> drain_chat_stream_messages()
      :provider_done -> drain_chat_stream_messages()
    after
      0 -> :ok
    end
  end

  defp handle_oauth_authorized(socket, auth_result) do
    case Synapsis.Provider.OAuth.OpenAI.exchange_code(
           auth_result.authorization_code,
           auth_result.code_verifier
         ) do
      {:ok, tokens} ->
        case Synapsis.Providers.save_oauth_tokens(socket.assigns.provider.id, tokens) do
          {:ok, provider} ->
            all_models = fetch_models(provider)

            {:noreply,
             socket
             |> assign(
               provider: provider,
               all_models: all_models,
               oauth_state: :authorized,
               oauth_poll_timer: nil,
               oauth_user_code: nil,
               oauth_device_auth_id: nil
             )
             |> put_flash(:info, "OAuth login successful")}

          {:error, _reason} ->
            {:noreply,
             assign(socket,
               oauth_state: :error,
               oauth_error: "Failed to save tokens",
               oauth_poll_timer: nil
             )}
        end

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           oauth_state: :error,
           oauth_error: "Token exchange failed",
           oauth_poll_timer: nil
         )}
    end
  end

  defp fetch_models(provider) do
    case Synapsis.Providers.models_by_id(provider.id) do
      {:ok, models} -> models
      {:error, _} -> []
    end
  end

  defp default_chat_model([], current), do: current
  defp default_chat_model(models, nil), do: hd(models).id

  defp default_chat_model(models, current),
    do: if(Enum.any?(models, &(&1.id == current)), do: current, else: hd(models).id)

  defp build_chat_request(%{type: type} = config, model, messages)
       when type in ["openai_responses", :openai_responses] do
    messages =
      messages
      |> Enum.reject(&(&1.role == "error"))
      |> Enum.map(fn %{role: role, content: content} ->
        %{role: role, parts: [%Synapsis.Part.Text{content: content}]}
      end)

    Synapsis.Provider.Adapter.format_request(messages, [], %{
      provider_type: type,
      model: model,
      max_tokens: 1024,
      stream: true,
      base_url: config[:base_url]
    })
  end

  defp build_chat_request(config, model, messages) do
    transport = Synapsis.Provider.Adapter.resolve_transport_type(config[:type])
    formatted_messages = Enum.map(messages, &format_chat_message(transport, &1))

    case transport do
      :anthropic ->
        %{
          model: model,
          max_tokens: 1024,
          stream: true,
          messages: formatted_messages
        }

      :openai ->
        %{
          model: model,
          stream: true,
          messages: formatted_messages
        }

      :google ->
        %{
          model: model,
          stream: true,
          contents: formatted_messages
        }
    end
  end

  defp format_chat_message(:anthropic, %{role: role, content: content}) do
    %{role: role, content: [%{type: "text", text: content}]}
  end

  defp format_chat_message(:openai, %{role: role, content: content}) do
    %{role: role, content: content}
  end

  defp format_chat_message(:google, %{role: "user", content: content}) do
    %{role: "user", parts: [%{text: content}]}
  end

  defp format_chat_message(:google, %{role: "assistant", content: content}) do
    %{role: "model", parts: [%{text: content}]}
  end

  defp format_chat_message(:google, %{role: _, content: content}) do
    %{role: "user", parts: [%{text: content}]}
  end

  defp provider_form_values(provider) do
    %{
      "base_url" => provider.base_url,
      "credential_id" => provider.credential_id || "",
      "enabled" => provider.enabled
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp oauth_settings?(provider) do
    provider.name == "openai-sub" or provider.preset == "openai-sub" or
      Synapsis.Providers.oauth_provider?(provider)
  end

  defp azure_selection(%{type: "azure_speech", config: config}) do
    config = config || %{}
    voice = Map.get(config, "voice", Map.get(config, :voice))

    alias_voice =
      Map.get(config, "voiceId", Map.get(config, "voice_id", Map.get(config, :voice_id)))

    selected =
      Synapsis.Provider.Speech.Azure.resolve_config(%{
        "providers" => %{"azure-speech" => %{"voice" => voice, "voiceId" => alias_voice}}
      })

    %{"voice" => selected.voice}
  end

  defp azure_selection(_), do: %{}

  defp azure_voice_label(voice) do
    [voice[:name] || voice.id, voice[:locale], voice[:gender], voice[:description]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp openai_speech_selection(%{type: "openai_speech", config: config}) do
    selected = Synapsis.Provider.Speech.OpenAI.resolve_config(config || %{})
    %{"model" => selected.model, "voice" => selected.voice}
  end

  defp openai_speech_selection(_provider), do: %{}

  defp inworld_speech_fields(%{type: "inworld_speech", config: config}) do
    config = config || %{}

    raw =
      Enum.reduce(inworld_speech_aliases(), %{}, fn {field, aliases}, values ->
        source = %{
          "model_id" => "modelId",
          "voice_id" => "voiceId",
          "temperature" => "temperature"
        }

        case Enum.find(aliases, &Map.has_key?(config, &1)) do
          nil -> values
          key -> Map.put(values, source[field], Map.get(config, key))
        end
      end)

    resolved =
      Synapsis.Provider.Speech.Inworld.resolve_config(%{"providers" => %{"inworld" => raw}})

    Map.new(inworld_speech_aliases(), fn {field, aliases} ->
      value = Map.get(resolved, Enum.at(aliases, 1))
      {field, if(is_nil(value), do: "", else: to_string(value))}
    end)
  end

  defp inworld_speech_fields(_provider), do: %{}

  defp inworld_speech_aliases do
    [
      {"model_id", ["model_id", :model_id, "modelId", :modelId]},
      {"voice_id", ["voice_id", :voice_id, "voiceId", :voiceId]},
      {"temperature", ["temperature", :temperature]}
    ]
  end

  defp inworld_speech_params(params) do
    Map.take(params, Enum.map(inworld_speech_aliases(), &elem(&1, 0)))
  end

  defp inworld_speech_changes(config, baseline, draft) do
    # Patch intentional edits from the rendered baseline into the newest UUID
    # record, retaining untouched aliases and advanced values exactly.
    Enum.reduce_while(inworld_speech_aliases(), {:ok, config}, fn {field, aliases},
                                                                  {:ok, current} ->
      if inworld_speech_unchanged?(field, baseline[field], draft[field]) do
        {:cont, {:ok, current}}
      else
        case inworld_speech_value(field, draft[field]) do
          {:ok, value} ->
            updated = Map.drop(current, aliases)
            updated = if is_nil(value), do: updated, else: Map.put(updated, field, value)
            {:cont, {:ok, updated}}

          {:error, _} = error ->
            {:halt, error}
        end
      end
    end)
  end

  defp inworld_speech_unchanged?("temperature", baseline, draft) do
    baseline == draft or
      case {inworld_speech_value("temperature", baseline),
            inworld_speech_value("temperature", draft)} do
        {{:ok, a}, {:ok, b}} -> a == b
        _ -> false
      end
  end

  defp inworld_speech_unchanged?(_field, baseline, draft), do: baseline == draft

  defp inworld_speech_value("temperature", value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      text ->
        case Float.parse(text) do
          {number, ""} when number > 0 and number <= 2 -> {:ok, number}
          _ -> {:error, :invalid_temperature}
        end
    end
  end

  defp inworld_speech_value(_field, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_selection}
      value -> {:ok, value}
    end
  end

  defp inworld_speech_value(_field, _value), do: {:error, :invalid_setting}

  defp inworld_voice_label(voice) do
    [voice[:name] || voice.id, voice[:description], voice[:locale], voice[:gender]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp elevenlabs_speech_fields(%{type: "elevenlabs", config: config}) do
    config = config || %{}
    defaults = Synapsis.Provider.Speech.ElevenLabs.resolve_config(%{})

    Map.new(elevenlabs_speech_aliases(), fn {field, aliases} ->
      default = Map.get(defaults, Enum.at(aliases, 1))

      value =
        case Enum.find(aliases, &Map.has_key?(config, &1)) do
          nil -> default
          key -> Map.get(config, key)
        end

      displayed =
        cond do
          is_nil(value) -> ""
          field == "voice_settings" -> Jason.encode!(value)
          true -> to_string(value)
        end

      {field, displayed}
    end)
  end

  defp elevenlabs_speech_fields(_provider), do: %{}

  defp elevenlabs_speech_aliases do
    [
      {"model_id", ["model_id", :model_id, "modelId", :modelId]},
      {"voice_id", ["voice_id", :voice_id, "voiceId", :voiceId]},
      {"seed", ["seed", :seed]},
      {"apply_text_normalization",
       [
         "apply_text_normalization",
         :apply_text_normalization,
         "applyTextNormalization",
         :applyTextNormalization
       ]},
      {"language_code", ["language_code", :language_code, "languageCode", :languageCode]},
      {"voice_settings", ["voice_settings", :voice_settings, "voiceSettings", :voiceSettings]}
    ]
  end

  defp elevenlabs_speech_params(params) do
    Map.take(params, Enum.map(elevenlabs_speech_aliases(), &elem(&1, 0)))
  end

  defp elevenlabs_speech_changes(config, baseline, draft) do
    # Compare against the saved form, never the latest change event. Full stale
    # submissions must leave untouched fields in the current UUID record exact.
    Enum.reduce_while(elevenlabs_speech_aliases(), {:ok, config}, fn {field, aliases},
                                                                     {:ok, current} ->
      if elevenlabs_speech_unchanged?(field, baseline[field], draft[field]) do
        {:cont, {:ok, current}}
      else
        case elevenlabs_speech_value(field, draft[field]) do
          {:ok, value} ->
            updated = Map.drop(current, aliases)
            updated = if is_nil(value), do: updated, else: Map.put(updated, field, value)
            {:cont, {:ok, updated}}

          {:error, _} = error ->
            {:halt, error}
        end
      end
    end)
  end

  defp elevenlabs_speech_unchanged?("voice_settings", baseline, draft) do
    baseline == draft or
      (is_binary(baseline) and is_binary(draft) and
         match?({:ok, _}, Jason.decode(baseline)) and
         Jason.decode(baseline) == Jason.decode(draft))
  end

  defp elevenlabs_speech_unchanged?(_field, baseline, draft), do: baseline == draft

  defp elevenlabs_speech_value("voice_settings", value) when is_binary(value) do
    if String.trim(value) == "" do
      {:ok, nil}
    else
      case Jason.decode(value) do
        {:ok, settings} when is_map(settings) -> {:ok, settings}
        _ -> {:error, :invalid_voice_settings}
      end
    end
  end

  defp elevenlabs_speech_value("seed", value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seed, ""} -> {:ok, seed}
      _ -> if String.trim(value) == "", do: {:ok, nil}, else: {:error, :invalid_seed}
    end
  end

  defp elevenlabs_speech_value(field, value) when is_binary(value) do
    case String.trim(value) do
      "" when field in ["model_id", "voice_id"] -> {:error, :invalid_selection}
      "" -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  defp elevenlabs_speech_value(_field, _value), do: {:error, :invalid_setting}

  defp elevenlabs_voice_label(voice) do
    [voice[:name] || voice.id, voice[:category], voice[:description]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp openai_speech_custom_options(provider) do
    Map.new(openai_speech_selection(provider), fn {field, value} ->
      {field, if(value == "__custom__", do: "__custom___", else: "__custom__")}
    end)
  end

  defp openai_speech_custom?(provider) do
    root =
      Synapsis.Provider.Speech.OpenAI.resolve_config(%{
        "baseUrl" => provider.base_url || Synapsis.Providers.default_base_url("openai_speech")
      }).base_url

    root not in ["https://api.openai.com", "https://api.openai.com/v1"]
  end

  defp openai_speech_options(choices, selected, custom?, custom_option) do
    retained = if selected not in choices and selected != custom_option, do: [selected], else: []
    options = Enum.map(choices ++ retained, &{&1, &1})
    if custom?, do: options ++ [{custom_option, "Custom value…"}], else: options
  end

  defp openai_speech_values(provider, params, custom_options) do
    custom? = openai_speech_custom?(provider)

    value = fn field ->
      if params[field] == custom_options[field] and custom?,
        do: params["custom_" <> field],
        else: params[field]
    end

    with model when is_binary(model) <- value.("model"),
         voice when is_binary(voice) <- value.("voice") do
      selected =
        Synapsis.Provider.Speech.OpenAI.resolve_config(%{"model" => model, "voice" => voice})

      if custom? or
           (selected.model in Synapsis.Provider.Speech.OpenAI.models() and
              selected.voice in Synapsis.Provider.Speech.OpenAI.voices()),
         do: {:ok, selected.model, selected.voice},
         else: {:error, :invalid_selection}
    else
      _ -> {:error, :invalid_selection}
    end
  end

  defp clawrouter_selection(%{type: "clawrouter_speech", config: config}) do
    selected =
      Synapsis.Provider.Speech.ClawRouter.resolve_config(%{
        "providers" => %{"clawrouter" => config || %{}}
      })

    %{"model" => selected.model, "voice" => selected.voice}
  end

  defp clawrouter_selection(_provider), do: %{}

  defp xiaomi_selection(%{type: "xiaomi_speech", config: config}) do
    selected =
      Synapsis.Provider.Speech.Xiaomi.resolve_config(%{
        "providers" => %{"xiaomi" => config || %{}}
      })

    %{"model" => selected.model, "voice" => selected.voice}
  end

  defp xiaomi_selection(_provider), do: %{}

  defp google_selection(%{type: "google_speech", config: config}) do
    config = config || %{}

    raw = %{
      "model" => Map.get(config, "model", Map.get(config, :model)),
      "voiceName" =>
        Map.get(config, "voiceName", Map.get(config, "voice_name", Map.get(config, :voice_name))),
      "voice" => Map.get(config, "voice", Map.get(config, :voice))
    }

    selected =
      Synapsis.Provider.Speech.Google.resolve_config(%{"providers" => %{"google" => raw}})

    %{"model" => selected.model, "voice_name" => selected.voice_name}
  end

  defp google_selection(_provider), do: %{}

  defp fish_reference(%{type: "fish_audio_speech", config: config}) do
    raw =
      Enum.reduce(
        [
          {"speakerVoiceId", "speaker_voice_id"},
          {"voiceId", "voice_id"},
          {"referenceId", "reference_id"}
        ],
        %{},
        fn {source, host}, raw ->
          value = Map.get(config || %{}, source, Map.get(config || %{}, host))
          Map.put(raw, source, value)
        end
      )

    Synapsis.Provider.Speech.FishAudio.resolve_talk_overrides(raw)[:reference_id] || ""
  end

  defp fish_reference(_provider), do: ""

  defp fish_voice_label(voice) do
    [voice[:name] || voice.id, voice[:locale], voice[:category]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @impl true
  def render(assigns) do
    model_options =
      Enum.map(assigns.all_models, fn m -> {m.id, m.name} end)

    provider_values =
      react_form_draft(assigns, "edit-provider-form") || provider_form_values(assigns.provider)

    credential_options = [
      {"", "No credential"} | Enum.map(assigns.credentials, &{&1.id, &1.name})
    ]

    selected_id = provider_values["credential_id"]

    credential_options =
      if selected_id not in [nil, ""] and
           not Enum.any?(assigns.credentials, &(&1.id == selected_id)),
         do: credential_options ++ [{selected_id, "Credential unavailable"}],
         else: credential_options

    assigns =
      assign(assigns,
        model_options: model_options,
        credential_options: credential_options,
        provider_values: provider_values
      )

    ~H"""
    <.settings_layout current_path="/settings/providers" content_class="max-w-4xl">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/providers"}>Providers</:crumb>
        <:crumb>{@provider.name}</:crumb>
      </.breadcrumb>

      <h1 class="text-2xl font-bold mb-6">{@provider.name}</h1>

      <%!-- Provider Settings --%>
      <.dm_card variant="bordered" class="mb-6">
        <:title>Settings</:title>
        <.react_form
          for={to_form(%{})}
          id="edit-provider-form"
          values={@provider_values}
          draft={react_form_draft(assigns, "edit-provider-form")}
          structure={[
            @provider.type,
            @provider.credential_id,
            @credential_options,
            oauth_settings?(@provider)
          ]}
          phx-submit="update_provider"
          phx-change="change_provider_form"
          class="space-y-4"
        >
          <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 --%>
          <.readonly_field label="Type" value={@provider.type} />
          <.readonly_field :if={@provider.preset} label="Preset" value={@provider.preset} />

          <.dm_input
            type="text"
            name="base_url"
            value={@provider_values["base_url"]}
            placeholder="https://api.example.com/v1"
            label="Base URL"
          />

          <div :if={not oauth_settings?(@provider)}>
            <.dm_select
              id="provider-credential"
              name="credential_id"
              value={@provider_values["credential_id"]}
              label="Credential"
              options={@credential_options}
            />
            <.link navigate={~p"/settings/credentials"} class="link text-sm">
              Manage Credentials
            </.link>
            <div
              :if={@provider.credential_id not in [nil, ""]}
              class="flex items-center justify-between gap-3 text-xs text-success mt-1"
            >
              <span>
                {if Enum.any?(@credentials, &(&1.id == @provider.credential_id)),
                  do: "Key is set",
                  else: "Credential unavailable"}
              </span>
              <.dm_btn
                id="clear-provider-api-key"
                type="button"
                variant="error"
                size="xs"
                phx-click="clear_api_key"
                confirm="Remove this Provider's credential reference?"
                confirm_title="Clear stored token?"
                confirm_text="Clear token"
              >
                Clear stored token
              </.dm_btn>
            </div>
          </div>

          <.dm_react_field name="enabled" type="checkbox" label="Enabled" />

          <:actions>
            <.dm_btn type="submit" variant="primary">
              Save Changes
            </.dm_btn>
          </:actions>
        </.react_form>
      </.dm_card>

      <.dm_card
        :if={Synapsis.Providers.speech_only?(@provider)}
        variant="bordered"
        class="mb-6"
      >
        <:title>{speech_capability_label(@provider)}</:title>
        <p class="text-sm text-on-surface-variant">
          Use this provider for speech synthesis. Set <code>tts.provider</code>
          to this saved provider name
          in the agent configuration.
        </p>
        <p class="text-sm font-medium mt-3">Provider name</p>
        <code id="speech-provider-reference" class="block text-sm select-all break-all mt-1">
          {@provider.name}
        </code>
      </.dm_card>

      <.dm_card :if={@provider.type == "azure_speech"} variant="bordered" class="mb-6">
        <:title>Azure Speech voice</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Enter a custom voice or refresh the catalog to choose a voice.
        </p>
        <.dm_btn
          id="azure-refresh-voices"
          type="button"
          variant="secondary"
          size="sm"
          phx-click="azure_refresh_voices"
          disabled={@azure_voice_loading}
        >
          Refresh voices
        </.dm_btn>
        <p id="azure-voice-status" role="status" aria-live="polite" class="text-sm mt-3 mb-3">
          {@azure_voice_status}
        </p>
        <.form
          for={to_form(%{})}
          id="azure-speech-form"
          phx-change="azure_selection_change"
          phx-submit="azure_selection_save"
          class="space-y-4"
        >
          <.dm_input
            type="text"
            id="azure-speech-voice"
            name="voice"
            label="Voice"
            value={@azure_selection["voice"]}
            list="azure-speech-voices"
          />
          <datalist id="azure-speech-voices">
            <option :for={voice <- @azure_voices} value={voice.id}>{azure_voice_label(voice)}</option>
          </datalist>
          <.dm_btn id="azure-save-voice" type="submit" variant="primary">Save voice</.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@provider.type == "inworld_speech"} variant="bordered" class="mb-6">
        <:title>Inworld speech</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Enter a model and voice, or refresh the voice catalog for suggestions.
        </p>
        <.dm_btn
          id="inworld-refresh-voices"
          type="button"
          variant="secondary"
          size="sm"
          phx-click="refresh_inworld_voices"
          disabled={@inworld_voice_loading}
        >
          Refresh voices
        </.dm_btn>
        <p id="inworld-voice-status" role="status" aria-live="polite" class="text-sm mt-3 mb-3">
          {@inworld_voice_status}
        </p>
        <.form
          for={to_form(%{})}
          id="inworld-speech-form"
          phx-change="change_inworld_speech"
          phx-submit="save_inworld_speech"
          class="space-y-4"
        >
          <.dm_input
            type="text"
            id="inworld-speech-model"
            name="model_id"
            label="Model"
            value={@inworld_speech_draft["model_id"]}
            list="inworld-speech-models"
          />
          <datalist id="inworld-speech-models">
            <option :for={model <- Synapsis.Provider.Speech.Inworld.models()} value={model} />
          </datalist>
          <.dm_input
            type="text"
            id="inworld-speech-voice"
            name="voice_id"
            label="Voice"
            value={@inworld_speech_draft["voice_id"]}
            list="inworld-speech-voices"
          />
          <datalist id="inworld-speech-voices">
            <option :for={voice <- @inworld_voices} value={voice.id}>
              {inworld_voice_label(voice)}
            </option>
          </datalist>
          <.dm_input
            type="number"
            id="inworld-speech-temperature"
            name="temperature"
            label="Temperature (optional)"
            step="any"
            value={@inworld_speech_draft["temperature"]}
          />
          <.dm_btn id="inworld-save-speech" type="submit" variant="primary">
            Save speech settings
          </.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@provider.type == "elevenlabs"} variant="bordered" class="mb-6">
        <:title>ElevenLabs speech</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Enter a model and voice, or refresh the voice catalog for suggestions.
        </p>
        <.dm_btn
          id="elevenlabs-refresh-voices"
          type="button"
          variant="secondary"
          size="sm"
          phx-click="refresh_elevenlabs_voices"
          disabled={@elevenlabs_voice_loading}
        >
          Refresh voices
        </.dm_btn>
        <p id="elevenlabs-voice-status" role="status" aria-live="polite" class="text-sm mt-3 mb-3">
          {@elevenlabs_voice_status}
        </p>
        <.form
          for={to_form(%{})}
          id="elevenlabs-speech-form"
          phx-change="change_elevenlabs_speech"
          phx-submit="save_elevenlabs_speech"
          class="space-y-4"
        >
          <.dm_input
            type="text"
            id="elevenlabs-speech-model"
            name="model_id"
            label="Model"
            value={@elevenlabs_speech_draft["model_id"]}
            list="elevenlabs-speech-models"
          />
          <datalist id="elevenlabs-speech-models">
            <option :for={model <- Synapsis.Provider.Speech.ElevenLabs.models()} value={model} />
          </datalist>
          <.dm_input
            type="text"
            id="elevenlabs-speech-voice"
            name="voice_id"
            label="Voice"
            value={@elevenlabs_speech_draft["voice_id"]}
            list="elevenlabs-speech-voices"
          />
          <datalist id="elevenlabs-speech-voices">
            <option :for={voice <- @elevenlabs_voices} value={voice.id}>
              {elevenlabs_voice_label(voice)}
            </option>
          </datalist>
          <details
            id="elevenlabs-speech-advanced"
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary class="cursor-pointer font-medium">Advanced speech settings</summary>
            <div class="space-y-4 mt-3">
              <.dm_input
                type="number"
                id="elevenlabs-speech-seed"
                name="seed"
                label="Seed (optional)"
                value={@elevenlabs_speech_draft["seed"]}
              />
              <.dm_input
                type="text"
                id="elevenlabs-speech-normalization"
                name="apply_text_normalization"
                label="Text normalization (optional)"
                placeholder="auto, on, off"
                value={@elevenlabs_speech_draft["apply_text_normalization"]}
              />
              <.dm_input
                type="text"
                id="elevenlabs-speech-language"
                name="language_code"
                label="Language code (optional)"
                value={@elevenlabs_speech_draft["language_code"]}
              />
              <.dm_textarea
                id="elevenlabs-speech-voice-settings"
                name="voice_settings"
                label="Voice settings (JSON)"
                rows={7}
                value={@elevenlabs_speech_draft["voice_settings"]}
              />
            </div>
          </details>
          <.dm_btn id="elevenlabs-save-speech" type="submit" variant="primary">
            Save speech settings
          </.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@provider.type == "openai_speech"} variant="bordered" class="mb-6">
        <:title>OpenAI speech</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Choose a model and voice for speech synthesis.
        </p>
        <.form
          for={to_form(%{})}
          id="openai-speech-form"
          phx-change="openai_speech_selection_change"
          phx-submit="openai_speech_selection_save"
          class="space-y-4"
        >
          <.dm_select
            id="openai-speech-model"
            name="model"
            label="Model"
            value={@openai_speech_selection["model"]}
            options={
              openai_speech_options(
                Synapsis.Provider.Speech.OpenAI.models(),
                @openai_speech_selection["model"],
                openai_speech_custom?(@provider),
                @openai_speech_custom_options["model"]
              )
            }
          />
          <.dm_input
            :if={@openai_speech_selection["model"] == @openai_speech_custom_options["model"]}
            type="text"
            id="openai-speech-custom-model"
            name="custom_model"
            label="Custom model"
            value={@openai_speech_selection["custom_model"] || ""}
          />
          <.dm_select
            id="openai-speech-voice"
            name="voice"
            label="Voice"
            value={@openai_speech_selection["voice"]}
            options={
              openai_speech_options(
                Synapsis.Provider.Speech.OpenAI.voices(),
                @openai_speech_selection["voice"],
                openai_speech_custom?(@provider),
                @openai_speech_custom_options["voice"]
              )
            }
          />
          <.dm_input
            :if={@openai_speech_selection["voice"] == @openai_speech_custom_options["voice"]}
            type="text"
            id="openai-speech-custom-voice"
            name="custom_voice"
            label="Custom voice"
            value={@openai_speech_selection["custom_voice"] || ""}
          />
          <.dm_btn id="openai-save-speech" type="submit" variant="primary">
            Save speech settings
          </.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@provider.type == "clawrouter_speech"} variant="bordered" class="mb-6">
        <:title>ClawRouter voice</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Choose a model and voice for speech synthesis.
        </p>
        <.form
          for={to_form(%{})}
          id="clawrouter-speech-form"
          phx-change="clawrouter_selection_change"
          phx-submit="clawrouter_selection_save"
          class="space-y-4"
        >
          <.dm_select
            id="clawrouter-speech-model"
            name="model"
            label="Model"
            value={@clawrouter_selection["model"]}
            options={Enum.map(Synapsis.Provider.Speech.ClawRouter.models(), &{&1, &1})}
          />
          <.dm_select
            id="clawrouter-speech-voice"
            name="voice"
            label="Voice"
            value={@clawrouter_selection["voice"]}
            options={Enum.map(Synapsis.Provider.Speech.ClawRouter.voices(), &{&1, &1})}
          />
          <.dm_btn id="clawrouter-save-speech" type="submit" variant="primary">
            Save speech settings
          </.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@provider.type == "xiaomi_speech"} variant="bordered" class="mb-6">
        <:title>Xiaomi MiMo voice</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Choose a suggested model and voice or enter a custom value.
        </p>
        <.form
          for={to_form(%{})}
          id="xiaomi-speech-form"
          phx-change="xiaomi_selection_change"
          phx-submit="xiaomi_selection_save"
          class="space-y-4"
        >
          <.dm_input
            type="text"
            id="xiaomi-speech-model"
            name="model"
            label="Model"
            value={@xiaomi_selection["model"]}
            list="xiaomi-speech-models"
          />
          <datalist id="xiaomi-speech-models">
            <option :for={model <- Synapsis.Provider.Speech.Xiaomi.models()} value={model} />
          </datalist>
          <.dm_input
            type="text"
            id="xiaomi-speech-voice"
            name="voice"
            label="Voice"
            value={@xiaomi_selection["voice"]}
            list="xiaomi-speech-voices"
          />
          <datalist id="xiaomi-speech-voices">
            <option :for={voice <- Synapsis.Provider.Speech.Xiaomi.voices()} value={voice} />
          </datalist>
          <.dm_btn id="xiaomi-save-selection" type="submit" variant="primary">
            Save speech settings
          </.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@provider.type == "google_speech"} variant="bordered" class="mb-6">
        <:title>Google Speech voice</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Choose a suggested model and voice or enter a custom value.
        </p>
        <.form
          for={to_form(%{})}
          id="google-speech-form"
          phx-change="google_selection_change"
          phx-submit="google_selection_save"
          class="space-y-4"
        >
          <.dm_input
            type="text"
            id="google-speech-model"
            name="model"
            label="Model"
            value={@google_selection["model"]}
            list="google-speech-models"
          />
          <datalist id="google-speech-models">
            <option :for={model <- Synapsis.Provider.Speech.Google.models()} value={model} />
          </datalist>
          <.dm_input
            type="text"
            id="google-speech-voice"
            name="voice_name"
            label="Voice"
            value={@google_selection["voice_name"]}
            list="google-speech-voices"
          />
          <datalist id="google-speech-voices">
            <option :for={voice <- Synapsis.Provider.Speech.Google.voices()} value={voice} />
          </datalist>
          <.dm_btn id="google-save-selection" type="submit" variant="primary">
            Save speech settings
          </.dm_btn>
        </.form>
      </.dm_card>

      <.dm_card :if={@provider.type == "fish_audio_speech"} variant="bordered" class="mb-6">
        <:title>Fish Audio voice</:title>
        <p class="text-sm text-on-surface-variant mb-3">
          Enter a reference ID or refresh the catalog to choose a voice.
        </p>
        <.dm_btn
          id="fish-refresh-voices"
          type="button"
          variant="secondary"
          size="sm"
          phx-click="fish_refresh_voices"
          disabled={@fish_voice_loading}
        >
          Refresh voices
        </.dm_btn>
        <p id="fish-voice-status" role="status" aria-live="polite" class="text-sm mt-3 mb-3">
          {@fish_voice_status}
        </p>
        <.form for={to_form(%{})} id="fish-voice-form" phx-submit="fish_save_voice" class="space-y-4">
          <.dm_select
            id="fish-voice-select"
            name="voice_id"
            label="Voice catalog"
            value={@fish_reference_id}
            phx-change="fish_select_voice"
            options={[{"", "Choose a voice"} | Enum.map(@fish_voices, &{&1.id, fish_voice_label(&1)})]}
          />
          <.dm_input
            type="text"
            name="reference_id"
            id="fish-reference-id"
            label="Reference ID"
            value={@fish_reference_id}
          />
          <.dm_btn id="fish-save-voice" type="submit" variant="primary">Save voice</.dm_btn>
        </.form>
      </.dm_card>

      <%!-- OAuth Login Section (openai-sub only) --%>
      <.dm_card :if={@provider.name == "openai-sub"} variant="bordered" class="mb-6">
        <:title>OAuth Authentication</:title>

        <%= if Synapsis.Providers.oauth_provider?(@provider) do %>
          <div class="flex items-center gap-3">
            <span class="w-2 h-2 rounded-full bg-success"></span>
            <span class="text-sm text-on-surface">Authenticated via OAuth</span>
            <.dm_btn variant="ghost" size="xs" phx-click="oauth_refresh">
              Refresh Token
            </.dm_btn>
            <.dm_btn variant="ghost" size="xs" phx-click="oauth_start">
              Re-authenticate
            </.dm_btn>
          </div>
        <% else %>
          <%= case @oauth_state do %>
            <% :idle -> %>
              <div class="space-y-3">
                <p class="text-sm text-on-surface-variant">
                  Sign in with your ChatGPT account using the OAuth device flow.
                  This uses the same authentication as OpenAI Codex CLI.
                </p>
                <.dm_btn variant="secondary" phx-click="oauth_start">
                  <.dm_mdi name="login" class="mr-2" /> Sign in with ChatGPT
                </.dm_btn>
              </div>
            <% :waiting_for_user -> %>
              <div class="space-y-4">
                <p class="text-sm text-on-surface-variant">
                  Visit the link below and enter this code:
                </p>
                <div class="flex items-center gap-4">
                  <code class="text-2xl font-mono font-bold tracking-widest bg-surface-container px-4 py-2 rounded-lg select-all">
                    {@oauth_user_code}
                  </code>
                  <.dm_loading_spinner size="sm" />
                </div>
                <div class="text-sm">
                  <a
                    href={@oauth_verification_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="text-primary underline"
                  >
                    {@oauth_verification_url}
                  </a>
                </div>
                <p class="text-xs text-on-surface-variant">
                  Waiting for authorization... This will expire in 15 minutes.
                </p>
                <.dm_btn variant="ghost" size="sm" phx-click="oauth_cancel">
                  Cancel
                </.dm_btn>
              </div>
            <% :authorized -> %>
              <div class="flex items-center gap-3">
                <span class="w-2 h-2 rounded-full bg-success"></span>
                <span class="text-sm text-success">Successfully authenticated!</span>
              </div>
            <% :error -> %>
              <div class="space-y-3">
                <div class="bg-error/10 border border-error/30 rounded-lg px-3 py-2 text-sm text-error">
                  {@oauth_error}
                </div>
                <.dm_btn variant="secondary" size="sm" phx-click="oauth_start">
                  Try Again
                </.dm_btn>
              </div>
          <% end %>
        <% end %>
      </.dm_card>

      <%!-- Models Section --%>
      <.dm_card
        :if={not Synapsis.Providers.speech_only?(@provider)}
        variant="bordered"
        class="mb-6"
      >
        <:title>
          <div class="flex justify-between items-center w-full">
            <span>Models</span>
            <div class="flex items-center gap-2">
              <.dm_btn variant="ghost" size="xs" phx-click="refresh_models">
                Refresh Models
              </.dm_btn>
              <.link navigate={~p"/settings/models"} class="link text-sm">Manage Models</.link>
            </div>
          </div>
        </:title>

        <div :if={@all_models == []} class="text-sm text-on-surface-variant">
          No models loaded. Use Refresh Models to load the provider's model list.
        </div>

        <div :for={model <- @all_models} class="flex items-center gap-2 py-1">
          <span class="text-sm">{model.name}</span>
          <code class="text-xs text-on-surface-variant">{model.id}</code>
        </div>
        <p class="text-xs text-on-surface-variant mt-3">
          These are discovery suggestions. Import models in Manage Models to make them available to agents and sessions.
        </p>
      </.dm_card>

      <%!-- Test Chat Section --%>
      <.dm_card :if={not Synapsis.Providers.speech_only?(@provider)} variant="bordered">
        <:title>
          <div class="flex justify-between items-center w-full cursor-pointer" phx-click="toggle_chat">
            <span class="text-lg font-semibold">Test Chat</span>
            <.dm_mdi
              name={if @chat_open, do: "chevron-up", else: "chevron-down"}
              class="text-on-surface-variant"
            />
          </div>
        </:title>
        <div :if={@chat_open} class="space-y-4">
          <%!-- Model selector --%>
          <div :if={@all_models != []} class="flex items-center gap-3">
            <.react_form
              for={to_form(%{})}
              id="provider-chat-model-form"
              values={%{"model" => @chat_model}}
              draft={react_form_draft(assigns, "provider-chat-model-form")}
              structure={@model_options}
              phx-change="chat_select_model"
              class="flex-1"
            >
              <.dm_react_field
                name="model"
                type="select"
                label="Model"
                options={
                  Enum.map(@model_options, fn {value, label} -> %{value: value, label: label} end)
                }
              />
            </.react_form>
            <.dm_btn
              :if={@chat_messages != []}
              variant="ghost"
              size="xs"
              phx-click="chat_clear"
            >
              Clear
            </.dm_btn>
          </div>

          <.dm_react_chat
            id={"provider-chat-#{@provider.id}"}
            conversation_id={@provider.id}
            hook="SynapsisReactChat"
            label="Provider test chat"
            messages={@react_chat_initial.messages}
            metadata={@react_chat_initial.metadata}
            runtime={@react_chat_initial.runtime}
            admission={@react_chat_initial.admission}
            class="synapsis-react-chat h-[420px] min-h-0"
          />
        </div>
      </.dm_card>
    </.settings_layout>
    """
  end

  defp speech_capability_label(provider) do
    provider
    |> Synapsis.Providers.speech_capabilities()
    |> Enum.map_join(", ", fn
      :tts -> "Text to speech"
      :stt -> "Speech to text"
    end)
  end
end
