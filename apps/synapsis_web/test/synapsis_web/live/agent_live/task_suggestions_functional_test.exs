defmodule SynapsisWeb.AgentLive.TaskSuggestionsFunctionalTest do
  use SynapsisWeb.ConnCase

  alias Synapsis.Session.Store
  alias Synapsis.TaskSuggestions

  test "selected session initially shows newest proposals with collapsed standalone prompts", %{
    conn: conn
  } do
    session = source_session()
    first = suggest(session, "First follow-up")
    second = suggest(session, "Second follow-up")

    {:ok, view, html} = live(conn, session_path(session))

    assert has_element?(view, "#task-suggestions", "Suggested follow-ups")
    assert has_element?(view, "#task-suggestions", "Not started")
    assert has_element?(view, "#task-suggestion-#{second}", "/tmp/suggestion-ui")
    assert has_element?(view, "#task-suggestion-#{first} details:not([open])", "Full prompt")
    assert html =~ "Standalone instructions for First follow-up"
    assert [^second, ^first] = suggestion_ids(html)
    assert Registry.lookup(Synapsis.Session.Registry, session.id) == []
    assert Synapsis.Sessions.get_messages(session.id) == []
  end

  test "actual registry broadcasts add and remove pending cards", %{conn: conn} do
    session = source_session()
    {:ok, view, _} = live(conn, session_path(session))
    assert has_element?(view, "#task-suggestions", "No pending follow-ups")

    id = suggest(session, "Live follow-up")
    assert has_element?(view, "#task-suggestion-#{id}", "Live follow-up")

    assert {:ok, %{dismissed: true}} =
             TaskSuggestions.dismiss(%{"task_id" => id}, context(session))

    assert {:ok, []} = TaskSuggestions.list(%{session_id: session.id})
    refute has_element?(view, "#task-suggestion-#{id}")
    assert has_element?(view, "#task-suggestions", "No pending follow-ups")
  end

  test "operator dismiss uses the captured proposer after the session agent changed", %{
    conn: conn
  } do
    session = source_session()
    id = suggest(session, "Earlier proposal", "earlier-agent")
    {:ok, view, _} = live(conn, session_path(session))

    view
    |> element("#task-suggestion-#{id} [phx-click='dismiss_task_suggestion']")
    |> render_click()

    refute has_element?(view, "#task-suggestion-#{id}")
    assert {:ok, []} = TaskSuggestions.list(%{session_id: session.id})

    assert {:ok, %{status: "dismissed"}} =
             TaskSuggestions.get(id, %{session_id: session.id, agent_id: "earlier-agent"})

    assert Registry.lookup(Synapsis.Session.Registry, session.id) == []
  end

  test "normal session navigation replaces subscriptions and snapshots", %{conn: conn} do
    first_session = source_session()
    second_session = source_session()
    first = suggest(first_session, "First session follow-up")
    second = suggest(second_session, "Second session follow-up")
    {:ok, view, _} = live(conn, session_path(first_session))
    assert subscribed?(view.pid, first_session.id)

    render_patch(view, session_path(second_session))
    refute subscribed?(view.pid, first_session.id)
    assert subscribed?(view.pid, second_session.id)
    refute has_element?(view, "#task-suggestion-#{first}")
    assert has_element?(view, "#task-suggestion-#{second}")

    suggest(first_session, "Later first-session follow-up")
    assert [^second] = suggestion_ids(render(view))

    render_patch(view, "/agent/agents/main/sessions")
    refute subscribed?(view.pid, second_session.id)
    refute has_element?(view, "#task-suggestions")

    render_patch(view, session_path(first_session))
    assert has_element?(view, "#task-suggestions", "Later first-session follow-up")
    assert length(suggestion_ids(render(view))) == 2
  end

  test "navigating to a removed session clears the previous suggestion subscription", %{
    conn: conn
  } do
    session = source_session()
    removed = source_session()
    suggest(session, "Previous session proposal")
    {:ok, view, _} = live(conn, session_path(session))
    assert subscribed?(view.pid, session.id)
    :ok = Store.delete_session(removed.id)

    render_patch(view, session_path(removed))
    assert_redirect(view, "/agent/agents/main/sessions")
    refute subscribed?(view.pid, session.id)
    refute subscribed?(view.pid, removed.id)
  end

  test "a repeated dismissal refreshes and explains the disappeared proposal", %{conn: conn} do
    session = source_session()
    id = suggest(session, "Already resolved")
    {:ok, view, _} = live(conn, session_path(session))
    render_click(view, "dismiss_task_suggestion", %{"task-id" => id})
    render_click(view, "dismiss_task_suggestion", %{"task-id" => id})
    assert has_element?(view, "#task-suggestions", "This suggestion is no longer pending")
    assert has_element?(view, "#task-suggestions", "No pending follow-ups")
  end

  test "loading failure presents retry without an empty success state" do
    html =
      render_component(&SynapsisWeb.AgentLive.TaskSuggestions.panel/1,
        suggestions: [],
        error: "Could not load suggested follow-ups. Retry to refresh."
      )

    assert html =~ "Could not load suggested follow-ups"
    assert html =~ "refresh_task_suggestions"
    assert html =~ "Retry"
    refute html =~ "No pending follow-ups"
  end

  defp source_session do
    now = DateTime.utc_now()

    session = %Synapsis.Session{
      id: Ecto.UUID.generate(),
      title: "Suggestion UI fixture",
      agent: "main",
      provider: "local-fixture",
      model: "ordinary-model",
      config: %{"subagents" => false},
      status: "idle",
      inserted_at: now,
      updated_at: now
    }

    :ok = Store.put_meta(session.id, Synapsis.Session.to_meta(session))
    on_exit(fn -> Store.delete_session(session.id) end)
    session
  end

  defp suggest(session, title, agent \\ "main") do
    {:ok, %{task_id: id}} =
      TaskSuggestions.create(
        %{
          "title" => title,
          "tldr" => "A useful next step",
          "prompt" => "Standalone instructions for #{title}"
        },
        %{context(session) | agent_id: agent}
      )

    assert {:ok, _} = TaskSuggestions.list(%{session_id: session.id})
    id
  end

  defp context(session),
    do: %{session_id: session.id, agent_id: "main", cwd: "/tmp/suggestion-ui"}

  defp session_path(session), do: "/agent/agents/main/sessions/#{session.id}"

  defp suggestion_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-task-suggestion-id]")
    |> LazyHTML.attribute("data-task-suggestion-id")
  end

  defp subscribed?(pid, session_id) do
    Enum.any?(Registry.lookup(Synapsis.PubSub, "task_suggestions:#{session_id}"), fn {subscriber,
                                                                                      _} ->
      subscriber == pid
    end)
  end
end
