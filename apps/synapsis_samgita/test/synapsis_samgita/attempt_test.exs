defmodule SynapsisSamgita.AttemptTest do
  use ExUnit.Case, async: false

  # Delegates to the real API except `start`, whose first call has an unknown
  # outcome (transport failure) and whose retry succeeds.
  defmodule FlakyAPI do
    defdelegate proof(conn, project_id, attempt_id), to: SynapsisSamgita.API
    defdelegate renew(conn, project_id, attempt_id, version, proof, opts), to: SynapsisSamgita.API

    def start(_conn, _project_id, _attempt_id, version, _proof, opts) do
      test = :persistent_term.get({__MODULE__, :test})
      send(test, {:flaky_start, {opts[:command_id], version}})

      if Process.get(:flaky_seen) do
        {:ok, %{"id" => "a-1", "state" => "running", "version" => version + 1}}
      else
        Process.put(:flaky_seen, true)
        {:error, %{status: nil, code: "transport_error", detail: "timeout"}}
      end
    end
  end

  import SynapsisSamgita.Test.SamgitaStub
  alias SynapsisSamgita.Attempt

  setup ctx do
    server = Gaoxy.Test.open()

    conn = %{
      base_url: String.trim_trailing(Gaoxy.Test.url(server), "/"),
      credential: String.duplicate("c", 43),
      connection_id: "conn-1"
    }

    {:ok, proofs} = Agent.start_link(fn -> ["v1.k.p0", "v1.k.p1", "v1.k.p2", "v1.k.p3"] end)

    unless ctx[:custom_proof] do
      Gaoxy.Test.stub(server, "GET", "/api/agent/projects/p-1/attempts/a-1/proof", fn conn ->
        proof = Agent.get_and_update(proofs, fn [h | t] -> {h, if(t == [], do: [h], else: t)} end)
        json(conn, 200, %{"data" => %{"attempt_id" => "a-1", "proof" => proof}})
      end)
    end

    attempt = %{
      "id" => "a-1",
      "task_id" => "t-1",
      "state" => "leased",
      "version" => 1,
      "lease_expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 120))
    }

    %{server: server, conn: conn, attempt: attempt}
  end

  defp start_attempt(ctx, opts \\ []) do
    SynapsisSamgita.Events.subscribe_attempts()

    start_supervised!(
      {Attempt,
       Keyword.merge(
         [conn: ctx.conn, project_id: "p-1", attempt: ctx.attempt, notify: self(), registry: nil],
         opts
       )}
    )
  end

  test "renews in the background, re-reading the proof after each renew", ctx do
    test_pid = self()

    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/renew", fn conn ->
      {body, conn} = body(conn)
      send(test_pid, {:renew, body["proof"], body["expected_version"]})

      json(conn, 200, %{
        "data" => %{"id" => "a-1", "state" => "leased", "version" => body["expected_version"] + 1}
      })
    end)

    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/start", fn conn ->
      {body, conn} = body(conn)
      send(test_pid, {:start, body["proof"], body["expected_version"]})

      json(conn, 200, %{
        "data" => %{
          "id" => "a-1",
          "state" => "running",
          "version" => body["expected_version"] + 1
        }
      })
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

    assert {:ok, %{state: "succeeded"}} =
             Attempt.report(pid, "succeeded", true, %{"note" => "ok"})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:attempt_view, %{state: "succeeded"}}
  end

  test "an expired lease with failing renewals marks the attempt lost", ctx do
    Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/renew", fn conn ->
      json(conn, 409, %{"errors" => %{"code" => "ownership_lost"}})
    end)

    expired = %{
      ctx.attempt
      | "lease_expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))
    }

    pid = start_attempt(%{ctx | attempt: expired}, renew_interval_ms: 20)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert_receive {:attempt_view, %{state: "lost", last_error: "ownership_lost"}}
  end

  describe "failure recovery" do
    defp scripted(server, method, path, responses) do
      {:ok, agent} = Agent.start_link(fn -> responses end)

      Gaoxy.Test.stub(server, method, path, fn conn ->
        {body, conn} = if method == "POST", do: body(conn), else: {%{}, conn}
        step = Agent.get_and_update(agent, fn [h | t] -> {h, if(t == [], do: [h], else: t)} end)
        step.(conn, body)
      end)
    end

    defp ok_attempt(state),
      do: fn conn, body ->
        json(conn, 200, %{
          "data" => %{
            "id" => "a-1",
            "state" => state,
            "version" => (body["expected_version"] || 0) + 1
          }
        })
      end

    test "a failed renew is retried well before the next interval", ctx do
      test_pid = self()
      fail = fn conn, _ -> json(conn, 503, %{"errors" => %{"code" => "unavailable"}}) end

      scripted(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/renew", [
        fn conn, body ->
          send(test_pid, {:renew, System.monotonic_time(:millisecond)})
          fail.(conn, body)
        end,
        fn conn, body ->
          send(test_pid, {:renew, System.monotonic_time(:millisecond)})
          ok_attempt("leased").(conn, body)
        end
      ])

      pid = start_attempt(ctx, renew_interval_ms: 300, retry_interval_ms: 20)
      assert_receive {:renew, t1}, 2_000
      assert_receive {:renew, t2}, 2_000
      assert t2 - t1 < 200
      # Let the in-flight proof re-read finish before the test server closes.
      :sys.get_state(pid)
    end

    @tag :custom_proof
    test "a proof re-read that fails after renew is retried before the next renew", ctx do
      test_pid = self()

      proof = fn p ->
        fn conn, _ -> json(conn, 200, %{"data" => %{"attempt_id" => "a-1", "proof" => p}}) end
      end

      scripted(ctx.server, "GET", "/api/agent/projects/p-1/attempts/a-1/proof", [
        proof.("v1.k.p0"),
        fn conn, _ -> json(conn, 500, %{"errors" => %{"code" => "internal"}}) end,
        proof.("v1.k.p1"),
        proof.("v1.k.p2")
      ])

      Gaoxy.Test.stub(ctx.server, "POST", "/api/agent/projects/p-1/attempts/a-1/renew", fn conn ->
        {body, conn} = body(conn)
        send(test_pid, {:renew_proof, body["proof"]})
        ok_attempt("leased").(conn, body)
      end)

      pid = start_attempt(ctx, renew_interval_ms: 200, retry_interval_ms: 10)
      assert_receive {:renew_proof, "v1.k.p0"}, 2_000
      assert_receive {:renew_proof, second}, 2_000
      assert second == "v1.k.p1"
      :sys.get_state(pid)
    end

    test "an uncertain write is retried with the same command_id and body", ctx do
      Process.put(:flaky_api_test, self())
      :persistent_term.put({FlakyAPI, :test}, self())
      pid = start_attempt(ctx, api: FlakyAPI)

      assert {:ok, %{state: "running", version: 2}} = Attempt.start_work(pid)
      assert_receive {:flaky_start, first}
      assert_receive {:flaky_start, second}
      assert first == second
    end
  end
end
