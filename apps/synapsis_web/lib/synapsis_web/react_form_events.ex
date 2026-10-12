defmodule SynapsisWeb.ReactFormEvents do
  @moduledoc "Adapts typed React Form events to existing LiveView business handlers."

  defmacro __using__(_opts) do
    quote do
      on_mount SynapsisWeb.ReactFormEvents

      @impl true
      def handle_event(event, %{"id" => id, "values" => values, "revision" => revision}, socket)
          when is_binary(id) and is_map(values) and is_integer(revision) do
        SynapsisWeb.ReactFormEvents.dispatch(__MODULE__, event, id, values, revision, socket)
      end
    end
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.Component.assign(socket,
       react_form_drafts: %{},
       react_form_mounts: %{}
     )}
  end

  def dispatch(module, event, id, values, _revision, socket) do
    [form_id | _] = String.split(id, "--", parts: 2)

    socket =
      socket
      |> Phoenix.Component.assign(
        react_form_drafts: Map.put(socket.assigns.react_form_drafts, form_id, values),
        react_form_mounts: Map.put(socket.assigns.react_form_mounts, form_id, id)
      )
      |> Phoenix.LiveView.clear_flash(:error)

    case module.handle_event(event, html_params(values), socket) do
      {:noreply, socket} -> {:reply, reply(socket), socket}
      {:reply, response, socket} -> {:reply, Map.merge(reply(socket), response), socket}
    end
  end

  # Existing handlers parse the HTML-form string contract. Preserve lists and
  # nesting while React keeps typed drafts and server validation stays unchanged.
  defp html_params(values) when is_map(values),
    do: Map.new(values, fn {key, value} -> {key, html_params(value)} end)

  defp html_params(values) when is_list(values), do: Enum.map(values, &html_params/1)
  defp html_params(nil), do: ""
  defp html_params(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp html_params(value), do: value

  defp reply(socket) do
    case Phoenix.Flash.get(socket.assigns.flash, :error) do
      nil -> %{status: "ok"}
      message -> %{status: "error", message: message, errors: %{"_form" => [message]}}
    end
  end
end
