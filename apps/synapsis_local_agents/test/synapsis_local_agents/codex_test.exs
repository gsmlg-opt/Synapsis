defmodule SynapsisLocalAgents.CodexTest do
  use ExUnit.Case, async: false

  alias Synapsis.LocalAgentConfig
  alias SynapsisLocalAgents.{Codex, Event}
  alias SynapsisLocalAgents.Test.ScriptedTransport

  @init_result %{
    "userAgent" => "codex/0.167.0",
    "codexHome" => "/isolated",
    "platformFamily" => "unix",
    "platformOs" => "linux"
  }

  setup do
    previous = Application.get_env(:synapsis_local_agents, :codex_transport)
    Application.put_env(:synapsis_local_agents, :codex_transport, {ScriptedTransport, observer: self()})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_local_agents, :codex_transport, previous),
        else: Application.delete_env(:synapsis_local_agents, :codex_transport)
    end)

    config = %LocalAgentConfig{id: "codex-1", name: "Codex", kind: "codex", executable: "/bin/true"}
    Process.flag(:trap_exit, true)
    {:ok, pid} = Codex.start_link(config, self())
    assert_receive {:transport_opened, session}, 2_000
    assert_receive {:sent, ^session, %{"id" => id, "method" => "initialize"}}, 2_000
    send(session, {:incoming, %{"id" => id, "result" => @init_result}})
    assert_receive {:sent, ^session, %{"method" => "initialized"}}, 2_000
    assert_receive {:local_agent_event, %Event{type: :status, data: %{state: :running}}}, 2_000
    %{pid: pid, session: session}
  end

  # Run `fun` while answering the next request sent to the session with `result`.
  defp answering(session, method, result, fun) do
    task = Task.async(fun)
    assert_receive {:sent, ^session, %{"id" => id, "method" => ^method} = wire}, 2_000
    send(session, {:incoming, %{"id" => id, "result" => result}})
    {Task.await(task), wire}
  end

  test "start_turn sends the text input and returns the turn id", %{pid: pid, session: s} do
    {result, wire} =
      answering(s, "turn/start", %{"turn" => %{"id" => "tu-1", "items" => [], "status" => "inProgress"}}, fn ->
        Codex.start_turn(pid, "th-1", "hello")
      end)

    assert {:ok, %{turn_id: "tu-1"}} = result
    assert wire["params"] == %{"threadId" => "th-1", "input" => [%{"type" => "text", "text" => "hello"}]}
  end

  defp failing(session, method, error, fun) do
    task = Task.async(fun)
    assert_receive {:sent, ^session, %{"id" => id, "method" => ^method}}, 2_000
    send(session, {:incoming, %{"id" => id, "error" => error}})
    task
  end

  @no_rollout %{"code" => -32600, "message" => "no rollout found for thread id th-new"}

  test "read_thread takes history from thread/resume", %{pid: pid, session: s} do
    turns = [
      %{"id" => "tu-1", "status" => "completed", "items" => [
        %{"type" => "userMessage", "id" => "i-1", "content" => [%{"type" => "text", "text" => "hello there"}]},
        %{"type" => "reasoning", "id" => "i-r"},
        %{"type" => "agentMessage", "id" => "i-2", "text" => "hi from codex"}
      ]}
    ]

    {result, _} =
      answering(s, "thread/resume", %{"thread" => %{"id" => "th-1", "turns" => turns}}, fn -> Codex.read_thread(pid, "th-1") end)

    assert {:ok, %{id: "th-1", turns: [%{id: "tu-1", items: items}]}} = result
    assert [%{role: :user, text: "hello there"}, %{role: :agent, text: "hi from codex"}] = items
  end

  test "a fresh thread has no rollout: resume succeeds and history is empty", %{pid: pid, session: s} do
    task = failing(s, "thread/resume", @no_rollout, fn -> Codex.resume_thread(pid, "th-new") end)
    assert {:ok, %{id: "th-new"}} = Task.await(task)

    task = failing(s, "thread/resume", @no_rollout, fn -> Codex.read_thread(pid, "th-new") end)
    assert_receive {:sent, ^s, %{"id" => id, "method" => "thread/read", "params" => params}}, 2_000
    refute Map.has_key?(params, "includeTurns")
    send(s, {:incoming, %{"id" => id, "result" => %{"thread" => %{"id" => "th-new"}}}})
    assert {:ok, %{id: "th-new", turns: []}} = Task.await(task)
  end

  test "upstream errors carry Codex's message", %{pid: pid, session: s} do
    error = %{"code" => -32600, "message" => "thread th-1 already has an active writer"}
    task = failing(s, "thread/resume", error, fn -> Codex.resume_thread(pid, "th-1") end)
    assert {:error, %{code: :upstream_error, message: "thread th-1 already has an active writer"}} = Task.await(task)
  end

  test "list_threads maps thread/list data", %{pid: pid, session: s} do
    data = [%{"id" => "th-1", "preview" => "First chat", "updatedAt" => 1_762_905_600}]
    {result, _} = answering(s, "thread/list", %{"data" => data}, fn -> Codex.list_threads(pid) end)
    assert {:ok, [%{id: "th-1", title: "First chat"}]} = result
  end

  test "a result the pinned schema rejects is still read from the wire", %{pid: pid, session: s} do
    {result, _} =
      answering(s, "thread/start", %{"thread" => %{"id" => "th-new"}}, fn -> Codex.start_thread(pid) end)

    assert {:ok, %{id: "th-new"}} = result
  end

  test "deltas and turn completion become local agent events", %{session: s} do
    send(s, {:incoming, %{"method" => "item/agentMessage/delta",
      "params" => %{"threadId" => "th-1", "turnId" => "tu-1", "itemId" => "i-1", "delta" => "Hel"}}})

    send(s, {:incoming, %{"method" => "turn/completed",
      "params" => %{"threadId" => "th-1", "turn" => %{"id" => "tu-1", "items" => [], "status" => "interrupted"}}}})

    assert_receive {:local_agent_event,
                    %Event{type: :item_delta, thread_id: "th-1", turn_id: "tu-1", item_id: "i-1", data: %{delta: "Hel"}}},
                   2_000

    assert_receive {:local_agent_event,
                    %Event{type: :turn_completed, thread_id: "th-1", turn_id: "tu-1", data: %{status: "interrupted"}}},
                   2_000
  end

  test "a failed turn carries Codex's error message", %{session: s} do
    send(s, {:incoming, %{"method" => "turn/completed",
      "params" => %{"threadId" => "th-1", "turn" => %{"id" => "tu-1", "items" => [], "status" => "failed",
        "error" => %{"message" => "Missing environment variable: `BP_TOKEN`.", "codexErrorInfo" => "other"}}}}})

    assert_receive {:local_agent_event,
                    %Event{type: :turn_completed, data: %{status: "failed", error: "Missing environment variable: `BP_TOKEN`."}}},
                   2_000
  end

  test "approval requests are accepted automatically", %{session: s} do
    send(s, {:incoming, %{"id" => "srv-1", "method" => "item/commandExecution/requestApproval",
      "params" => %{"threadId" => "th-1", "turnId" => "tu-1", "itemId" => "i-1", "startedAtMs" => 1}}})

    assert_receive {:sent, ^s, %{"id" => "srv-1", "result" => %{"decision" => "accept"}}}, 2_000

    assert_receive {:local_agent_event,
                    %Event{type: :interaction, data: %{method: "item/commandExecution/requestApproval", decision: "accept"}}},
                   2_000
  end

  test "losing the Codex connection stops the adapter abnormally", %{pid: pid, session: s} do
    send(s, :drop_connection)
    assert_receive {:EXIT, ^pid, reason}, 2_000
    refute reason in [:normal, :shutdown]
  end

  test "stop/1 closes the session", %{pid: pid} do
    assert :ok = Codex.stop(pid)
    assert_receive {:transport_closed, _}, 2_000
    refute Process.alive?(pid)
  end

  describe "stdio_transport/1" do
    @tag :tmp_dir
    test "passes through env vars that Codex providers declare via env_key", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config.toml"), """
      model_provider = "backplane"
      [model_providers.backplane]
      base_url = "http://localhost"
      env_key = "BP_TOKEN"
      [model_providers.other]
      env_key = "OTHER_KEY"
      """)

      config = %LocalAgentConfig{id: "c", name: "Codex", kind: "codex", executable: "/bin/codex",
        args: ["app-server"], codex_home: dir}

      {SamgitaCodexDriver.Transport.Stdio, opts} = Codex.stdio_transport(config)
      assert "PATH" in opts[:inherit_env]
      assert "BP_TOKEN" in opts[:inherit_env]
      assert "OTHER_KEY" in opts[:inherit_env]
      assert opts[:codex_home] == dir
      assert opts[:executable] == "/bin/codex"
    end

    @tag :tmp_dir
    test "a missing or invalid Codex config keeps the default env", %{tmp_dir: dir} do
      config = %LocalAgentConfig{id: "c", name: "Codex", kind: "codex", executable: "/bin/codex",
        args: [], codex_home: dir}

      {_, opts} = Codex.stdio_transport(config)
      assert opts[:inherit_env] == ~w(PATH LANG LC_ALL LC_CTYPE TMPDIR TEMP TMP SystemRoot WINDIR)

      File.write!(Path.join(dir, "config.toml"), "not = [valid")
      {_, opts} = Codex.stdio_transport(config)
      assert "PATH" in opts[:inherit_env]
    end
  end
end
