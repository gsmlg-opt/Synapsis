defmodule Synapsis.Tool.E2ETest do
  use ExUnit.Case

  alias Synapsis.Tool.{Executor, Registry}

  @test_dir System.tmp_dir!() |> Path.join("synapsis_e2e_test_#{:rand.uniform(100_000)}")

  setup do
    File.mkdir_p!(@test_dir)

    File.write!(
      Path.join(@test_dir, "sample.txt"),
      "line one\nline two\nline three\nfind_me_marker\n"
    )

    File.write!(
      Path.join(@test_dir, "editable.txt"),
      "alpha beta gamma\n"
    )

    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "builtin tools are registered" do
    test "core tools are available in registry" do
      for name <- ["file_read", "file_edit", "grep", "glob", "bash", "file_write"] do
        assert {:ok, {:module, _mod, _opts}} = Registry.lookup(name),
               "Expected builtin tool #{inspect(name)} to be registered"
      end
    end
  end

  describe "grep tool via Executor" do
    test "finds a pattern in a temp file" do
      {:ok, output} =
        Executor.execute("grep", %{"pattern" => "find_me_marker", "path" => @test_dir}, %{
          project_path: @test_dir
        })

      assert output =~ "find_me_marker"
      assert output =~ "sample.txt"
    end

    test "returns no matches for absent pattern" do
      {:ok, output} =
        Executor.execute("grep", %{"pattern" => "ZZZZZ_NOT_HERE", "path" => @test_dir}, %{
          project_path: @test_dir
        })

      assert output =~ "No matches"
    end
  end

  describe "file_read tool via Executor" do
    test "reads temp file contents" do
      {:ok, content} =
        Executor.execute("file_read", %{"path" => "sample.txt"}, %{
          project_path: @test_dir
        })

      assert content =~ "line one"
      assert content =~ "find_me_marker"
    end

    test "reads with offset and limit" do
      {:ok, content} =
        Executor.execute(
          "file_read",
          %{"path" => "sample.txt", "offset" => 1, "limit" => 1},
          %{project_path: @test_dir}
        )

      assert content == "line two"
    end
  end

  describe "file_edit tool via Executor" do
    test "edits temp file content" do
      {:ok, result} =
        Executor.execute(
          "file_edit",
          %{"path" => "editable.txt", "old_string" => "beta", "new_string" => "BETA"},
          %{project_path: @test_dir}
        )

      assert result =~ "ok"

      # Verify the file was actually modified
      updated = File.read!(Path.join(@test_dir, "editable.txt"))
      assert updated =~ "BETA"
      refute updated =~ "beta"
    end
  end

  describe "independent tool calls work in sequence" do
    test "grep then file_read then file_edit pipeline" do
      # Step 1: grep to find the file containing the marker
      {:ok, grep_output} =
        Executor.execute("grep", %{"pattern" => "find_me_marker"}, %{
          project_path: @test_dir
        })

      assert grep_output =~ "sample.txt"

      # Step 2: file_read to get the file content
      {:ok, content} =
        Executor.execute("file_read", %{"path" => "sample.txt"}, %{
          project_path: @test_dir
        })

      assert content =~ "find_me_marker"

      # Step 3: file_edit to modify the file
      {:ok, _} =
        Executor.execute(
          "file_edit",
          %{
            "path" => "sample.txt",
            "old_string" => "find_me_marker",
            "new_string" => "found_and_replaced"
          },
          %{project_path: @test_dir}
        )

      # Verify end-to-end result
      final = File.read!(Path.join(@test_dir, "sample.txt"))
      assert final =~ "found_and_replaced"
      refute final =~ "find_me_marker"
    end
  end

  describe "tool calls are independent" do
    test "one tool failure does not affect another" do
      # Failing call: read nonexistent file
      {:error, _} =
        Executor.execute("file_read", %{"path" => "nonexistent.txt"}, %{
          project_path: @test_dir
        })

      # Succeeding call: read existing file
      {:ok, content} =
        Executor.execute("file_read", %{"path" => "sample.txt"}, %{
          project_path: @test_dir
        })

      assert content =~ "line one"
    end
  end

  describe "glob tool via Executor" do
    test "finds files matching pattern" do
      {:ok, output} =
        Executor.execute("glob", %{"pattern" => "**/*.txt"}, %{
          project_path: @test_dir
        })

      assert output =~ "sample.txt"
      assert output =~ "editable.txt"
    end
  end
end
