defmodule Synapsis.Agent.Tools.SessionDirectoryFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional
  alias Synapsis.Agent.Tools.SessionDirectory
  alias Synapsis.Session.Store

  test "native descriptor and backend expose the core durable public JSON page" do
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, title: id, agent: "archive", status: "idle"})
    on_exit(fn -> Store.delete_session(id) end)

    context = %{
      session_id: id,
      agent_id: "main",
      run_id: "directory/run",
      incarnation: 1,
      catalog_revision: 1
    }

    assert SessionDirectory.names() == ["synapsis::sessions_list"]
    assert {:ok, [descriptor]} = SessionDirectory.descriptors(context)
    assert descriptor.backend == SessionDirectory and descriptor.tool_revision == 3

    assert Enum.sort(Map.keys(descriptor.schema["properties"])) ==
             ~w(active_minutes agent include_derived_titles include_last_message limit message_limit offset search)

    for flag <- ~w(include_derived_titles include_last_message) do
      assert descriptor.schema["properties"][flag]["type"] == "boolean"
      assert descriptor.schema["properties"][flag]["default"] == false
    end

    assert descriptor.schema["properties"]["message_limit"] ==
             %{"type" => "integer", "minimum" => 0, "default" => 0}

    input = %{"search" => id}

    assert {:ok, core} =
             Synapsis.SessionDirectory.list(input, Map.take(context, [:session_id, :agent_id]))

    operation =
      Map.merge(context, %{
        tool_name: descriptor.tool_name,
        tool_revision: 3,
        arguments: input,
        backend_context: context
      })

    assert {:ok, %{content: content, structured: page}} = SessionDirectory.execute(operation)
    assert page == core
    assert Jason.decode!(content) == Jason.decode!(Jason.encode!(core))
    assert content == Jason.encode!(core, pretty: true)
    assert [%{id: ^id, agent: "archive"}] = page.sessions

    assert Enum.sort(Map.keys(hd(page.sessions))) ==
             ~w(agent id inserted_at model provider status title updated_at)a
  end
end
