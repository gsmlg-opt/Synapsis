defmodule Synapsis.Agent.Tools.SessionStatusFunctionalTest do
  use ExUnit.Case, async: false
  alias Synapsis.Agent.Tools.SessionStatus
  alias Synapsis.Session.Store

  setup do
    :ok = Store.ensure_started()
    id = Ecto.UUID.generate()
    :ok = Store.put_meta(id, %{id: id, title: "Stored", agent: "archive", status: "idle"})
    on_exit(fn -> Store.delete_session(id) end)

    context = %{
      session_id: id,
      agent_id: "main",
      run_id: "status/run",
      incarnation: 1,
      catalog_revision: 1
    }

    %{id: id, context: context}
  end

  test "native durable JSON agrees with core public metadata", ctx do
    assert SessionStatus.names() == ["synapsis::session_status"]
    assert {:ok, [descriptor]} = SessionStatus.descriptors(ctx.context)
    assert descriptor.tool_revision == 1 and descriptor.backend == SessionStatus
    assert Enum.sort(Map.keys(descriptor.schema["properties"])) == ~w(session_id source)
    assert descriptor.schema["properties"]["source"]["enum"] == ~w(auto live durable)
    input = %{"source" => "durable"}

    assert {:ok, core} =
             Synapsis.SessionStatus.read(input, Map.take(ctx.context, [:session_id, :agent_id]))

    expected =
      Map.put(core, :usage, %{
        source: "native_committed",
        coverage: "retained_runs",
        observation: "sequential",
        runtime_version: "1.10.60",
        retained_runs: 0,
        observed_runs: 0,
        provider_attempts: 0,
        metrics: %{input_tokens: 0, cached_tokens: 0, output_tokens: 0, reasoning_tokens: 0},
        cost: %{status: "unavailable"}
      })

    assert {:ok, %{content: content, structured: ^expected} = native} =
             SessionStatus.execute(operation(ctx.context, input))

    assert Jason.decode!(content) == Jason.decode!(Jason.encode!(expected))
    assert byte_size(Jason.encode!(native)) <= 65_536
  end

  test "auto records point-in-time absence before durable fallback", ctx do
    assert {:ok, %{structured: result}} = SessionStatus.execute(operation(ctx.context, %{}))
    assert result.source == "durable"
    assert result.live_observation == "unregistered"
    assert result.session.id == ctx.id
  end

  test "explicit live source reports absent Worker", ctx do
    assert {:error, error} = SessionStatus.execute(operation(ctx.context, %{"source" => "live"}))
    assert error.details.code == "not_running"
  end

  defp operation(context, input) do
    Map.merge(context, %{
      tool_name: "synapsis::session_status",
      tool_revision: 1,
      arguments: input,
      backend_context: context
    })
  end
end
