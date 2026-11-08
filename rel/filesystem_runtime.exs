defmodule Synapsis.Release.FilesystemRuntime do
  @moduledoc false

  @spec bundle(Mix.Release.t()) :: Mix.Release.t()
  def bundle(%Mix.Release{} = release) do
    source = System.fetch_env!("SYNAPSIS_FILESYSTEM_RUNTIME_ROOT")
    destination = Path.join(release.version_path, "filesystem-node")
    source_node = Path.join(source, "bin/node")
    destination_node = Path.join(destination, "bin/node")

    File.mkdir_p!(Path.dirname(destination_node))
    File.cp!(source_node, destination_node)
    File.chmod!(destination_node, Bitwise.band(File.stat!(source_node).mode, 0o777))
    File.cp!(Path.join(source, "LICENSE"), Path.join(destination, "LICENSE"))
    release
  end
end
