defmodule SynapsisWeb.ProviderLive.Show do
  use SynapsisWeb, :live_view
  use SynapsisWeb.ReactFormEvents
  require Logger

  alias SynapsisWeb.ChatBridge

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Synapsis.Providers.get(id) do
      {:ok, provider} ->
        all_models = fetch_models(provider)
        enabled = Synapsis.Providers.enabled_models(provider)
        default_model = if all_models != [], do: hd(all_models).id, else: nil

        {:ok,
         assign(socket,
           provider: provider,
           page_title: provider.name,
           all_models: all_models,
           enabled_models: enabled,
           editing_models: false,
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
        if params["api_key"] && params["api_key"] != "",
          do: Map.put(attrs, :api_key_encrypted, params["api_key"]),
          else: attrs
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

  def handle_event("toggle_edit_models", _params, socket) do
    {:noreply,
     socket
     |> reset_react_form("provider-models-form", %{
       "models" => selected_model_ids(socket.assigns.all_models, socket.assigns.enabled_models)
     })
     |> assign(editing_models: !socket.assigns.editing_models)}
  end

  def handle_event("save_models", params, socket) do
    selected = (params["models"] || []) |> Enum.reject(&(&1 == ""))
    provider = socket.assigns.provider
    config = Map.merge(provider.config || %{}, %{"enabled_models" => selected})

    case Synapsis.Providers.update(provider.id, %{config: config}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(
           provider: updated,
           enabled_models: Synapsis.Providers.enabled_models(updated),
           editing_models: false
         )
         |> reset_react_form("provider-models-form")
         |> put_flash(:info, "Models updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update models")}
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
           enabled_models: Synapsis.Providers.enabled_models(provider),
           chat_model: default_chat_model(all_models, socket.assigns.chat_model)
         )
         |> reset_react_form("provider-models-form", %{
           "models" => selected_model_ids(all_models, Synapsis.Providers.enabled_models(provider))
         })
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

  defp model_enabled?(model_id, enabled_models) do
    enabled_models == [] or model_id in enabled_models
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
    %{"base_url" => provider.base_url, "api_key" => "", "enabled" => provider.enabled}
  end

  defp selected_model_ids(models, enabled_models) do
    models
    |> Enum.filter(&model_enabled?(&1.id, enabled_models))
    |> Enum.map(& &1.id)
  end

  @impl true
  def render(assigns) do
    model_options =
      Enum.map(assigns.all_models, fn m -> {m.id, m.name} end)

    assigns = assign(assigns, model_options: model_options)

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
          values={provider_form_values(@provider)}
          draft={react_form_draft(assigns, "edit-provider-form")}
          structure={[
            @provider.type,
            @provider.api_key_encrypted not in [nil, ""],
            Synapsis.Providers.oauth_provider?(@provider)
          ]}
          phx-submit="update_provider"
          phx-change="change_provider_form"
          class="space-y-4"
        >
          <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#191 --%>
          <.readonly_field label="Type" value={@provider.type} />

          <.dm_input
            type="text"
            name="base_url"
            value={@provider.base_url}
            placeholder="https://api.example.com/v1"
            label="Base URL"
          />

          <div>
            <.dm_input
              type="password"
              name="api_key"
              value=""
              placeholder="Leave empty to keep current key"
              label="API Key"
            />
            <div
              :if={
                @provider.api_key_encrypted not in [nil, ""] and
                  not Synapsis.Providers.oauth_provider?(@provider)
              }
              class="flex items-center justify-between gap-3 text-xs text-success mt-1"
            >
              <span>Key is set</span>
              <.dm_btn
                id="clear-provider-api-key"
                type="button"
                variant="error"
                size="xs"
                phx-click="clear_api_key"
                confirm="Clear the stored access token?"
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
      <.dm_card variant="bordered" class="mb-6">
        <:title>
          <div class="flex justify-between items-center w-full">
            <span>Models</span>
            <div class="flex items-center gap-2">
              <.dm_btn variant="ghost" size="xs" phx-click="refresh_models">
                Refresh Models
              </.dm_btn>
              <.dm_btn variant="ghost" size="xs" phx-click="toggle_edit_models">
                {if @editing_models, do: "Cancel", else: "Edit"}
              </.dm_btn>
            </div>
          </div>
        </:title>

        <div :if={@all_models == []} class="text-sm text-on-surface-variant">
          No models loaded. Use Refresh Models to load the provider's model list.
        </div>

        <%= if @all_models != [] && @editing_models do %>
          <.react_form
            for={to_form(%{})}
            id="provider-models-form"
            values={%{"models" => selected_model_ids(@all_models, @enabled_models)}}
            draft={react_form_draft(assigns, "provider-models-form")}
            structure={Enum.map(@all_models, & &1.id)}
            phx-submit="save_models"
          >
            <%!-- # WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#192 --%>
            <input type="hidden" name="models[]" value="" />
            <div class="space-y-2">
              <div :for={model <- @all_models} class="flex items-center gap-3">
                <label class="flex items-center gap-2 text-sm" for={"model-#{model.id}"}>
                  <input
                    type="checkbox"
                    name="models[]"
                    value={model.id}
                    checked={model_enabled?(model.id, @enabled_models)}
                    id={"model-#{model.id}"}
                    class="h-4 w-4 rounded border-outline text-primary focus:ring-primary"
                  />
                  <span>{model.name}</span>
                </label>
                <span class="text-xs text-on-surface-variant">{model.id}</span>
              </div>
            </div>
            <:actions>
              <div class="flex gap-2">
                <.dm_btn type="submit" variant="secondary" size="sm">
                  Save Models
                </.dm_btn>
                <.dm_btn type="button" variant="ghost" size="sm" phx-click="toggle_edit_models">
                  Cancel
                </.dm_btn>
              </div>
            </:actions>
          </.react_form>
        <% end %>

        <%= if @all_models != [] && !@editing_models do %>
          <div class="space-y-1">
            <div :for={model <- @all_models} class="flex items-center gap-2 py-1">
              <%= if model_enabled?(model.id, @enabled_models) do %>
                <span class="w-2 h-2 rounded-full bg-success"></span>
                <span class="text-sm">{model.name}</span>
                <span class="text-xs text-on-surface-variant">{model.id}</span>
              <% else %>
                <span class="w-2 h-2 rounded-full bg-on-surface/20"></span>
                <span class="text-sm text-on-surface-variant">{model.name}</span>
                <span class="text-xs text-on-surface-variant/50">{model.id}</span>
              <% end %>
            </div>
          </div>
          <div :if={@enabled_models == []} class="text-xs text-on-surface-variant mt-3">
            All models enabled (no filter set)
          </div>
        <% end %>
      </.dm_card>

      <%!-- Test Chat Section --%>
      <.dm_card variant="bordered">
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
end
