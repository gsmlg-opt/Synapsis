defmodule Synapsis.Tool.MemoryToolsTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{SemanticMemory, Repo}

  setup do
    Synapsis.Memory.Cache.clear()

    # Create project + session for context
    {:ok, project} =
      %Synapsis.Project{}
      |> Synapsis.Project.changeset(%{
        path: "/tmp/mem_tool_test_#{System.unique_integer([:positive])}",
        slug: "mem-tool-test-#{System.unique_integer([:positive])}",
        name: "mem-tool-test-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    {:ok, session} =
      %Synapsis.Session{}
      |> Synapsis.Session.changeset(%{
        project_id: project.id,
        provider: "anthropic",
        model: "claude-sonnet-4-20250514"
      })
      |> Repo.insert()

    context = %{
      session_id: session.id,
      project_id: to_string(project.id),
      agent_id: "test_agent",
      agent_scope: :project
    }

    {:ok, context: context, project: project, session: session}
  end

  describe "MemorySave" do
    test "saves a single memory record", %{context: context} do
      input = %{
        "memories" => [
          %{
            "kind" => "fact",
            "title" => "Elixir uses snake_case",
            "summary" => "All Elixir variables and functions use snake_case naming.",
            "tags" => ["elixir", "style"]
          }
        ]
      }

      assert {:ok, json} = Synapsis.Tool.MemorySave.execute(input, context)
      results = Jason.decode!(json)
      assert length(results) == 1
      assert hd(results)["status"] == "saved"
      assert hd(results)["title"] == "Elixir uses snake_case"
    end

    test "saves multiple memory records", %{context: context} do
      input = %{
        "memories" => [
          %{"kind" => "fact", "title" => "Fact 1", "summary" => "First fact"},
          %{"kind" => "decision", "title" => "Decision 1", "summary" => "First decision"}
        ]
      }

      assert {:ok, json} = Synapsis.Tool.MemorySave.execute(input, context)
      results = Jason.decode!(json)
      assert length(results) == 2
      assert Enum.all?(results, &(&1["status"] == "saved"))
    end

    test "infers project scope from context", %{context: context} do
      input = %{
        "memories" => [
          %{"kind" => "fact", "title" => "Scoped memory", "summary" => "Should be project scope"}
        ]
      }

      assert {:ok, json} = Synapsis.Tool.MemorySave.execute(input, context)
      [result] = Jason.decode!(json)
      {:ok, mem} = Synapsis.Memory.get_semantic(result["id"])
      assert mem.scope == "project"
      assert mem.scope_id == context.project_id
    end

    test "respects explicit scope override", %{context: context} do
      input = %{
        "memories" => [
          %{
            "scope" => "shared",
            "kind" => "pattern",
            "title" => "Shared pattern",
            "summary" => "Cross-project pattern"
          }
        ]
      }

      assert {:ok, json} = Synapsis.Tool.MemorySave.execute(input, context)
      [result] = Jason.decode!(json)
      {:ok, mem} = Synapsis.Memory.get_semantic(result["id"])
      assert mem.scope == "shared"
    end

    test "sets contributed_by from context agent_id", %{context: context} do
      input = %{
        "memories" => [
          %{"kind" => "lesson", "title" => "Test lesson", "summary" => "Learned something"}
        ]
      }

      assert {:ok, json} = Synapsis.Tool.MemorySave.execute(input, context)
      [result] = Jason.decode!(json)
      {:ok, mem} = Synapsis.Memory.get_semantic(result["id"])
      assert mem.contributed_by == "test_agent"
    end
  end

  describe "MemorySearch" do
    setup %{context: context} do
      # Insert test memories
      {:ok, _} =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "project",
          scope_id: context.project_id,
          kind: "fact",
          title: "Phoenix uses LiveView",
          summary: "The project uses Phoenix LiveView for real-time UI",
          tags: ["phoenix", "liveview"],
          importance: 0.8
        })
        |> Repo.insert()

      {:ok, _} =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "shared",
          scope_id: "",
          kind: "preference",
          title: "Concise responses",
          summary: "User prefers short, direct answers",
          tags: ["communication"],
          importance: 0.7
        })
        |> Repo.insert()

      :ok
    end

    test "searches by query and returns results", %{context: context} do
      input = %{"query" => "Phoenix LiveView"}
      assert {:ok, json} = Synapsis.Tool.MemorySearch.execute(input, context)
      results = Jason.decode!(json)
      assert length(results) > 0
      assert Enum.any?(results, &(&1["title"] == "Phoenix uses LiveView"))
    end

    test "respects limit parameter", %{context: context} do
      input = %{"query" => "project", "limit" => 1}
      assert {:ok, json} = Synapsis.Tool.MemorySearch.execute(input, context)
      results = Jason.decode!(json)
      assert length(results) <= 1
    end

    test "returns empty array when no matches", %{context: context} do
      input = %{"query" => "xyznonexistent123"}
      assert {:ok, json} = Synapsis.Tool.MemorySearch.execute(input, context)
      results = Jason.decode!(json)
      assert results == []
    end
  end

  describe "MemoryUpdate" do
    setup %{context: context} do
      {:ok, mem} =
        %SemanticMemory{}
        |> SemanticMemory.changeset(%{
          scope: "project",
          scope_id: context.project_id,
          kind: "decision",
          title: "Use GenServer",
          summary: "Decided to use GenServer for session management",
          importance: 0.8
        })
        |> Repo.insert()

      {:ok, memory: mem}
    end

    test "updates memory fields", %{context: context, memory: mem} do
      input = %{
        "action" => "update",
        "memory_id" => mem.id,
        "changes" => %{
          "summary" => "Updated: Use GenServer with DynamicSupervisor"
        }
      }

      assert {:ok, json} = Synapsis.Tool.MemoryUpdate.execute(input, context)
      result = Jason.decode!(json)
      assert result["status"] == "success"

      {:ok, updated} = Synapsis.Memory.get_semantic(mem.id)
      assert updated.summary == "Updated: Use GenServer with DynamicSupervisor"
    end

    test "archives a memory", %{context: context, memory: mem} do
      input = %{"action" => "archive", "memory_id" => mem.id}

      assert {:ok, json} = Synapsis.Tool.MemoryUpdate.execute(input, context)
      result = Jason.decode!(json)
      assert result["status"] == "success"

      {:ok, archived} = Synapsis.Memory.get_semantic(mem.id)
      refute is_nil(archived.archived_at)
    end

    test "restores an archived memory", %{context: context, memory: mem} do
      # Archive first
      Synapsis.Memory.archive_semantic(mem)

      input = %{"action" => "restore", "memory_id" => mem.id}
      assert {:ok, json} = Synapsis.Tool.MemoryUpdate.execute(input, context)
      result = Jason.decode!(json)
      assert result["status"] == "success"

      {:ok, restored} = Synapsis.Memory.get_semantic(mem.id)
      assert is_nil(restored.archived_at)
    end

    test "returns error for nonexistent memory", %{context: context} do
      bogus_id = Ecto.UUID.generate()
      input = %{"action" => "update", "memory_id" => bogus_id}
      assert {:error, msg} = Synapsis.Tool.MemoryUpdate.execute(input, context)
      assert msg =~ "not found"
    end

    test "creates audit trail event", %{context: context, memory: mem} do
      input = %{
        "action" => "update",
        "memory_id" => mem.id,
        "changes" => %{"title" => "Updated title"}
      }

      Synapsis.Tool.MemoryUpdate.execute(input, context)

      events = Synapsis.Memory.list_events(type: "memory_updated")
      assert length(events) > 0
      event = hd(events)
      assert event.payload["memory_id"] == mem.id
      assert event.payload["action"] == "update"
      assert event.payload["previous"]["title"] == "Use GenServer"
    end
  end

  describe "SessionSummarize" do
    test "returns empty candidates when no messages", %{context: context} do
      input = %{}
      assert {:ok, json} = Synapsis.Tool.SessionSummarize.execute(input, context)
      result = Jason.decode!(json)
      assert result["candidates"] == []
    end

    test "returns candidates for session with messages", %{context: context, session: session} do
      # Insert enough messages with sufficient content to trigger candidate extraction
      for i <- 1..6 do
        %Synapsis.Message{}
        |> Synapsis.Message.changeset(%{
          session_id: session.id,
          role: if(rem(i, 2) == 1, do: "user", else: "assistant"),
          parts: [
            %Synapsis.Part.Text{
              content:
                "Discussing Elixir patterns and Phoenix LiveView architecture for building real-time applications with message #{i}"
            }
          ],
          token_count: 20
        })
        |> Repo.insert!()
      end

      # Use focus to guarantee at least one candidate from the focus-based extraction
      input = %{"focus" => "Elixir architecture", "scope" => "full"}
      assert {:ok, json} = Synapsis.Tool.SessionSummarize.execute(input, context)
      result = Jason.decode!(json)
      assert result["message_count"] == 6
      # With focus and 6 messages (>=5), we should get both focused and topic candidates
      assert length(result["candidates"]) >= 1
    end

    test "returns error when no session_id in context" do
      assert {:error, msg} = Synapsis.Tool.SessionSummarize.execute(%{}, %{})
      assert msg =~ "session_id"
    end
  end

  describe "tool behaviour compliance" do
    test "MemorySave implements Tool behaviour" do
      assert Synapsis.Tool.MemorySave.name() == "memory_save"
      assert Synapsis.Tool.MemorySave.category() == :memory
      assert Synapsis.Tool.MemorySave.permission_level() == :write
      assert Synapsis.Tool.MemorySave.side_effects() == [:memory_promoted]
      assert is_map(Synapsis.Tool.MemorySave.parameters())
    end

    test "MemorySearch implements Tool behaviour" do
      assert Synapsis.Tool.MemorySearch.name() == "memory_search"
      assert Synapsis.Tool.MemorySearch.category() == :memory
      assert Synapsis.Tool.MemorySearch.permission_level() == :read
      assert Synapsis.Tool.MemorySearch.side_effects() == []
    end

    test "MemoryUpdate implements Tool behaviour" do
      assert Synapsis.Tool.MemoryUpdate.name() == "memory_update"
      assert Synapsis.Tool.MemoryUpdate.category() == :memory
      assert Synapsis.Tool.MemoryUpdate.permission_level() == :write
      assert Synapsis.Tool.MemoryUpdate.side_effects() == [:memory_updated]
    end

    test "SessionSummarize implements Tool behaviour" do
      assert Synapsis.Tool.SessionSummarize.name() == "session_summarize"
      assert Synapsis.Tool.SessionSummarize.category() == :memory
      assert Synapsis.Tool.SessionSummarize.permission_level() == :read
    end
  end
end
