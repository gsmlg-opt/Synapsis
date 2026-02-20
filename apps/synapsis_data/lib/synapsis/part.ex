defmodule Synapsis.Part do
  @moduledoc """
  Custom Ecto type for polymorphic message parts.
  Serializes tagged structs to/from JSONB.
  """
  use Ecto.Type

  def type, do: :map

  def cast(%{} = part), do: {:ok, cast_part(part)}
  def cast(part) when is_struct(part), do: {:ok, part}
  def cast(_), do: :error

  def load(%{} = data), do: {:ok, load_part(data)}
  def load(nil), do: {:ok, nil}
  def load(_), do: :error

  def dump(%{} = part) when is_struct(part), do: {:ok, dump_part(part)}
  def dump(%{} = part), do: {:ok, dump_part(cast_part(part))}
  def dump(nil), do: {:ok, nil}
  def dump(_), do: :error

  def equal?(a, b), do: a == b

  # Load from DB (string keys) -> struct
  defp load_part(%{"type" => "text"} = data) do
    %Synapsis.Part.Text{content: data["content"] || ""}
  end

  defp load_part(%{"type" => "tool_use"} = data) do
    %Synapsis.Part.ToolUse{
      tool: data["tool"],
      tool_use_id: data["tool_use_id"],
      input: data["input"] || %{},
      status: load_atom(data["status"], :pending)
    }
  end

  defp load_part(%{"type" => "tool_result"} = data) do
    %Synapsis.Part.ToolResult{
      tool_use_id: data["tool_use_id"],
      content: data["content"] || "",
      is_error: data["is_error"] || false
    }
  end

  defp load_part(%{"type" => "reasoning"} = data) do
    %Synapsis.Part.Reasoning{content: data["content"] || ""}
  end

  defp load_part(%{"type" => "image"} = data) do
    %Synapsis.Part.Image{
      media_type: data["media_type"] || "image/png",
      data: data["data"] || "",
      path: data["path"]
    }
  end

  defp load_part(%{"type" => "file"} = data) do
    %Synapsis.Part.File{path: data["path"], content: data["content"] || ""}
  end

  defp load_part(%{"type" => "snapshot"} = data) do
    %Synapsis.Part.Snapshot{files: data["files"] || []}
  end

  defp load_part(%{"type" => "agent"} = data) do
    %Synapsis.Part.Agent{agent: data["agent"], message: data["message"] || ""}
  end

  defp load_part(data) when is_map(data) do
    %Synapsis.Part.Text{content: inspect(data)}
  end

  # Dump struct -> DB (string keys)
  defp dump_part(%Synapsis.Part.Text{content: content}) do
    %{"type" => "text", "content" => content}
  end

  defp dump_part(%Synapsis.Part.ToolUse{} = p) do
    %{
      "type" => "tool_use",
      "tool" => p.tool,
      "tool_use_id" => p.tool_use_id,
      "input" => p.input,
      "status" => to_string(p.status)
    }
  end

  defp dump_part(%Synapsis.Part.ToolResult{} = p) do
    %{
      "type" => "tool_result",
      "tool_use_id" => p.tool_use_id,
      "content" => p.content,
      "is_error" => p.is_error
    }
  end

  defp dump_part(%Synapsis.Part.Reasoning{content: content}) do
    %{"type" => "reasoning", "content" => content}
  end

  defp dump_part(%Synapsis.Part.Image{} = p) do
    %{
      "type" => "image",
      "media_type" => p.media_type,
      "data" => p.data,
      "path" => p.path
    }
  end

  defp dump_part(%Synapsis.Part.File{path: path, content: content}) do
    %{"type" => "file", "path" => path, "content" => content}
  end

  defp dump_part(%Synapsis.Part.Snapshot{files: files}) do
    %{"type" => "snapshot", "files" => files}
  end

  defp dump_part(%Synapsis.Part.Agent{agent: agent, message: message}) do
    %{"type" => "agent", "agent" => agent, "message" => message}
  end

  # Cast from external input (atom or string keys) -> struct
  defp cast_part(%{"type" => _} = data), do: load_part(data)

  defp cast_part(%{type: _} = data) do
    data
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> load_part()
  end

  defp cast_part(data) when is_struct(data), do: data

  defp load_atom(nil, default), do: default
  defp load_atom(val, _default) when is_atom(val), do: val
  defp load_atom(val, _default) when is_binary(val), do: String.to_existing_atom(val)
end
