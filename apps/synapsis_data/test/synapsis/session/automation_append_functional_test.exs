defmodule Synapsis.Session.AutomationAppendFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Session.Store

  setup do
    assert :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(id) end)
    %{id: id}
  end

  test "completed assistant append preserves prior turns and all unrelated current metadata", %{
    id: id
  } do
    before = ~U[2026-10-28 01:00:00Z]
    now = ~U[2026-10-28 02:00:00Z]

    meta = %{
      id: id,
      title: "Updated title",
      config: %{"nested" => %{"keep" => true}},
      updated_at: before
    }

    previous = %{id: Ecto.UUID.generate(), role: "user", parts: [%{type: "text", text: "source"}]}

    result = %{
      id: Ecto.UUID.generate(),
      role: "assistant",
      parts: [%{type: "text", text: "作业已完成"}]
    }

    assert :ok = Store.commit_turn(id, 0, previous, meta)

    assert {:ok, merged} = Store.append_automation_turn(id, 1, result, now)
    assert merged == %{meta | updated_at: now}
    assert {:ok, ^merged} = Store.get_meta(id)
    assert {:ok, [^previous, ^result]} = Store.list_turns(id)
  end

  test "append reads the latest metadata after a separate title and config update", %{id: id} do
    original = %{
      id: id,
      title: "Original",
      config: %{"keep" => 1},
      updated_at: ~U[2026-10-28 01:00:00Z]
    }

    assert :ok = Store.put_meta(id, original)
    edited = %{original | title: "Human edit", config: %{"keep" => 1, "new" => "value"}}
    assert :ok = Store.put_meta(id, edited)

    turn = %{
      id: Ecto.UUID.generate(),
      role: "assistant",
      parts: [%{type: "text", text: "result"}]
    }

    now = ~U[2026-10-28 02:00:00Z]

    assert {:ok, meta} = Store.append_automation_turn(id, 0, turn, now)
    assert meta == %{edited | updated_at: now}
    assert {:ok, [^turn]} = Store.list_turns(id)
  end
end
