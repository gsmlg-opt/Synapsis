defmodule Synapsis.Git.BranchTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.Branch

  defp create_bare_repo(base) do
    src = Path.join(base, "src")
    File.mkdir_p!(src)
    System.cmd("git", ["init"], cd: src)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: src)
    System.cmd("git", ["config", "user.name", "Test"], cd: src)
    File.write!(Path.join(src, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: src)
    System.cmd("git", ["commit", "-m", "initial"], cd: src)

    bare = Path.join(base, "bare.git")
    System.cmd("git", ["clone", "--bare", src, bare])
    bare
  end

  setup do
    base =
      Path.join(System.tmp_dir!(), "branch_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    bare = create_bare_repo(base)
    {:ok, bare: bare}
  end

  describe "create/3" do
    test "creates a branch from a base ref", %{bare: bare} do
      assert :ok = Branch.create(bare, "feature/new", "HEAD")
      assert Branch.exists?(bare, "feature/new")
    end

    test "returns error if branch already exists", %{bare: bare} do
      :ok = Branch.create(bare, "existing", "HEAD")
      assert {:error, _} = Branch.create(bare, "existing", "HEAD")
    end

    test "returns error if base ref is nonexistent", %{bare: bare} do
      assert {:error, _} = Branch.create(bare, "from-ghost", "refs/heads/nonexistent_branch")
    end
  end

  describe "list/1" do
    test "returns at least the default branch", %{bare: bare} do
      {:ok, branches} = Branch.list(bare)
      assert is_list(branches)
      assert length(branches) >= 1
    end

    test "includes newly created branch", %{bare: bare} do
      :ok = Branch.create(bare, "listed-branch", "HEAD")
      {:ok, branches} = Branch.list(bare)
      assert "listed-branch" in branches
    end
  end

  describe "exists?/2" do
    test "returns true for the default branch", %{bare: bare} do
      {:ok, [default | _]} = Branch.list(bare)
      assert Branch.exists?(bare, default)
    end

    test "returns false for nonexistent branch", %{bare: bare} do
      refute Branch.exists?(bare, "no-such-branch")
    end
  end

  describe "delete/3" do
    test "deletes a branch with force", %{bare: bare} do
      :ok = Branch.create(bare, "to-delete", "HEAD")
      assert :ok = Branch.delete(bare, "to-delete", true)
      refute Branch.exists?(bare, "to-delete")
    end

    test "returns error when deleting non-existent branch", %{bare: bare} do
      assert {:error, _} = Branch.delete(bare, "no-such", false)
    end
  end
end
