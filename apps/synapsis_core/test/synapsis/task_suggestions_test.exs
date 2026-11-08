defmodule Synapsis.TaskSuggestionsTest do
  use ExUnit.Case, async: true

  alias Synapsis.TaskSuggestions

  setup do
    server = start_supervised!({TaskSuggestions, name: nil})
    context = %{session_id: Ecto.UUID.generate(), agent_id: "main", cwd: "/tmp/project"}
    %{server: server, context: context, opts: [server: server]}
  end

  test "records trimmed suggestions in newest-first source order without creating sessions",
       ctx do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "task_suggestions:#{ctx.context.session_id}")
    before_meta = Synapsis.Session.Store.get_meta(ctx.context.session_id)
    assert {:ok, %{task_id: first}} = TaskSuggestions.create(input(), ctx.context, ctx.opts)
    assert "task_" <> uuid = first
    assert {:ok, ^uuid} = Ecto.UUID.cast(uuid)
    assert_receive {:task_suggestion_created, suggestion}
    assert suggestion.id == first
    assert suggestion.title == "Improve docs"
    assert suggestion.prompt == "Describe the public API."
    assert suggestion.tldr == "Make the API easier to use."
    assert suggestion.cwd == ctx.context.cwd
    assert suggestion.session_id == ctx.context.session_id
    assert suggestion.agent_id == "main"
    assert is_integer(suggestion.created_at)
    assert Synapsis.Session.Store.get_meta(ctx.context.session_id) == before_meta

    assert {:ok, %{task_id: second}} = TaskSuggestions.create(input(), ctx.context, ctx.opts)
    assert second != first
    assert {:ok, [newest, ^suggestion]} = TaskSuggestions.list(ctx.context, ctx.opts)
    assert newest.id == second
    assert {:ok, []} = TaskSuggestions.list(%{session_id: Ecto.UUID.generate()}, ctx.opts)
  end

  test "dismisses a pending record once and retains lifecycle without explanatory reason", ctx do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "task_suggestions:#{ctx.context.session_id}")
    assert {:ok, %{task_id: id}} = TaskSuggestions.create(input(), ctx.context, ctx.opts)
    assert_receive {:task_suggestion_created, suggestion}
    args = %{"task_id" => id, "reason" => "Already handled"}

    assert {:ok, %{task_id: ^id, dismissed: true}} =
             TaskSuggestions.dismiss(args, ctx.context, ctx.opts)

    assert_receive {:task_suggestion_resolved, %{task_id: ^id, status: "dismissed"} = event}
    refute Map.has_key?(event, :reason)
    assert {:ok, []} = TaskSuggestions.list(ctx.context, ctx.opts)

    assert {:ok, %{status: "dismissed", suggestion: ^suggestion}} =
             TaskSuggestions.get(id, ctx.context, ctx.opts)

    assert {:ok, %{task_id: ^id, dismissed: false}} =
             TaskSuggestions.dismiss(args, ctx.context, ctx.opts)

    assert {:ok, %{dismissed: false}} =
             TaskSuggestions.dismiss(%{"task_id" => "task_missing"}, ctx.context, ctx.opts)
  end

  test "a restarted suggestion service has no retained records", ctx do
    assert {:ok, %{task_id: id}} = TaskSuggestions.create(input(), ctx.context, ctx.opts)
    assert :ok = stop_supervised(TaskSuggestions)
    server = start_supervised!({TaskSuggestions, name: nil})
    assert {:ok, []} = TaskSuggestions.list(ctx.context, server: server)
    assert {:error, :not_found} = TaskSuggestions.get(id, ctx.context, server: server)
  end

  test "count admission evicts dismissed records before the oldest pending record", ctx do
    :ok = Phoenix.PubSub.subscribe(Synapsis.PubSub, "task_suggestions:#{ctx.context.session_id}")

    ids =
      for _ <- 1..100 do
        assert {:ok, %{task_id: id}} = TaskSuggestions.create(input(), ctx.context, ctx.opts)
        assert_receive {:task_suggestion_created, %{id: ^id}}
        id
      end

    [first, dismissed | _] = ids

    assert {:ok, %{dismissed: true}} =
             TaskSuggestions.dismiss(%{"task_id" => dismissed}, ctx.context, ctx.opts)

    assert_receive {:task_suggestion_resolved, %{task_id: ^dismissed, status: "dismissed"}}

    assert {:ok, %{task_id: next}} = TaskSuggestions.create(input(), ctx.context, ctx.opts)
    assert_receive {:task_suggestion_created, %{id: ^next}}
    assert {:error, :not_found} = TaskSuggestions.get(dismissed, ctx.context, ctx.opts)
    assert {:ok, %{status: "pending"}} = TaskSuggestions.get(first, ctx.context, ctx.opts)
    assert {:ok, %{task_id: last}} = TaskSuggestions.create(input(), ctx.context, ctx.opts)
    assert_receive event
    assert event == {:task_suggestion_resolved, %{task_id: first, status: "expired"}}
    assert_receive event
    assert {:task_suggestion_created, %{id: ^last}} = event
    assert {:ok, rows} = TaskSuggestions.list(ctx.context, ctx.opts)
    assert length(rows) == 100
    assert Enum.map(Enum.take(rows, 2), & &1.id) == [last, next]
    assert {:error, :not_found} = TaskSuggestions.get(first, ctx.context, ctx.opts)
  end

  test "aggregate retained JSON stays within two MiB for large normal prompts", ctx do
    for character <- ["x", "文"] do
      large = Map.put(input(), "prompt", String.duplicate(character, 32_768))

      ids =
        for _ <- 1..100 do
          assert {:ok, %{task_id: id}} = TaskSuggestions.create(large, ctx.context, ctx.opts)
          id
        end

      assert {:ok, rows} = TaskSuggestions.list(ctx.context, ctx.opts)
      assert length(rows) < 100
      retained = Enum.reduce(rows, 1, &(byte_size(Jason.encode!(&1)) + 1 + &2))
      assert retained <= 2 * 1024 * 1024
      assert Enum.map(rows, & &1.id) == ids |> Enum.reverse() |> Enum.take(length(rows))
      assert {:error, :not_found} = TaskSuggestions.get(hd(ids), ctx.context, ctx.opts)
    end
  end

  test "explicit absolute cwd and character-length normal inputs are retained", ctx do
    args = %{
      "title" => String.duplicate("文", 60),
      "prompt" => String.duplicate("文", 32_768),
      "tldr" => String.duplicate("文", 1_024),
      "cwd" => "/tmp/follow-up"
    }

    assert {:ok, %{task_id: id}} = TaskSuggestions.create(args, ctx.context, ctx.opts)
    assert {:ok, [row]} = TaskSuggestions.list(ctx.context, ctx.opts)
    assert row.id == id
    assert row.cwd == args["cwd"]
    assert row.title == args["title"]
    assert row.prompt == args["prompt"]
    assert row.tldr == args["tldr"]
  end

  defp input do
    %{
      "title" => " Improve docs ",
      "prompt" => " Describe the public API. ",
      "tldr" => " Make the API easier to use. "
    }
  end
end
