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
end
