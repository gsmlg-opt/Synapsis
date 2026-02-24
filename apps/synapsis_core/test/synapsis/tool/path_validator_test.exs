defmodule Synapsis.Tool.PathValidatorTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.PathValidator

  @project_root "/tmp/synapsis_validator_test"

  describe "validate/2" do
    test "allows nil project_path (no restriction)" do
      assert :ok = PathValidator.validate("/anywhere/file.txt", nil)
    end

    test "allows path equal to project root" do
      assert :ok = PathValidator.validate(@project_root, @project_root)
    end

    test "allows path inside project root" do
      assert :ok = PathValidator.validate("#{@project_root}/src/foo.ex", @project_root)
    end

    test "allows deeply nested path" do
      assert :ok = PathValidator.validate("#{@project_root}/a/b/c/d.txt", @project_root)
    end

    test "rejects path outside project root" do
      assert {:error, msg} = PathValidator.validate("/etc/passwd", @project_root)
      assert msg =~ "outside project root"
    end

    test "rejects sibling directory (prefix attack)" do
      # /tmp/synapsis_validator_test_evil must NOT match /tmp/synapsis_validator_test
      sibling = @project_root <> "_evil"
      assert {:error, msg} = PathValidator.validate(sibling, @project_root)
      assert msg =~ "outside project root"
    end

    test "rejects relative traversal path" do
      traversal = "#{@project_root}/../../etc/passwd"
      assert {:error, msg} = PathValidator.validate(traversal, @project_root)
      assert msg =~ "outside project root"
    end

    test "handles Path.expand for relative paths with dot segments" do
      # Path.expand resolves .., so ../../etc/passwd expands to /etc/passwd
      assert {:error, _} =
               PathValidator.validate("#{@project_root}/../outside.txt", @project_root)
    end

    test "rejects double-dot traversal at start" do
      assert {:error, _} = PathValidator.validate("../../etc/shadow", @project_root)
    end

    test "allows current directory reference with dot" do
      assert :ok = PathValidator.validate("#{@project_root}/./file.txt", @project_root)
    end

    test "rejects path with project root as substring prefix" do
      assert {:error, _} =
               PathValidator.validate("#{@project_root}_malicious/file.txt", @project_root)
    end
  end
end
