defmodule SynapsisWeb.AgentLive.TaskSuggestionAcceptanceFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  alias Synapsis.Agent.TestSupport.DeterministicProvider
  alias Synapsis.Session.{Store, Worker}
  alias Synapsis.{AgentConfigs, Models, Providers, Session, Sessions, TaskSuggestions}

  @moduletag timeout: 60_000
  @prefix "Start by addressing this task in the current folder. If an isolated Git worktree is needed, explain why and ask the user before creating or switching to it.\n\n"

  test "operator Start launches once and accepted source cards retain the destination across remounts",
       %{conn: conn} do
    owner = self()

    root =
      Path.join([
        System.tmp_dir!(),
        "synapsis-suggestion360-web-#{System.get_env("MIX_TEST_PARTITION", "0")}",
        Ecto.UUID.generate()
      ])

    File.mkdir_p!(root)
    fixture = Gaoxy.Test.open()
    {:ok, counter} = Agent.start_link(fn -> [] end)

    {:ok, provider} =
      Providers.create(%{
        name: "suggestion-web-#{Ecto.UUID.generate()}",
        type: "openai",
        base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
        api_key_encrypted: "fixture-key"
      })

    {:ok, model} = Models.create(%{provider_id: provider.id, model: "web-follow-up-model"})

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "suggestion-web-#{Ecto.UUID.generate()}",
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
            do: send(handler, :complete_web_suggestion)
      end

      {:ok, sessions} = Sessions.list(agent.name)
      Enum.each(sessions, &Sessions.delete(&1.id))
      AgentConfigs.delete(agent)
      Models.delete(model)
      Providers.delete(provider.id)
      if Process.alive?(counter), do: Agent.stop(counter)
      File.rm_rf!(root)
    end)

    Gaoxy.Test.stub(fixture, "POST", "/v1/chat/completions", fn request_conn ->
      {:ok, body, request_conn} = Plug.Conn.read_body(request_conn)
      request = Jason.decode!(body)
      handler = self()
      Agent.update(counter, &(&1 ++ [{request, handler}]))
      send(owner, {:web_suggested_request, request, handler})

      receive do
        :complete_web_suggestion -> :ok
      after
        20_000 -> raise "ordinary web suggested completion was not released"
      end

      DeterministicProvider.send_sse(request_conn, [
        DeterministicProvider.text_chunk("Web follow-up complete"),
        DeterministicProvider.finish_chunk("stop")
      ])
    end)

    {:ok, %{task_id: task_id}} =
      TaskSuggestions.create(
        %{
          "title" => "Write the follow-up",
          "tldr" => "Continue in this folder",
          "prompt" => "Add the usage example."
        },
        %{session_id: source.id, agent_id: agent.name, cwd: root}
      )

    source_path = "/agent/agents/#{agent.name}/sessions/#{source.id}"
    card = "#task-suggestion-#{task_id}"
    {:ok, view, _} = live(conn, source_path)

    assert has_element?(
             view,
             "#{card} [phx-click='accept_task_suggestion']",
             "Start in this folder"
           )

    assert length(Agent.get(counter, & &1)) == 0
    assert {:ok, sessions} = Sessions.list(agent.name)
    assert length(sessions) == 1

    view |> element("#{card} [phx-click='accept_task_suggestion']") |> render_click()
    assert_receive {:web_suggested_request, request, handler}, 15_000

    await(fn ->
      match?(
        {:ok, %{status: "accepted"}},
        TaskSuggestions.get(task_id, %{session_id: source.id, agent_id: agent.name})
      )
    end)

    {:ok, %{receipt: receipt}} =
      TaskSuggestions.get(task_id, %{session_id: source.id, agent_id: agent.name})

    destination_path = "/agent/agents/#{agent.name}/sessions/#{receipt.session_id}"
    assert has_element?(view, "#{card} a[href='#{destination_path}']", "Open session")
    refute has_element?(view, "#{card} [phx-click='accept_task_suggestion']")
    assert request["model"] == model.model
    users = Enum.filter(request["messages"], &(&1["role"] == "user"))
    assert Enum.map(users, &message_text/1) == [@prefix <> "Add the usage example."]
    assert {:ok, []} = Store.list_turns(source.id)

    render_click(view, "refresh_task_suggestions", %{})
    assert has_element?(view, "#{card} a[href='#{destination_path}']", "Open session")
    {:ok, remounted, _} = live(conn, source_path)
    assert has_element?(remounted, "#{card} a[href='#{destination_path}']", "Open session")
    render_click(remounted, "accept_task_suggestion", %{"task-id" => task_id})
    assert has_element?(remounted, "#{card} a[href='#{destination_path}']", "Open session")
    assert {:ok, sessions} = Sessions.list(agent.name)
    assert Enum.sort(Enum.map(sessions, & &1.id)) == Enum.sort([source.id, receipt.session_id])
    assert length(Agent.get(counter, & &1)) == 1

    send(handler, :complete_web_suggestion)

    await(fn ->
      match?({:ok, %{runtime: %{active: false}}}, Worker.public_status(receipt.session_id))
    end)

    assert {:ok, turns} = Store.list_turns(receipt.session_id)
    assert Enum.map(turns, & &1.role) == ["user", "assistant"]
    assert hd(turns).id == receipt.input_id

    remounted |> element("#{card} a[href='#{destination_path}']") |> render_click()
    assert_patch(remounted, destination_path)
    assert render(remounted) =~ "Web follow-up complete"
    render_patch(remounted, source_path)
    assert has_element?(remounted, "#{card} a[href='#{destination_path}']", "Open session")

    assert {:ok, %{status: "accepted", receipt: ^receipt}} =
             TaskSuggestions.get(task_id, %{session_id: source.id, agent_id: agent.name})

    assert {:ok, ^turns} = Store.list_turns(receipt.session_id)
    assert length(Agent.get(counter, & &1)) == 1
    assert {:ok, []} = Store.list_turns(source.id)
  end

  defp message_text(%{"content" => content}) when is_binary(content), do: content
  defp message_text(%{"content" => content}), do: Enum.map_join(content, &(&1["text"] || ""))
  defp await(check), do: await(check, System.monotonic_time(:millisecond) + 15_000)

  defp await(check, deadline) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await(check, deadline)
    end
  end
end
