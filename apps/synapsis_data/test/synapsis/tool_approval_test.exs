defmodule Synapsis.ToolApprovalTest do
  use Synapsis.DataCase

  alias Synapsis.ToolApproval

  @valid_attrs %{
    pattern: "file_read",
    scope: :global,
    policy: :allow,
    created_by: :user
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = ToolApproval.changeset(%ToolApproval{}, @valid_attrs)
      assert changeset.valid?
    end

    test "validates pattern is required" do
      attrs = Map.delete(@valid_attrs, :pattern)
      changeset = ToolApproval.changeset(%ToolApproval{}, attrs)
      refute changeset.valid?
    end

    test "validates policy enum" do
      attrs = Map.put(@valid_attrs, :policy, :invalid)
      changeset = ToolApproval.changeset(%ToolApproval{}, attrs)
      refute changeset.valid?
    end

    test "inserts valid approval" do
      {:ok, approval} =
        %ToolApproval{}
        |> ToolApproval.changeset(@valid_attrs)
        |> Repo.insert()

      assert approval.pattern == "file_read"
      assert approval.policy == :allow
    end
  end

  describe "matches?/3" do
    test "exact tool name matches" do
      approval = %ToolApproval{pattern: "file_read"}
      assert ToolApproval.matches?(approval, "file_read", %{})
    end

    test "exact tool name does not match different tool" do
      approval = %ToolApproval{pattern: "file_read"}
      refute ToolApproval.matches?(approval, "file_write", %{})
    end

    test "wildcard tool matches any tool" do
      approval = %ToolApproval{pattern: "*"}
      assert ToolApproval.matches?(approval, "anything", %{})
    end

    test "tool with argument glob matches" do
      approval = %ToolApproval{pattern: "shell_exec:git *"}
      assert ToolApproval.matches?(approval, "shell_exec", %{"cmd" => "git push"})
    end

    test "tool with argument glob does not match non-matching args" do
      approval = %ToolApproval{pattern: "shell_exec:git *"}
      refute ToolApproval.matches?(approval, "shell_exec", %{"cmd" => "rm -rf /"})
    end

    test "wildcard argument matches any input" do
      approval = %ToolApproval{pattern: "file_read:*"}
      assert ToolApproval.matches?(approval, "file_read", %{"path" => "/any/path"})
    end

    test "double-star glob matches nested paths" do
      approval = %ToolApproval{pattern: "file_write:/projects/**/src/**"}

      assert ToolApproval.matches?(approval, "file_write", %{"path" => "/projects/foo/src/bar.ex"})
    end
  end
end
