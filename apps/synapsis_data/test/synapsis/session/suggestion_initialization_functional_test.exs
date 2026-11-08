defmodule Synapsis.Session.SuggestionInitializationFunctionalTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session
  alias Synapsis.Session.Store

  test "initializes the preallocated suggested session and retains exact metadata on fresh reads" do
    id = Ecto.UUID.generate()
    source = Ecto.UUID.generate()
    now = DateTime.utc_now()

    meta =
      Session.to_meta(%Session{
        id: id,
        title: "Follow up / 雪",
        agent: "suggestion-fixture",
        provider: "saved-provider",
        model: "saved-model",
        status: "idle",
        inserted_at: now,
        updated_at: now,
        config: %{
          "provider_id" => Ecto.UUID.generate(),
          "model_id" => Ecto.UUID.generate(),
          "creation_context" => %{
            "version" => 1,
            "kind" => "task_suggestion",
            "task_id" => "task_" <> Ecto.UUID.generate(),
            "source_session_id" => source,
            "cwd" => System.tmp_dir!()
          }
        }
      })

    permission =
      %Synapsis.SessionPermission{}
      |> Synapsis.SessionPermission.changeset(%{session_id: id, tool_contract_version: 1})
      |> Ecto.Changeset.apply_changes()
      |> Map.from_struct()
      |> Map.delete(:__meta__)

    on_exit(fn -> Store.delete_session(id) end)

    assert :ok = Store.initialize_session(id, meta, permission, timeout: 5_000)
    assert {:ok, ^meta} = Store.get_meta(id)
    assert {:ok, ^meta} = Task.async(fn -> Store.get_meta(id) end) |> Task.await(5_000)
    assert {:ok, []} = Store.list_turns(id)
    assert Session.from_meta(meta).id == id
  end
end
