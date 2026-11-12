defmodule SynapsisSamgita.AttemptTest do
  use ExUnit.Case, async: false

  import SynapsisSamgita.Test.SamgitaStub
  alias SynapsisSamgita.Attempt

  setup do
    server = Gaoxy.Test.open()
    conn = %{base_url: String.trim_trailing(Gaoxy.Test.url(server), "/"), credential: String.duplicate("c", 43), connection_id: "conn-1"}
    {:ok, proofs} = Agent.start_link(fn -> ["v1.k.p0", "v1.k.p1", "v1.k.p2", "v1.k.p3"] end)

    Gaoxy.Test.stub(server, "GET", "/api/agent/projects/p-1/attempts/a-1/proof", fn conn ->
      proof = Agent.get_and_update(proofs, fn [h | t] -> {h, if(t == [], do: [h], else: t)} end)
      json(conn, 200, %{"data" => %{"attempt_id" => "a-1", "proof" => proof}})
    end)

    attempt = %{"id" => "a-1", "task_id" => "t-1", "state" => "leased", "version" => 1,
                "lease_expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 120))}

    %{server: server, conn: conn, attempt: attempt}
  end

  defp start_attempt(ctx, opts \\ []) do
    SynapsisSamgita.Events.subscribe_attempts()

    start_supervised!(
      {Attempt, Keyword.merge([conn: ctx.conn, project_id: "p-1", attempt: ctx.attempt, notify: self(), registry: nil], opts)}
    )
  end

  test "renews in the background, re-reading the proof after each renew", ctx do
    test_pid = self()

    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/renew", fn conn ->
      {body, conn} = body(conn)
      send(test_pid, {:renew, body["proof"], body["expected_version"]})
      json(conn, 200, %{"data" => %{"id" => "a-1", "state" => "leased", "version" => body["expected_version"] + 1}})
    end)

    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/start", fn conn ->
      {body, conn} = body(conn)
      send(test_pid, {:start, body["proof"], body["expected_version"]})
      json(conn, 200, %{"data" => %{"id" => "a-1", "state" => "running", "version" => body["expected_version"] + 1}})
    end)

    pid = start_attempt(ctx, renew_interval_ms: 50)

    assert_receive {:renew, "v1.k.p0", 1}, 2_000
    assert_receive {:renew, "v1.k.p1", 2}, 2_000
    :sys.get_state(pid)

    assert {:ok, %{state: "running"}} = Attempt.start_work(pid)
    assert_receive {:start, proof, version}
    assert proof in ["v1.k.p2", "v1.k.p3"]
    assert version >= 3
  end

  test "a failed step keeps the attempt unchanged and records the error", ctx do
    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/start", fn conn ->
      json(conn, 409, %{"errors" => %{"code" => "stale_version"}})
    end)

    pid = start_attempt(ctx)

    assert {:error, %{code: "stale_version"}} = Attempt.start_work(pid)
    assert %{state: "leased", version: 1, last_error: "stale_version"} = Attempt.view(pid)
    assert_receive {:samgita_attempt, %{last_error: "stale_version"}}
  end

  test "a successful report finishes the attempt", ctx do
    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/report", fn conn ->
      {body, conn} = body(conn)
      assert %{"outcome" => "succeeded", "effects_resolved" => true} = body
      json(conn, 200, %{"data" => %{"id" => "a-1", "state" => "succeeded", "version" => 2}})
    end)

    pid = start_attempt(ctx)
    ref = Process.monitor(pid)

    assert {:ok, %{state: "succeeded"}} = Attempt.report(pid, "succeeded", true, %{"note" => "ok"})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:attempt_view, %{state: "succeeded"}}
  end

  test "an expired lease with failing renewals marks the attempt lost", ctx do
    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/renew", fn conn ->
      json(conn, 409, %{"errors" => %{"code" => "ownership_lost"}})
    end)

    expired = %{ctx.attempt | "lease_expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))}
    pid = start_attempt(%{ctx | attempt: expired}, renew_interval_ms: 20)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert_receive {:attempt_view, %{state: "lost", last_error: "ownership_lost"}}
  end
end
