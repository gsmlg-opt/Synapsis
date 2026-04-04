defmodule Synapsis.Git.RepoOpsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Git.RepoOps

  # Creates a local git repo with one commit that can be used as a clone source
  defp create_source_repo(base_dir) do
    src = Path.join(base_dir, "source")
    File.mkdir_p!(src)
    System.cmd("git", ["init"], cd: src)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: src)
    System.cmd("git", ["config", "user.name", "Test"], cd: src)
    File.write!(Path.join(src, "README.md"), "# Source")
    System.cmd("git", ["add", "."], cd: src)
    System.cmd("git", ["commit", "-m", "initial"], cd: src)
    src
  end

  setup do
    base =
      Path.join(System.tmp_dir!(), "repo_ops_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    src = create_source_repo(base)
    {:ok, base: base, src: src}
  end

  describe "clone_bare/2" do
    test "clones a local repo as bare", %{base: base, src: src} do
      bare = Path.join(base, "clones/bare_repo.git")
      assert :ok = RepoOps.clone_bare(src, bare)
      assert File.dir?(bare)
      # bare repo has HEAD file
      assert File.exists?(Path.join(bare, "HEAD"))
    end

    test "creates parent directories automatically", %{base: base, src: src} do
      bare = Path.join(base, "deep/nested/dirs/repo.git")
      assert :ok = RepoOps.clone_bare(src, bare)
      assert File.dir?(bare)
    end

    test "returns error on invalid URL", %{base: base} do
      bare = Path.join(base, "bad_clone.git")
      assert {:error, reason} = RepoOps.clone_bare("/nonexistent_source_repo", bare)
      assert is_binary(reason)
    end
  end

  describe "add_remote/3" do
    setup %{base: base, src: src} do
      bare = Path.join(base, "bare.git")
      :ok = RepoOps.clone_bare(src, bare)
      {:ok, bare: bare}
    end

    test "adds a named remote", %{bare: bare} do
      assert :ok = RepoOps.add_remote(bare, "upstream", "https://example.com/repo.git")
    end

    test "returns error on duplicate remote", %{bare: bare} do
      :ok = RepoOps.add_remote(bare, "dup", "https://example.com/a.git")
      assert {:error, _reason} = RepoOps.add_remote(bare, "dup", "https://example.com/b.git")
    end
  end

  describe "remove_remote/2" do
    setup %{base: base, src: src} do
      bare = Path.join(base, "bare_rm.git")
      :ok = RepoOps.clone_bare(src, bare)
      :ok = RepoOps.add_remote(bare, "to_remove", "https://example.com/repo.git")
      {:ok, bare: bare}
    end

    test "removes an existing remote", %{bare: bare} do
      assert :ok = RepoOps.remove_remote(bare, "to_remove")
    end

    test "returns error for non-existent remote", %{bare: bare} do
      assert {:error, _} = RepoOps.remove_remote(bare, "nonexistent")
    end
  end

  describe "fetch_all/1" do
    setup %{base: base, src: src} do
      bare = Path.join(base, "bare_fetch.git")
      :ok = RepoOps.clone_bare(src, bare)
      {:ok, bare: bare}
    end

    test "fetches successfully", %{bare: bare} do
      assert :ok = RepoOps.fetch_all(bare)
    end
  end

  describe "set_push_url/3" do
    setup %{base: base, src: src} do
      bare = Path.join(base, "bare_push.git")
      :ok = RepoOps.clone_bare(src, bare)
      {:ok, bare: bare}
    end

    test "sets push URL for existing remote", %{bare: bare} do
      assert :ok = RepoOps.set_push_url(bare, "origin", "https://push.example.com/repo.git")
    end
  end
end
