defmodule SynapsisServer.ReleaseArtifactTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../../../..", __DIR__)

  test "every Mix project exposes the version attribute used by release stamping" do
    mix_projects =
      [Path.join(@project_root, "mix.exs") | Path.wildcard(Path.join(@project_root, "apps/*/mix.exs"))]

    Enum.each(mix_projects, fn path ->
      source = File.read!(path)
      relative_path = Path.relative_to(path, @project_root)

      assert source =~ ~r/^\s*@version\s+"[^"]+"/m,
             "#{relative_path} must declare @version for release stamping"

      assert source =~ ~r/version:\s*@version/,
             "#{relative_path} must use @version in project/0"
    end)
  end
end
