defmodule Synapsis.Tool.FileMove do
  @moduledoc "Move/rename a file."
  use Synapsis.Tool

  @impl true
  def name, do: "file_move"

  @impl true
  def description, do: "Move or rename a file from source to destination."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string", "description" => "Source file path"},
        "destination" => %{"type" => "string", "description" => "Destination file path"}
      },
      "required" => ["source", "destination"]
    }
  end

  @impl true
  def execute(input, context) do
    source = input["source"]
    dest = input["destination"]

    src_virtual = Synapsis.Tool.VFS.virtual?(source)
    dst_virtual = Synapsis.Tool.VFS.virtual?(dest)

    cond do
      src_virtual != dst_virtual ->
        {:error, "Cannot move between real filesystem and @synapsis/ workspace"}

      src_virtual and dst_virtual ->
        Synapsis.Tool.VFS.move(source, dest)

      true ->
        resolved_src = resolve_path(source, context[:project_path])
        resolved_dst = resolve_path(dest, context[:project_path])

        with :ok <- Synapsis.Tool.PathValidator.validate(resolved_src, context[:project_path]),
             :ok <- Synapsis.Tool.PathValidator.validate(resolved_dst, context[:project_path]) do
          if File.exists?(resolved_src) do
            with :ok <- File.mkdir_p(Path.dirname(resolved_dst)),
                 :ok <- File.rename(resolved_src, resolved_dst) do
              {:ok, "Moved #{resolved_src} to #{resolved_dst}"}
            else
              {:error, reason} ->
                {:error, "Failed to move #{resolved_src} to #{resolved_dst}: #{inspect(reason)}"}
            end
          else
            {:error, "Source file does not exist: #{resolved_src}"}
          end
        end
    end
  end

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :filesystem

  @impl true
  def side_effects, do: [:file_changed]

  defp resolve_path(path, project_path) do
    if Path.type(path) == :absolute, do: path, else: Path.join(project_path || ".", path)
  end
end
