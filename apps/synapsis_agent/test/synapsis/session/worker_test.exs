defmodule Synapsis.Session.WorkerTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.{Repo, Session}
  alias Synapsis.Session.Worker

  test "cancel force-stops graph runner and returns session to idle" do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        provider: "anthropic",
        model: "test-model",
        agent: "main",
        status: "streaming"
      })
      |> Repo.insert()

    runner_pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(runner_pid)

    state = %Worker{
      session_id: session.id,
      session: session,
      runner_pid: runner_pid,
      execution_mode: :graph
    }

    assert {:noreply, %{runner_pid: nil, stream_ref: nil}, _timeout} =
             Worker.handle_cast(:cancel, state)

    assert_receive {:DOWN, ^ref, :process, ^runner_pid, :killed}
    assert Repo.get!(Session, session.id).status == "idle"
  end
end
