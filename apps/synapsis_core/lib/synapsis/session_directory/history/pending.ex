defmodule Synapsis.SessionDirectory.History.Pending do
  @moduledoc false
  alias Synapsis.SessionDirectory.History.DTO

  # Positions belong to the original stored append order, before any filtering.
  def page(entries, input) do
    eligible =
      entries
      |> Enum.with_index(1)
      |> Enum.reject(fn {entry, _} ->
        field(entry, :status) == "consumed" or
          (field(entry, :kind) == "system_event" and is_map(field(entry, :event)) and
             not is_nil(field(field(entry, :event), :run_id)))
      end)

    before = input["pending_before"]

    remaining =
      eligible
      |> Enum.reverse()
      |> Enum.filter(fn {_, position} ->
        is_nil(before) or position < before
      end)

    selected = Enum.take(remaining, min(Map.get(input, "limit", 200), 20))

    page = %{
      "items" => Enum.map(selected, fn {entry, _} -> item(entry) end),
      "total" => length(eligible)
    }

    if length(remaining) > length(selected),
      do: Map.put(page, "nextBefore", selected |> List.last() |> elem(1)),
      else: page
  end

  defp item(entry) do
    %{
      "id" => field(entry, :id),
      "state" => field(entry, :status),
      "kind" => field(entry, :kind),
      "acceptedAt" => timestamp(field(entry, :inserted_at)),
      "message" => DTO.pending_message(entry)
    }
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(value), do: value
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
