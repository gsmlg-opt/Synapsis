defmodule Synapsis.Backplane.ConnectionDeleteTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.Connection
  alias Synapsis.Config.Store

  setup do
    clear_store()
    on_exit(&clear_store/0)
    :ok
  end

  test "a late source update cannot recreate a deleted connection" do
    assert {:ok, connection} =
             Connection.create(%{name: "late-update", base_url: "https://backplane.example.test"})

    assert :ok = Connection.delete(connection)
    assert {:error, :not_found} = Connection.update(connection, %{status: "synced"})
    assert {:error, :not_found} = Connection.get(connection.id)
  end

  test "delete/1 propagates persistence failures and keeps the connection" do
    assert {:ok, connection} =
             Connection.create(%{
               name: "delete-failure",
               base_url: "https://backplane.example.test"
             })

    :backplane
    |> Store.file_path()
    |> File.chmod!(0o400)

    assert {:error, {:persist_failed, _reason}} = Connection.delete(connection)
    assert {:ok, %{id: id}} = Connection.get(connection.id)
    assert id == connection.id
  end

  defp clear_store do
    :backplane
    |> Store.file_path()
    |> File.rm()

    if :ets.info(:synapsis_config_backplane) != :undefined do
      :ets.delete_all_objects(:synapsis_config_backplane)
    end

    :ok
  end
end
