defmodule Synapsis.Workspace.BlobStore.LocalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.BlobStore.Local

  @test_root Path.join(System.tmp_dir!(), "synapsis_blob_test_#{:rand.uniform(100_000)}")

  setup do
    Application.put_env(:synapsis_workspace, :blob_store_root, @test_root)

    on_exit(fn ->
      File.rm_rf!(@test_root)
      Application.delete_env(:synapsis_workspace, :blob_store_root)
    end)

    :ok
  end

  describe "put/1" do
    test "stores content and returns SHA-256 ref" do
      content = "Hello, workspace!"
      assert {:ok, ref} = Local.put(content)
      assert is_binary(ref)
      assert String.length(ref) == 64
      assert ref == :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    end

    test "stores content at correct path" do
      {:ok, ref} = Local.put("test content")
      <<a::binary-size(2), b::binary-size(2), rest::binary>> = ref
      expected_path = Path.join([@test_root, a, b, rest])
      assert File.exists?(expected_path)
    end

    test "deduplicates identical content" do
      content = "duplicate content"
      {:ok, ref1} = Local.put(content)
      {:ok, ref2} = Local.put(content)
      assert ref1 == ref2
    end

    test "handles empty content" do
      assert {:ok, ref} = Local.put("")
      assert is_binary(ref)
    end

    test "handles large binary content" do
      content = :crypto.strong_rand_bytes(128 * 1024)
      assert {:ok, ref} = Local.put(content)
      assert {:ok, ^content} = Local.get(ref)
    end
  end

  describe "get/1" do
    test "retrieves stored content" do
      content = "retrievable content"
      {:ok, ref} = Local.put(content)
      assert {:ok, ^content} = Local.get(ref)
    end

    test "returns not_found for missing ref" do
      fake_ref = String.duplicate("ab", 32)
      assert {:error, :not_found} = Local.get(fake_ref)
    end
  end

  describe "delete/1" do
    test "removes stored blob" do
      {:ok, ref} = Local.put("to delete")
      assert :ok = Local.delete(ref)
      assert {:error, :not_found} = Local.get(ref)
    end

    test "delete of missing ref returns ok" do
      fake_ref = String.duplicate("cd", 32)
      assert :ok = Local.delete(fake_ref)
    end
  end

  describe "exists?/1" do
    test "returns true for stored blob" do
      {:ok, ref} = Local.put("exists check")
      assert Local.exists?(ref) == true
    end

    test "returns false for missing blob" do
      fake_ref = String.duplicate("ef", 32)
      assert Local.exists?(fake_ref) == false
    end
  end
end
