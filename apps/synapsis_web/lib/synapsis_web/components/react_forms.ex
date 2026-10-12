defmodule SynapsisWeb.ReactForms do
  @moduledoc "Presentation helpers for the published DuskMoon React Form bridge."
  use Phoenix.Component

  import PhoenixDuskmoon.Component.DataEntry.ReactForm, only: [dm_react_form: 1]

  attr :id, :string, required: true
  attr :for, :any, default: %{}
  attr :as, :any, default: nil
  attr :values, :map, default: nil
  attr :draft, :map, default: nil
  attr :structure, :any, default: nil
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(autocomplete name novalidate phx-change phx-submit phx-target phx-debounce)

  slot :inner_block
  slot :actions

  def react_form(assigns) do
    assigns =
      assigns
      |> assign(:mount_id, form_mount_id(assigns.id, assigns.structure))
      |> assign(
        :initial_values,
        assigns.draft || assigns.values || form_values(assigns.for, assigns.as)
      )

    ~H"""
    <%!-- Key structural mounts so LiveView sends unchanged nested components in full. --%>
    <.dm_react_form
      :for={mount_id <- [@mount_id]}
      :key={mount_id}
      id={mount_id}
      values={@initial_values}
      class={["synapsis-react-form", @class]}
      data-form-id={@id}
      {@rest}
    >
      {render_slot(@inner_block)}
      <div :if={@actions != []} class="flex items-center gap-2 mt-4">
        {render_slot(@actions)}
      </div>
    </.dm_react_form>
    """
  end

  def form_mount_id(id, nil), do: id
  def form_mount_id(id, structure), do: "#{id}--#{:erlang.phash2(structure)}"

  def react_form_draft(assigns, id), do: Map.get(assigns.react_form_drafts, id)

  def reset_react_form(socket, id, values \\ nil) do
    mount_id = Map.get(socket.assigns.react_form_mounts, id, id)

    drafts =
      if is_nil(values),
        do: Map.delete(socket.assigns.react_form_drafts, id),
        else: Map.put(socket.assigns.react_form_drafts, id, values)

    socket
    |> Phoenix.Component.assign(:react_form_drafts, drafts)
    |> Phoenix.LiveView.push_event("dm:form:reset", %{id: mount_id, form_id: id, values: values})
  end

  defp form_values(%Phoenix.HTML.Form{params: params, name: name}, as) do
    named_values(params, as || name)
  end

  defp form_values(params, as) when is_map(params), do: named_values(params, as)
  defp named_values(params, nil), do: params
  defp named_values(params, ""), do: params
  defp named_values(params, name), do: %{to_string(name) => params}
end
