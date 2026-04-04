defmodule Synapsis.Agent.ApprovalTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.Approval
  alias Synapsis.{ToolApproval, Repo}

  defp insert_approval(attrs) do
    %ToolApproval{}
    |> ToolApproval.changeset(attrs)
    |> Repo.insert!()
  end

  describe "check_approval/3" do
    test "returns :ask when no pattern matches (default)" do
      assert Approval.check_approval("file_read", %{}) == :ask
    end

    test "returns :allow for matching allow pattern" do
      insert_approval(%{
        pattern: "file_read",
        scope: :global,
        policy: :allow,
        created_by: :user
      })

      assert Approval.check_approval("file_read", %{}) == :allow
    end

    test "returns :record for matching record pattern" do
      insert_approval(%{
        pattern: "file_write",
        scope: :global,
        policy: :record,
        created_by: :user
      })

      assert Approval.check_approval("file_write", %{}) == :record
    end

    test "returns :deny for matching deny pattern" do
      insert_approval(%{
        pattern: "shell_exec",
        scope: :global,
        policy: :deny,
        created_by: :system
      })

      assert Approval.check_approval("shell_exec", %{}) == :deny
    end

    test "most specific pattern wins" do
      insert_approval(%{
        pattern: "shell_exec",
        scope: :global,
        policy: :ask,
        created_by: :user
      })

      insert_approval(%{
        pattern: "shell_exec:git *",
        scope: :global,
        policy: :allow,
        created_by: :user
      })

      assert Approval.check_approval("shell_exec", %{"cmd" => "git push"}) == :allow
    end

    test "handles empty approvals table" do
      assert Approval.check_approval("anything", %{}) == :ask
    end

    test "project-scoped patterns checked first" do
      {:ok, project} =
        %Synapsis.Project{}
        |> Synapsis.Project.changeset(%{
          path: "/tmp/approval-test",
          slug: "approval-test",
          name: "approval-test"
        })
        |> Repo.insert()

      insert_approval(%{
        pattern: "file_read",
        scope: :global,
        policy: :ask,
        created_by: :user
      })

      insert_approval(%{
        pattern: "file_read",
        scope: :project,
        project_id: project.id,
        policy: :allow,
        created_by: :user
      })

      assert Approval.check_approval("file_read", %{}, project_id: project.id) == :allow
    end
  end

  describe "persist_approval/3" do
    test "inserts new approval" do
      assert {:ok, approval} = Approval.persist_approval("file_read", :allow)
      assert approval.pattern == "file_read"
      assert approval.policy == :allow
    end

    test "updates existing approval for same pattern" do
      Approval.persist_approval("file_read", :ask)
      assert {:ok, approval} = Approval.persist_approval("file_read", :allow)
      assert approval.policy == :allow

      # Should only have one record
      approvals = Approval.list_approvals()
      assert length(Enum.filter(approvals, &(&1.pattern == "file_read"))) == 1
    end
  end

  describe "list_approvals/1" do
    test "returns all approvals" do
      insert_approval(%{pattern: "a", scope: :global, policy: :allow, created_by: :user})
      insert_approval(%{pattern: "b", scope: :global, policy: :deny, created_by: :user})

      approvals = Approval.list_approvals()
      assert length(approvals) == 2
    end
  end

  describe "matches?/3" do
    test "exact tool name matches" do
      assert Approval.matches?("file_read", "file_read", %{})
    end

    test "exact tool name does not match different tool" do
      refute Approval.matches?("file_read", "file_write", %{})
    end

    test "wildcard tool matches any tool" do
      assert Approval.matches?("*", "anything", %{})
    end

    test "tool with argument glob matches" do
      assert Approval.matches?("shell_exec:git *", "shell_exec", %{"cmd" => "git push"})
    end

    test "tool with argument glob does not match non-matching args" do
      refute Approval.matches?("shell_exec:git *", "shell_exec", %{"cmd" => "rm -rf /"})
    end

    test "wildcard argument matches any input" do
      assert Approval.matches?("file_read:*", "file_read", %{"path" => "/any/path"})
    end

    test "double-star glob matches nested paths" do
      assert Approval.matches?(
               "file_write:/projects/**/src/**",
               "file_write",
               %{"path" => "/projects/foo/src/bar.ex"}
             )
    end
  end

  describe "delete_approval/1" do
    test "deletes an existing approval" do
      approval =
        insert_approval(%{pattern: "test", scope: :global, policy: :allow, created_by: :user})

      assert :ok = Approval.delete_approval(approval.id)
      assert Approval.list_approvals() == []
    end

    test "returns error for nonexistent approval" do
      assert {:error, :not_found} = Approval.delete_approval(Ecto.UUID.generate())
    end
  end
end
