defmodule Synapsis.LocalAgentConfigs do
  @moduledoc "Context for local agent definitions persisted in `local_agents.toml`."

  alias Synapsis.Config.Store
  alias Synapsis.LocalAgentConfig

  @store_type :local_agent
  @fields ~w(name kind executable args cwd codex_home autostart)a

  @spec list() :: [LocalAgentConfig.t()]
  def list do
    @store_type |> Store.list() |> Enum.map(&to_struct/1) |> Enum.sort_by(&{&1.name, &1.id})
  end

  @spec get(String.t()) :: LocalAgentConfig.t() | nil
  def get(id) do
    case Store.get(@store_type, id) do
      {:ok, map} -> to_struct(map)
      _ -> nil
    end
  end

  def create(attrs) when is_map(attrs) do
    changeset = LocalAgentConfig.changeset(%LocalAgentConfig{}, attrs)

    with {:ok, record} <- Ecto.Changeset.apply_action(changeset, :insert) do
      record = %{record | id: record.id || Ecto.UUID.generate()}

      case Store.put(@store_type, to_store_map(record)) do
        :ok -> {:ok, record}
        {:ok, _} -> {:ok, record}
        error -> error
      end
    end
  end

  def update(%LocalAgentConfig{id: id}, attrs) when is_map(attrs) do
    Store.with_write_lock(fn ->
      with {:ok, current} <- Store.get(@store_type, id),
           changeset = LocalAgentConfig.changeset(to_struct(current), Map.drop(attrs, [:id, "id"])),
           {:ok, record} <- Ecto.Changeset.apply_action(changeset, :update),
           {:ok, merged} <- Store.replace_existing(@store_type, id, to_store_map(record)) do
        {:ok, to_struct(merged)}
      end
    end)
  end

  def delete(%LocalAgentConfig{id: id} = config) do
    with :ok <- Store.delete(@store_type, id), do: {:ok, config}
  end

  @doc "Create the default Codex entry when none exists and `codex` is on PATH."
  @spec ensure_default_codex() :: :ok
  def ensure_default_codex do
    Store.with_write_lock(fn ->
      executable = System.find_executable("codex")

      if executable && not Enum.any?(list(), &(&1.kind == "codex")) do
        {:ok, _} = create(%{name: "Codex", kind: "codex", executable: executable})
      end

      :ok
    end)
  end

  defp to_struct(map) do
    record = %LocalAgentConfig{} |> LocalAgentConfig.changeset(map) |> Ecto.Changeset.apply_changes()
    %{record | id: map["id"] || record.id}
  end

  defp to_store_map(%LocalAgentConfig{} = r) do
    @fields
    |> Map.new(&{Atom.to_string(&1), Map.fetch!(r, &1)})
    |> Map.put("id", r.id)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
