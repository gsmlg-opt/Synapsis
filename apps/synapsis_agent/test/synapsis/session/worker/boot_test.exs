defmodule Synapsis.Session.Worker.BootTest do
  use ExUnit.Case, async: true

  alias Synapsis.Session.Worker.Boot

  @tag :tmp_dir
  test "creates missing agent workspace path before boot uses it", %{tmp_dir: tmp_dir} do
    workspace_path = Path.join(tmp_dir, "agents/main")

    refute File.exists?(workspace_path)
    assert {:ok, ^workspace_path} = Boot.ensure_workspace_path(workspace_path)
    assert File.dir?(workspace_path)
  end

  @tag :tmp_dir
  test "reports workspace path creation failures", %{tmp_dir: tmp_dir} do
    parent_file = Path.join(tmp_dir, "not-a-directory")
    File.write!(parent_file, "file")
    workspace_path = Path.join(parent_file, "main")

    assert {:error, {:workspace_unavailable, ^workspace_path, _reason}} =
             Boot.ensure_workspace_path(workspace_path)
  end
end
