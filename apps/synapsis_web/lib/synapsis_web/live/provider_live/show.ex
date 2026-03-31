defmodule SynapsisWeb.ProviderLive.Show do
  use SynapsisWeb, :live_view
  require Logger

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
           # OAuth device flow state
           oauth_state: :idle,
           oauth_user_code: nil,
           oauth_verification_url: nil,
           oauth_device_auth_id: nil,
           oauth_error: nil,
           oauth_poll_timer: nil
         )}

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
         |> put_flash(:info, "Provider updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update provider")}
    end
  end

  def handle_event("toggle_edit_models", _params, socket) do
    {:noreply, assign(socket, editing_models: !socket.assigns.editing_models)}
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
         |> put_flash(:info, "Models updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update models")}
    end
  end

  # -- Test Chat Events --

  def handle_event("toggle_chat", _params, socket) do
    {:noreply, assign(socket, chat_open: !socket.assigns.chat_open)}
  end

  def handle_event("chat_select_model", %{"model" => model}, socket) do
    {:noreply, assign(socket, chat_model: model)}
  end

  def handle_event("chat_send", %{"message" => message}, socket) when message != "" do
    provider = socket.assigns.provider
    model = socket.assigns.chat_model

    messages =
      socket.assigns.chat_messages ++ [%{role: "user", content: message}]

    case Synapsis.Provider.Registry.get(provider.name) do
      {:ok, config} ->
        request = build_chat_request(config, model, messages)

        {:ok, ref} = Synapsis.Provider.Adapter.stream(request, config)

        {:noreply,
         assign(socket,
           chat_messages: messages,
           chat_streaming: true,
           chat_stream_text: "",
           chat_stream_ref: ref
         )}

      {:error, _} ->
        {:noreply,
         assign(socket,
           chat_messages:
             messages ++
               [%{role: "error", content: "Provider not registered. Save and enable it first."}]
         )}
    end
  end

  def handle_event("chat_send", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("chat_clear", _params, socket) do
    {:noreply, assign(socket, chat_messages: [], chat_stream_text: "", chat_streaming: false)}
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
  def handle_info({:provider_chunk, {:text_delta, text}}, socket) do
    {:noreply, assign(socket, chat_stream_text: socket.assigns.chat_stream_text <> text)}
  end

  def handle_info({:provider_chunk, _other_event}, socket) do
    # Ignore non-text events (reasoning, tool_use, etc.)
    {:noreply, socket}
  end

  def handle_info(:provider_done, socket) do
    messages =
      socket.assigns.chat_messages ++
        [%{role: "assistant", content: socket.assigns.chat_stream_text}]

    {:noreply,
     assign(socket,
       chat_messages: messages,
       chat_streaming: false,
       chat_stream_text: "",
       chat_stream_ref: nil
     )}
  end

  def handle_info({:provider_error, reason}, socket) do
    messages =
      socket.assigns.chat_messages ++ [%{role: "error", content: "Error: #{reason}"}]

    {:noreply,
     assign(socket,
       chat_messages: messages,
       chat_streaming: false,
       chat_stream_text: "",
       chat_stream_ref: nil
     )}
  end

  # Task completion messages
  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
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
    if timer = socket.assigns[:oauth_poll_timer] do
      Process.cancel_timer(timer)
    end

    :ok
  end

  # -- Private helpers --

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

  @impl true
  def render(assigns) do
    model_options =
      Enum.map(assigns.all_models, fn m -> {m.id, m.name} end)

    assigns = assign(assigns, model_options: model_options)

    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.breadcrumb class="mb-4">
        <:crumb to={~p"/settings"}>Settings</:crumb>
        <:crumb to={~p"/settings/providers"}>Providers</:crumb>
        <:crumb>{@provider.name}</:crumb>
      </.breadcrumb>

      <h1 class="text-2xl font-bold mb-6">{@provider.name}</h1>

      <%!-- Provider Settings --%>
      <.dm_card variant="bordered" class="mb-6">
        <:title>Settings</:title>
        <.dm_form for={to_form(%{})} phx-submit="update_provider" class="space-y-4">
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
            <div :if={@provider.api_key_encrypted} class="text-xs text-success mt-1">
              Key is set
            </div>
          </div>

          <div>
            <input type="hidden" name="enabled" value="false" />
            <.dm_switch
              name="enabled"
              value="true"
              checked={@provider.enabled}
              label="Enabled"
              color="success"
            />
          </div>

          <:actions>
            <.dm_btn type="submit" variant="primary">
              Save Changes
            </.dm_btn>
          </:actions>
        </.dm_form>
      </.dm_card>

      <%!-- OAuth Login Section (openai-sub only) --%>
      <.dm_card :if={@provider.name == "openai-sub"} variant="bordered" class="mb-6">
        <:title>OAuth Authentication</:title>

        <%= if Synapsis.Providers.oauth_provider?(@provider) do %>
          <div class="flex items-center gap-3">
            <span class="w-2 h-2 rounded-full bg-success"></span>
            <span class="text-sm text-base-content">Authenticated via OAuth</span>
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
                <p class="text-sm text-base-content/70">
                  Sign in with your ChatGPT account using the OAuth device flow.
                  This uses the same authentication as OpenAI Codex CLI.
                </p>
                <.dm_btn variant="primary" phx-click="oauth_start">
                  <.dm_mdi name="login" class="mr-2" /> Sign in with ChatGPT
                </.dm_btn>
              </div>
            <% :waiting_for_user -> %>
              <div class="space-y-4">
                <p class="text-sm text-base-content/70">
                  Visit the link below and enter this code:
                </p>
                <div class="flex items-center gap-4">
                  <code class="text-2xl font-mono font-bold tracking-widest bg-base-200 px-4 py-2 rounded-lg select-all">
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
                <p class="text-xs text-base-content/50">
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
                <.dm_btn variant="primary" size="sm" phx-click="oauth_start">
                  Try Again
                </.dm_btn>
              </div>
          <% end %>
        <% end %>
      </.dm_card>

      <%!-- Models Section --%>
      <.dm_card :if={@all_models != []} variant="bordered" class="mb-6">
        <:title>
          <div class="flex justify-between items-center w-full">
            <span>Models</span>
            <.dm_btn variant="ghost" size="xs" phx-click="toggle_edit_models">
              {if @editing_models, do: "Cancel", else: "Edit"}
            </.dm_btn>
          </div>
        </:title>

        <%= if @editing_models do %>
          <.dm_form for={to_form(%{})} phx-submit="save_models">
            <input type="hidden" name="models[]" value="" />
            <div class="space-y-2">
              <div :for={model <- @all_models} class="flex items-center gap-3">
                <label class="flex items-center gap-2 text-sm leading-6">
                  <input
                    type="checkbox"
                    name="models[]"
                    value={model.id}
                    checked={model_enabled?(model.id, @enabled_models)}
                    class="checkbox"
                    id={"model-#{model.id}"}
                  />
                  {model.name}
                </label>
                <span class="text-xs text-base-content/40">{model.id}</span>
              </div>
            </div>
            <:actions>
              <div class="flex gap-2">
                <.dm_btn type="submit" variant="primary" size="sm">
                  Save Models
                </.dm_btn>
                <.dm_btn type="button" variant="ghost" size="sm" phx-click="toggle_edit_models">
                  Cancel
                </.dm_btn>
              </div>
            </:actions>
          </.dm_form>
        <% else %>
          <div class="space-y-1">
            <div :for={model <- @all_models} class="flex items-center gap-2 py-1">
              <%= if model_enabled?(model.id, @enabled_models) do %>
                <span class="w-2 h-2 rounded-full bg-success"></span>
                <span class="text-sm">{model.name}</span>
                <span class="text-xs text-base-content/40">{model.id}</span>
              <% else %>
                <span class="w-2 h-2 rounded-full bg-base-content/20"></span>
                <span class="text-sm text-base-content/50">{model.name}</span>
                <span class="text-xs text-base-content/30">{model.id}</span>
              <% end %>
            </div>
          </div>
          <div :if={@enabled_models == []} class="text-xs text-base-content/50 mt-3">
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
              class="text-base-content/50"
            />
          </div>
        </:title>
        <div :if={@chat_open} class="space-y-4">
          <%!-- Model selector --%>
          <div :if={@all_models != []} class="flex items-center gap-3">
            <.dm_form for={to_form(%{})} phx-change="chat_select_model" class="flex-1">
              <.dm_select
                name="model"
                label="Model"
                options={@model_options}
                value={@chat_model}
              />
            </.dm_form>
            <.dm_btn
              :if={@chat_messages != []}
              variant="ghost"
              size="xs"
              phx-click="chat_clear"
            >
              Clear
            </.dm_btn>
          </div>

          <%!-- Messages --%>
          <div
            class="bg-base-100 rounded-lg border border-base-300 p-3 min-h-[120px] max-h-[400px] overflow-y-auto space-y-3"
            id="chat-messages"
            phx-hook="ScrollBottom"
          >
            <div :if={@chat_messages == [] && !@chat_streaming} class="text-base-content/40 text-sm">
              Send a message to test this provider...
            </div>

            <div :for={msg <- @chat_messages}>
              <%= case msg.role do %>
                <% "user" -> %>
                  <.chat_bubble role="user">{msg.content}</.chat_bubble>
                <% "assistant" -> %>
                  <.chat_bubble role="assistant">{msg.content}</.chat_bubble>
                <% "error" -> %>
                  <div class="flex justify-start">
                    <div class="bg-error/20 border border-error/30 rounded-lg px-3 py-2 max-w-[80%] text-sm text-error">
                      {msg.content}
                    </div>
                  </div>
                <% _ -> %>
              <% end %>
            </div>

            <%!-- Streaming indicator --%>
            <div :if={@chat_streaming}>
              <.chat_bubble role="assistant">
                <span :if={@chat_stream_text != ""}>{@chat_stream_text}</span>
                <.dm_loading_spinner size="xs" class="inline-block ml-1" />
              </.chat_bubble>
            </div>
          </div>

          <%!-- Input --%>
          <.dm_form for={to_form(%{})} phx-submit="chat_send" class="flex gap-2">
            <.dm_input
              type="text"
              name="message"
              value=""
              placeholder="Type a test message..."
              autocomplete="off"
              disabled={@chat_streaming}
              class="flex-1"
            />
            <.dm_btn type="submit" variant="primary" size="sm" disabled={@chat_streaming}>
              Send
            </.dm_btn>
          </.dm_form>
        </div>
      </.dm_card>
    </div>
    """
  end
end
