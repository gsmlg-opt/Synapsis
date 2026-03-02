defmodule SynapsisWeb.ProviderLive.Show do
  use SynapsisWeb, :live_view

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
           chat_stream_ref: nil
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
    selected = params["models"] || []
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

  # -- Private helpers --

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
    ~H"""
    <div class="min-h-screen bg-gray-950 text-gray-100">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center gap-2 text-sm text-gray-500 mb-4">
          <.link navigate={~p"/settings"} class="hover:text-gray-300">Settings</.link>
          <span>/</span>
          <.link navigate={~p"/settings/providers"} class="hover:text-gray-300">Providers</.link>
          <span>/</span>
          <span class="text-gray-300">{@provider.name}</span>
        </div>

        <h1 class="text-2xl font-bold mb-6">{@provider.name}</h1>

        <.flash_group flash={@flash} />

        <%!-- Provider Settings --%>
        <div class="bg-gray-900 rounded-lg p-6 border border-gray-800 mb-6">
          <form phx-submit="update_provider" class="space-y-4">
            <div>
              <label class="block text-sm text-gray-400 mb-1">Type</label>
              <div class="text-gray-200">{@provider.type}</div>
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">Base URL</label>
              <input
                type="text"
                name="base_url"
                value={@provider.base_url}
                placeholder="https://api.example.com/v1"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
            </div>

            <div>
              <label class="block text-sm text-gray-400 mb-1">API Key</label>
              <input
                type="password"
                name="api_key"
                placeholder="Leave empty to keep current key"
                class="w-full bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none"
              />
              <div :if={@provider.api_key_encrypted} class="text-xs text-green-500 mt-1">
                Key is set
              </div>
            </div>

            <div>
              <label class="flex items-center gap-2">
                <input type="hidden" name="enabled" value="false" />
                <input
                  type="checkbox"
                  name="enabled"
                  value="true"
                  checked={@provider.enabled}
                  class="rounded bg-gray-800 border-gray-700"
                />
                <span class="text-sm">Enabled</span>
              </label>
            </div>

            <button
              type="submit"
              class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700"
            >
              Save Changes
            </button>
          </form>
        </div>

        <%!-- Models Section --%>
        <div :if={@all_models != []} class="bg-gray-900 rounded-lg p-6 border border-gray-800 mb-6">
          <div class="flex justify-between items-center mb-4">
            <h2 class="text-lg font-semibold">Models</h2>
            <button
              phx-click="toggle_edit_models"
              class="text-sm text-blue-400 hover:text-blue-300"
            >
              {if @editing_models, do: "Cancel", else: "Edit"}
            </button>
          </div>

          <%= if @editing_models do %>
            <form phx-submit="save_models">
              <div class="space-y-2">
                <div :for={model <- @all_models} class="flex items-center gap-3">
                  <input
                    type="checkbox"
                    name="models[]"
                    value={model.id}
                    checked={model_enabled?(model.id, @enabled_models)}
                    class="rounded bg-gray-800 border-gray-700 text-blue-500"
                    id={"model-#{model.id}"}
                  />
                  <label for={"model-#{model.id}"} class="flex-1 flex items-center gap-2">
                    <span class="text-sm">{model.name}</span>
                    <span class="text-xs text-gray-600">{model.id}</span>
                  </label>
                </div>
              </div>
              <div class="mt-4 flex gap-2">
                <button
                  type="submit"
                  class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 text-sm"
                >
                  Save Models
                </button>
                <button
                  type="button"
                  phx-click="toggle_edit_models"
                  class="px-4 py-2 bg-gray-700 text-gray-300 rounded hover:bg-gray-600 text-sm"
                >
                  Cancel
                </button>
              </div>
            </form>
          <% else %>
            <div class="space-y-1">
              <div :for={model <- @all_models} class="flex items-center gap-2 py-1">
                <%= if model_enabled?(model.id, @enabled_models) do %>
                  <span class="w-2 h-2 rounded-full bg-green-500"></span>
                  <span class="text-sm">{model.name}</span>
                  <span class="text-xs text-gray-600">{model.id}</span>
                <% else %>
                  <span class="w-2 h-2 rounded-full bg-gray-700"></span>
                  <span class="text-sm text-gray-500">{model.name}</span>
                  <span class="text-xs text-gray-700">{model.id}</span>
                <% end %>
              </div>
            </div>
            <div :if={@enabled_models == []} class="text-xs text-gray-500 mt-3">
              All models enabled (no filter set)
            </div>
          <% end %>
        </div>

        <%!-- Test Chat Section --%>
        <div class="bg-gray-900 rounded-lg border border-gray-800">
          <button
            phx-click="toggle_chat"
            class="w-full flex justify-between items-center p-4 text-left hover:bg-gray-800/50 rounded-lg transition-colors"
          >
            <h2 class="text-lg font-semibold">Test Chat</h2>
            <span class="text-gray-500 text-sm">
              {if @chat_open, do: "Close", else: "Open"}
            </span>
          </button>

          <div :if={@chat_open} class="px-4 pb-4 space-y-4">
            <%!-- Model selector --%>
            <div :if={@all_models != []} class="flex items-center gap-3">
              <label class="text-xs text-gray-400">Model</label>
              <form phx-change="chat_select_model" class="flex-1">
                <select
                  name="model"
                  class="w-full bg-gray-800 border border-gray-700 rounded px-2 py-1.5 text-sm text-gray-200"
                >
                  <option
                    :for={m <- @all_models}
                    value={m.id}
                    selected={m.id == @chat_model}
                  >
                    {m.name}
                  </option>
                </select>
              </form>
              <button
                :if={@chat_messages != []}
                phx-click="chat_clear"
                class="text-xs text-gray-500 hover:text-gray-300"
              >
                Clear
              </button>
            </div>

            <%!-- Messages --%>
            <div
              class="bg-gray-950 rounded-lg border border-gray-800 p-3 min-h-[120px] max-h-[400px] overflow-y-auto space-y-3"
              id="chat-messages"
              phx-hook="ScrollBottom"
            >
              <div :if={@chat_messages == [] && !@chat_streaming} class="text-gray-600 text-sm">
                Send a message to test this provider...
              </div>

              <div :for={msg <- @chat_messages}>
                <%= case msg.role do %>
                  <% "user" -> %>
                    <div class="flex justify-end">
                      <div class="bg-blue-900/40 rounded-lg px-3 py-2 max-w-[80%] text-sm">
                        {msg.content}
                      </div>
                    </div>
                  <% "assistant" -> %>
                    <div class="flex justify-start">
                      <div class="bg-gray-800 rounded-lg px-3 py-2 max-w-[80%] text-sm whitespace-pre-wrap">
                        {msg.content}
                      </div>
                    </div>
                  <% "error" -> %>
                    <div class="flex justify-start">
                      <div class="bg-red-900/30 border border-red-800 rounded-lg px-3 py-2 max-w-[80%] text-sm text-red-300">
                        {msg.content}
                      </div>
                    </div>
                  <% _ -> %>
                <% end %>
              </div>

              <%!-- Streaming indicator --%>
              <div :if={@chat_streaming} class="flex justify-start">
                <div class="bg-gray-800 rounded-lg px-3 py-2 max-w-[80%] text-sm whitespace-pre-wrap">
                  <span :if={@chat_stream_text != ""}>{@chat_stream_text}</span>
                  <span class="inline-block w-2 h-4 bg-gray-400 animate-pulse ml-0.5"></span>
                </div>
              </div>
            </div>

            <%!-- Input --%>
            <form phx-submit="chat_send" class="flex gap-2">
              <input
                type="text"
                name="message"
                placeholder="Type a test message..."
                autocomplete="off"
                disabled={@chat_streaming}
                class="flex-1 bg-gray-800 text-gray-100 rounded px-3 py-2 border border-gray-700 focus:border-blue-500 focus:outline-none disabled:opacity-50"
              />
              <button
                type="submit"
                disabled={@chat_streaming}
                class="px-4 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50 text-sm"
              >
                Send
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
