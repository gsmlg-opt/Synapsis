defmodule Synapsis.Workspace.PathResolverAdditionsTest do
  use ExUnit.Case, async: true

  alias Synapsis.Workspace.PathResolver

  describe "derive_kind/1 — new resource kinds" do
    test "board.yaml -> :board" do
      assert PathResolver.derive_kind(["board.yaml"]) == :board
    end

    test "plans/auth.md -> :plan" do
      assert PathResolver.derive_kind(["plans", "auth.md"]) == :plan
    end

    test "plans/subdirectory/file.md -> :plan" do
      assert PathResolver.derive_kind(["plans", "subdirectory", "file.md"]) == :plan
    end

    test "plans alone -> :plan" do
      assert PathResolver.derive_kind(["plans"]) == :plan
    end

    test "design/architecture.md -> :design_doc" do
      assert PathResolver.derive_kind(["design", "architecture.md"]) == :design_doc
    end

    test "design/subdirectory/diagram.md -> :design_doc" do
      assert PathResolver.derive_kind(["design", "sub", "diagram.md"]) == :design_doc
    end

    test "design alone -> :design_doc" do
      assert PathResolver.derive_kind(["design"]) == :design_doc
    end

    test "logs/devlog.md -> :devlog" do
      assert PathResolver.derive_kind(["logs", "devlog.md"]) == :devlog
    end

    test "repos/{repo_id}/config.yaml -> :repo_config" do
      assert PathResolver.derive_kind(["repos", "some-repo-id", "config.yaml"]) == :repo_config
    end

    test "repos/abc123/config.yaml -> :repo_config" do
      assert PathResolver.derive_kind(["repos", "abc123", "config.yaml"]) == :repo_config
    end
  end

  describe "derive_kind/1 — existing kinds still work" do
    test "attachments/* -> :attachment" do
      assert PathResolver.derive_kind(["attachments", "image.png"]) == :attachment
    end

    test "handoffs/* -> :handoff" do
      assert PathResolver.derive_kind(["handoffs", "summary.md"]) == :handoff
    end

    test "scratch/* -> :session_scratch" do
      assert PathResolver.derive_kind(["scratch", "notes.md"]) == :session_scratch
    end

    test "unknown -> :document" do
      assert PathResolver.derive_kind(["notes.md"]) == :document
      assert PathResolver.derive_kind(["some", "random", "path.txt"]) == :document
      assert PathResolver.derive_kind([]) == :document
    end
  end

  describe "derive_kind/1 — non-matching similar paths" do
    test "logs/other.md -> :document (not devlog)" do
      assert PathResolver.derive_kind(["logs", "other.md"]) == :document
    end

    test "repos/id/other.yaml -> :document (not repo_config)" do
      assert PathResolver.derive_kind(["repos", "id", "other.yaml"]) == :document
    end

    test "repos/config.yaml -> :document (no repo_id segment)" do
      assert PathResolver.derive_kind(["repos", "config.yaml"]) == :document
    end
  end
end
