defmodule SynapsisWeb.ReactFormHelpers do
  @moduledoc false
  import Phoenix.LiveViewTest

  def react_form_submit(view, id, changes), do: send_form(view, id, changes, "phx-submit")
  def react_form_change(view, id, changes), do: send_form(view, id, changes, "phx-change")

  defp send_form(view, id, changes, event_attr) do
    html = view |> element(~s([data-form-id="#{id}"])) |> render() |> LazyHTML.from_fragment()
    [mount_id] = html |> LazyHTML.query("[data-form-id]") |> LazyHTML.attribute("id")
    [event] = html |> LazyHTML.query("[data-form-id]") |> LazyHTML.attribute(event_attr)

    initial =
      html
      |> LazyHTML.query("[data-form-id]")
      |> LazyHTML.attribute("data-initial-values")
      |> hd()
      |> Jason.decode!()

    native = native_values(html)
    values = native |> merge(initial) |> merge(changes)

    render_hook(view, event, %{
      "id" => mount_id,
      "values" => values,
      "revision" => System.unique_integer([:positive, :monotonic])
    })
  end

  defp native_values(html) do
    html
    |> LazyHTML.query("input[name], textarea[name], select[name]")
    |> LazyHTML.to_tree()
    |> Enum.flat_map(fn {tag, attrs, children} ->
      attrs = Map.new(attrs)
      name = attrs["name"]
      type = attrs["type"]

      cond do
        Map.has_key?(attrs, "disabled") ->
          []

        type in ["checkbox", "radio"] and not Map.has_key?(attrs, "checked") ->
          []

        type in ["submit", "button", "reset", "file"] ->
          []

        tag == "textarea" ->
          [{name, children |> LazyHTML.from_tree() |> LazyHTML.text()}]

        tag == "select" ->
          options =
            children |> LazyHTML.from_tree() |> LazyHTML.query("option") |> LazyHTML.to_tree()

          selected = Enum.filter(options, fn {_, a, _} -> List.keymember?(a, "selected", 0) end)

          selected =
            if selected == [] and not Map.has_key?(attrs, "multiple"),
              do: Enum.take(options, 1),
              else: selected

          Enum.map(selected, fn {_, a, c} ->
            {name, Map.new(a)["value"] || c |> LazyHTML.from_tree() |> LazyHTML.text()}
          end)

        true ->
          [{name, attrs["value"] || ""}]
      end
    end)
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
  end

  defp merge(left, right),
    do:
      Map.merge(left, right, fn _key, old, new ->
        if is_map(old) and is_map(new), do: merge(old, new), else: new
      end)
end
