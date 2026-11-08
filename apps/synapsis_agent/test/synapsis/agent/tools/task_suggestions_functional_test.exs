defmodule Synapsis.Agent.Tools.TaskSuggestionsFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Agent.Tools.{DisplayCatalog, TaskSuggestions}
  alias Synapsis.TaskSuggestions, as: Domain

  setup do
    context = %{
      session_id: Ecto.UUID.generate(),
      agent_id: "main",
      cwd: "/tmp/suggestion-project",
      run_id: "suggestions/run",
      incarnation: 1,
      catalog_revision: 1
    }

    %{context: context}
  end

  test "native create and dismiss agree between JSON content, structured result and core", ctx do
    assert TaskSuggestions.names() == ~w(synapsis::suggest_task synapsis::dismiss_task)
    assert {:ok, descriptors} = TaskSuggestions.descriptors(ctx.context)
    assert length(descriptors) == 2
    [create, dismiss] = descriptors
    assert create.tool_revision == 1 and create.backend == TaskSuggestions
    assert Enum.sort(Map.keys(create.schema["properties"])) == ~w(cwd prompt title tldr)
    assert Enum.sort(Map.keys(dismiss.schema["properties"])) == ~w(reason task_id)
    assert create.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert dismiss.safety == %{read_only: false, retry_safe: true, parallel_safe: false}
    assert TaskSuggestions.permission_level(create.tool_name) == :write
    assert create.description =~ "pending suggestion"
    assert create.description =~ "operator can start it in a new session"

    args = %{"title" => "Improve docs", "prompt" => "Describe the API", "tldr" => "Help readers"}
    create_op = operation(ctx.context, create.tool_name, args)
    assert {:ok, classification} = TaskSuggestions.classify(ctx.context, create_op)
    assert classification.action == "task_suggestion.create"

    resource =
      String.replace_prefix(classification.resource, "task_suggestion:", "") |> Jason.decode!()

    assert resource["session_id"] == ctx.context.session_id
    assert resource["agent_id"] == "main"
    assert resource["candidate"]["cwd"] == ctx.context.cwd

    assert {:ok, %{structured: %{task_id: id}, content: content} = result} =
             TaskSuggestions.execute(create_op)

    assert Jason.decode!(content) == %{"task_id" => id}
    assert byte_size(Jason.encode!(result)) <= 65_536
    assert {:ok, [record]} = Domain.list(ctx.context)
    assert record.id == id and record.cwd == ctx.context.cwd

    dismiss_op = operation(ctx.context, dismiss.tool_name, %{"task_id" => id, "reason" => "Done"})

    assert {:ok, %{action: "task_suggestion.dismiss", resource: target}} =
             TaskSuggestions.classify(ctx.context, dismiss_op)

    assert Jason.decode!(String.replace_prefix(target, "task_suggestion:", "")) == %{
             "session_id" => ctx.context.session_id,
             "agent_id" => "main",
             "task_id" => id
           }

    assert {:ok, %{structured: %{task_id: ^id, dismissed: true} = structured, content: text}} =
             TaskSuggestions.execute(dismiss_op)

    assert Jason.decode!(text) == Jason.decode!(Jason.encode!(structured))
    assert {:ok, %{structured: %{dismissed: false}}} = TaskSuggestions.execute(dismiss_op)
    assert {:ok, []} = Domain.list(ctx.context)
    assert {:ok, %{status: "dismissed", suggestion: ^record}} = Domain.get(id, ctx.context)
  end

  test "display metadata accurately describes proposals", _ctx do
    entry = Enum.find(DisplayCatalog.list(), &(&1.name == "synapsis::suggest_task"))
    assert entry.category == :planning
    assert entry.description =~ "pending"
    assert entry.description =~ "without starting"
  end

  defp operation(context, name, input) do
    Map.merge(context, %{
      tool_name: name,
      tool_revision: 1,
      arguments: input,
      backend_context: context
    })
  end
end
