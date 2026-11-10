defmodule Synapsis.Automation.WebhookFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Automation.Webhook

  test "a real local 204 accepts the exact encoded JSON once and reports ordered progress" do
    fixture = Gaoxy.Test.open()
    owner = self()
    encoded = "{\"action\":\"finished\",\"summary\":\"原文 \\n\",\"jobId\":\"fixture-job\"}"

    Gaoxy.Test.expect_once(fixture, "POST", "/finished", fn conn ->
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert {:ok, ^encoded, conn} = Plug.Conn.read_body(conn)
      send(owner, {:received_exact_json, encoded})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    progress = fn observation ->
      send(owner, {:progress, observation})
      :ok
    end

    assert {:ok, outcome} =
             Webhook.deliver(
               Gaoxy.Test.url(fixture, "/finished"),
               encoded,
               System.monotonic_time(:millisecond) + 5_000,
               progress
             )

    assert_receive {:progress,
                    %{"status" => "unknown", "attempted" => true, "attempt_count" => 1}}

    assert_receive {:received_exact_json, ^encoded}

    assert_receive {:progress,
                    %{"status" => "delivered", "delivered" => true, "http_status" => 204}}

    assert Map.take(outcome, ~w(status attempted delivered http_status attempt_count)) == %{
             "status" => "delivered",
             "attempted" => true,
             "delivered" => true,
             "http_status" => 204,
             "attempt_count" => 1
           }

    assert length(Gaoxy.Test.requests(fixture).entries) == 1
    assert :ok = Gaoxy.Test.verify_and_close!(fixture)
  end

  test "2xx headers publish acknowledged delivery while the successful body remains unfinished" do
    fixture = Gaoxy.Test.open()
    owner = self()
    release = make_ref()
    encoded = Jason.encode!(%{"action" => "finished", "summary" => "Accepted before body end"})

    Gaoxy.Test.expect_once(fixture, "POST", "/headers-first", fn conn ->
      assert {:ok, ^encoded, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.send_chunked(conn, 202)
      assert {:ok, conn} = Plug.Conn.chunk(conn, "accepted")
      send(owner, {:response_body_held, self()})

      receive do
        ^release -> conn
      after
        5_000 -> raise "successful response body was not released"
      end
    end)

    progress = fn observation ->
      acknowledgement = make_ref()
      send(owner, {:progress_handshake, self(), acknowledgement, observation})

      receive do
        {^acknowledgement, :acknowledged} -> :ok
      after
        5_000 -> raise "delivery progress was not acknowledged"
      end
    end

    task =
      Task.async(fn ->
        Webhook.deliver(
          Gaoxy.Test.url(fixture, "/headers-first"),
          encoded,
          System.monotonic_time(:millisecond) + 5_000,
          progress
        )
      end)

    assert_receive {:progress_handshake, worker, attempted_ack,
                    %{"status" => "unknown", "attempted" => true, "attempt_count" => 1}},
                   1_000

    send(worker, {attempted_ack, :acknowledged})
    assert_receive {:response_body_held, receiver}, 1_000

    try do
      assert_receive {:progress_handshake, ^worker, delivered_ack,
                      %{"status" => "delivered", "delivered" => true, "http_status" => 202}},
                     1_000

      assert Process.alive?(receiver)
      send(worker, {delivered_ack, :acknowledged})
      assert {:ok, %{"status" => "delivered", "http_status" => 202}} = Task.await(task, 1_000)
    after
      send(receiver, release)
      Task.shutdown(task, :brutal_kill)
    end

    assert length(Gaoxy.Test.requests(fixture).entries) == 1
    assert :ok = Gaoxy.Test.verify_and_close!(fixture)
  end
end
