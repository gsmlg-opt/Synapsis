defmodule Synapsis.TaskSuggestionAcceptanceFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.{AgentConfigs, Models, Providers, Session, Sessions, TaskSuggestions}

  @moduletag timeout: 60_000
  @prefix "Start by addressing this task in the current folder. If an isolated Git worktree is needed, explain why and ask the user before creating or switching to it.\n\n"

  setup do
    assert {:ok, _} = Application.ensure_all_started(:synapsis_agent)
    :ok
  end

  test "ordinary acceptance retains the native launch receipt and replays it without another session or prompt" do
    owner = self()

    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-suggestion360-core-#{System.get_env("MIX_TEST_PARTITION", "0")}",
        Ecto.UUID.generate()
      ])

    File.mkdir_p!(root)
    fixture = Gaoxy.Test.open()
    {:ok, counter} = Agent.start_link(fn -> [] end)

    {:ok, provider} =
      Providers.create(%{
        name: "suggestion-core-#{Ecto.UUID.generate()}",
        type: "openai",
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
        api_key_encrypted: "fixture-key"
      })

    {:ok, model} = Models.create(%{provider_id: provider.id, model: "suggestion-model"})

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "suggestion-core-#{Ecto.UUID.generate()}",
        provider: provider.name,
        model: model.model,
        tools: [],
        tool_contract_version: 1,
        config: %{"workspace_path" => root}
      })

    source = %Session{
      id: Ecto.UUID.generate(),
      title: "Source",
      agent: agent.name,
      provider: provider.name,
      model: model.model,
      status: "idle",
      config: %{"provider_id" => provider.id, "model_id" => model.id},
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    :ok = Store.put_meta(source.id, Session.to_meta(source))

    on_exit(fn ->
      if Process.alive?(counter) do
        for {_request, handler} <- Agent.get(counter, & &1),
            do: send(handler, :complete_suggestion)
      end

      {:ok, sessions} = Sessions.list(agent.name)
      Enum.each(sessions, &Sessions.delete(&1.id))
      AgentConfigs.delete(agent)
      Models.delete(model)
      Providers.delete(provider.id)
      if Process.alive?(counter), do: Agent.stop(counter)
      File.rm_rf!(root)
    end)

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      handler = self()
      Agent.update(counter, &(&1 ++ [{request, handler}]))
      send(owner, {:core_suggestion_request, request, handler})

      receive do
        :complete_suggestion -> :ok
      after
        20_000 -> raise "ordinary suggested completion was not released"
      end

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
      |> Plug.Conn.send_resp(
        200,
        "data: " <>
          Jason.encode!(%{
            choices: [%{delta: %{content: "Suggested task complete"}, finish_reason: nil}]
          }) <>
          "\n\ndata: " <>
          Jason.encode!(%{choices: [%{delta: %{}, finish_reason: "stop"}]}) <>
          "\n\ndata: [DONE]\n\n"
      )
    end)

    {:ok, %{task_id: task_id}} =
      TaskSuggestions.create(
        %{
          "title" => "Follow-up",
          "tldr" => "Continue locally",
          "prompt" => "Write the next paragraph."
        },
        %{session_id: source.id, agent_id: agent.name, cwd: root}
      )

    context = %{session_id: source.id, requester_id: "synapsis:operator"}

    assert {:ok, %{status: "accepting", task_id: ^task_id, session_id: destination}} =
             TaskSuggestions.accept(task_id, context)

    refute destination == source.id
    assert_receive {:core_suggestion_request, request, handler}, 10_000
    receipt = await_receipt(task_id, source.id, agent.name)
    assert receipt.status == "accepted"
    assert receipt.session_id == destination
    assert receipt.task_id == task_id
    assert receipt.source_session_id == source.id
    for key <- [:run_id, :turn_id, :message_id, :input_id], do: assert(is_binary(receipt[key]))
    refute receipt.message_id == receipt.input_id
    assert request["model"] == model.model

    assert [%{"role" => "user", "content" => content}] =
             Enum.reject(request["messages"], &(&1["role"] == "system"))

    assert prompt_text(content) == @prefix <> "Write the next paragraph."
    assert {:ok, []} = TaskSuggestions.list(%{session_id: source.id})

    assert {:ok, [%{status: "accepted", suggestion: %{id: ^task_id}, receipt: ^receipt}]} =
             TaskSuggestions.list_for_host(%{session_id: source.id})

    assert {:ok, ^receipt} = TaskSuggestions.accept(task_id, context)
    assert {:ok, sessions} = Sessions.list(agent.name)
    assert Enum.sort(Enum.map(sessions, & &1.id)) == Enum.sort([source.id, destination])
    assert length(Agent.get(counter, & &1)) == 1
    assert {:ok, []} = Store.list_turns(source.id)

    send(handler, :complete_suggestion)

    await(fn ->
      match?({:ok, %{runtime: %{active: false}}}, Worker.public_status(destination))
    end)

    assert {:ok, turns} = Store.list_turns(destination)
    assert Enum.map(turns, & &1.role) == ["user", "assistant"]
    assert hd(turns).id == receipt.input_id
    assert {:ok, ^receipt} = TaskSuggestions.accept(task_id, context)
    assert length(Agent.get(counter, & &1)) == 1
  end

  defp await_receipt(id, source, agent) do
    await(fn ->
      match?(
        {:ok, %{status: "accepted"}},
        TaskSuggestions.get(id, %{session_id: source, agent_id: agent})
      )
    end)

    {:ok, %{receipt: receipt}} = TaskSuggestions.get(id, %{session_id: source, agent_id: agent})
    receipt
  end

  defp prompt_text(content) when is_binary(content), do: content
  defp prompt_text(content), do: Enum.map_join(content, &(&1["text"] || ""))
  defp await(check), do: await(check, System.monotonic_time(:millisecond) + 15_000)

  defp await(check, deadline) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await(check, deadline)
    end
  end
end
