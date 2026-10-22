defmodule Synapsis.Models do
  @moduledoc "Data-only CRUD and non-destructive import for the configured model catalog."
  alias Synapsis.{Config.Store, ModelConfig}

  def list(opts \\ []) do
    records =
      Store.list(:model)
      |> Enum.map(&to_struct/1)
      |> Enum.filter(fn record ->
        Enum.all?(opts, fn {key, value} -> Map.get(record, key) == value end)
      end)
      |> Enum.sort_by(&{&1.provider_id, &1.model})

    {:ok, records}
  end

  def get(id) do
    case Store.get(:model, id) do
      {:ok, attrs} -> {:ok, to_struct(attrs)}
      error -> error
    end
  end

  def get_by_identity(provider_id, model) do
    {:ok, records} = list(provider_id: provider_id, model: model)

    case records do
      [record | _] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  def create(attrs), do: %ModelConfig{} |> ModelConfig.changeset(attrs) |> persist()
  def update(%ModelConfig{id: id}, attrs), do: update(id, attrs)

  def update(id, attrs) do
    with {:ok, record} <- get(id),
         do: record |> ModelConfig.changeset(Map.drop(attrs, [:id, "id"])) |> persist()
  end

  def delete(%ModelConfig{id: id}), do: delete(id)

  def delete(id) do
    with {:ok, record} <- get(id), :ok <- Store.delete(:model, id), do: {:ok, record}
  end

  @doc "Import suggestions without changing an existing model's choices or stable ID."
  def import(provider_id, candidates) when is_list(candidates) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, records} ->
      model = value(candidate, :model) || value(candidate, :id)

      result =
        case get_by_identity(provider_id, model) do
          {:ok, record} ->
            {:ok, record}

          {:error, :not_found} ->
            create(%{
              provider_id: provider_id,
              model: model,
              name: value(candidate, :name),
              context_window: value(candidate, :context_window) || %ModelConfig{}.context_window,
              enabled: value(candidate, :enabled, true)
            })
        end

      case result do
        {:ok, record} ->
          {:cont, {:ok, [record | records]}}

        error ->
          # Another importer may have inserted this same identity meanwhile.
          case get_by_identity(provider_id, model) do
            {:ok, record} -> {:cont, {:ok, [record | records]}}
            {:error, :not_found} -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp persist(%Ecto.Changeset{valid?: true} = changeset) do
    record = Ecto.Changeset.apply_changes(changeset)
    record = if record.id, do: record, else: %{record | id: Ecto.UUID.generate()}
    {:ok, records} = list(provider_id: record.provider_id, model: record.model)

    if Enum.any?(records, &(&1.id != record.id)) do
      {:error,
       Ecto.Changeset.add_error(changeset, :model, "has already been taken for this provider")}
    else
      case Store.put(:model, Map.from_struct(record) |> Map.delete(:__meta__)) do
        {:ok, _} ->
          {:ok, record}

        {:error, :duplicate_model} ->
          {:error,
           Ecto.Changeset.add_error(changeset, :model, "has already been taken for this provider")}

        error ->
          error
      end
    end
  end

  defp persist(changeset), do: {:error, changeset}

  defp to_struct(attrs),
    do: %ModelConfig{} |> ModelConfig.changeset(attrs) |> Ecto.Changeset.apply_changes()

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
