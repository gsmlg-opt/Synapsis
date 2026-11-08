defmodule Synapsis.Agent.Tools.SessionHistoryFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.Tools.SessionHistory
  alias Synapsis.Session.Store

  setup do
    previous = Application.fetch_env(:synapsis_agent, :filesystem_node)
    node = System.get_env("SYNAPSIS_FILESYSTEM_NODE") || System.find_executable("node")
    Application.put_env(:synapsis_agent, :filesystem_node, node)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:synapsis_agent, :filesystem_node, value)
        :error -> Application.delete_env(:synapsis_agent, :filesystem_node)
      end
    end)

    :ok
  end

  test "native descriptor and backend return the same durable public JSON page" do
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, agent: "history-reader"})
    on_exit(fn -> Store.delete_session(id) end)

    context = %{
      session_id: id,
      agent_id: "history-reader",
      run_id: "history/run",
      incarnation: 1,
      catalog_revision: 1
    }

    assert SessionHistory.names() == ["synapsis::sessions_history"]
    assert {:ok, [descriptor]} = SessionHistory.descriptors(context)
    assert descriptor.backend == SessionHistory
    assert descriptor.tool_revision == 2

    assert Enum.sort(Map.keys(descriptor.schema["properties"])) ==
             ~w(include_tools limit message_id offset pending_before session_id)

    operation =
      Map.merge(context, %{
        tool_name: descriptor.tool_name,
        tool_revision: 2,
        arguments: %{},
        backend_context: context
      })

    assert {:ok, %{content: content, structured: page}} = SessionHistory.execute(operation)
    assert Jason.decode!(content) == Jason.decode!(Jason.encode!(page))
    pending = %{"items" => [], "total" => 0}

    assert page == %{
             "session_id" => id,
             "messages" => [],
             "truncated" => false,
             "droppedMessages" => false,
             "contentTruncated" => false,
             "contentRedacted" => false,
             "bytes" => byte_size(Jason.encode!([])) + byte_size(Jason.encode!(pending)),
             "pendingInputs" => pending
           }
  end
end
