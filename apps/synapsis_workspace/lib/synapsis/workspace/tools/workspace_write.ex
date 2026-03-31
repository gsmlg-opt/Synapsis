defmodule Synapsis.Workspace.Tools.WorkspaceWrite do
  @moduledoc "Write content to the shared workspace."
  use Synapsis.Tool

  @impl true
  def name, do: "workspace_write"

  @impl true
  def permission_level, do: :write

  @impl true
  def category, do: :workspace

  @impl true
  def description do
    "Write a document to the shared workspace. Creates or updates plans, todos, notes, handoffs, and other workspace artifacts. Auto-creates parent directories."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Workspace path (e.g. /projects/myapp/plans/auth-redesign.md)"
        },
        "content" => %{
          "type" => "string",
          "description" => "Content to write"
        },
        "metadata" => %{
          "type" => "object",
          "description" => "Optional metadata (title, tags, etc.)"
        },
        "content_format" => %{
          "type" => "string",
          "enum" => ["markdown", "yaml", "json", "text"],
          "description" => "Content format (default: markdown)"
        }
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(input, context) do
    path = input["path"]
    content = input["content"]
    author = context[:agent_id] || context[:session_id] || "agent"

    agent_ctx = build_agent_context(context)

    with :allowed <- Synapsis.Workspace.Permissions.check(agent_ctx, path, :write) do
      opts =
        %{author: author}
        |> maybe_put(:metadata, input["metadata"])
        |> maybe_put(:content_format, parse_format(input["content_format"]))

      case Synapsis.Workspace.write(path, content, opts) do
        {:ok, resource} ->
          {:ok,
           Jason.encode!(%{
             id: resource.id,
             path: resource.path,
             version: resource.version,
             lifecycle: resource.lifecycle
           })}

        {:error, %Ecto.Changeset{} = changeset} ->
          errors =
            Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
              Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
                atom_key =
                  try do
                    String.to_existing_atom(key)
                  rescue
                    ArgumentError -> nil
                  end

                (if(atom_key, do: Keyword.get(opts, atom_key), else: nil) || key) |> to_string()
              end)
            end)
            |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

          {:error, "Write failed: #{errors}"}

        {:error, _reason} ->
          {:error, "Write failed"}
      end
    else
      :denied -> {:error, "Permission denied: cannot write to #{path}"}
    end
  end

  defp build_agent_context(context) do
    %{
      role: context[:role] || :user,
      project_id: context[:project_id],
      session_id: context[:session_id]
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_format("markdown"), do: :markdown
  defp parse_format("yaml"), do: :yaml
  defp parse_format("json"), do: :json
  defp parse_format("text"), do: :text
  defp parse_format(_), do: nil
end
