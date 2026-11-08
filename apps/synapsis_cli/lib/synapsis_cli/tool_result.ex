defmodule SynapsisCli.ToolResult do
  @moduledoc false

  @preview_limit 500
  @truncation "\n[truncated]"
  @sidecars [
    {"structured", "Structured"},
    {"artifacts", "Artifacts"},
    {"details", "Details"},
    {"progress", "Progress"},
    {"pagination", "Pagination"}
  ]

  # This checks display shapes only. Runtime admission and public-result
  # sanitization belong to the server; no media or references are dispatched.
  def preview(%{"projection" => projection, "is_error" => is_error})
      when is_map(projection) and map_size(projection) == 2 and is_boolean(is_error) do
    with %{"version" => version, "result" => result} when version === 1 and is_map(result) <-
           projection,
         true <- result["is_error"] === is_error,
         {:ok, content} <- content_lines(Map.get(result, "content")),
         {:ok, error} <- error_lines(Map.get(result, "error")) do
      sidecars =
        Enum.flat_map(@sidecars, fn {key, label} ->
          case Map.get(result, key) do
            nil -> []
            value -> [label <> ": " <> Jason.encode!(value)]
          end
        end)

      text = Enum.join(content ++ error ++ sidecars, "\n")
      {is_error, truncate(text)}
    else
      _invalid -> invalid()
    end
  end

  def preview(_event), do: invalid()

  defp content_lines(nil), do: {:ok, []}
  defp content_lines(content) when is_binary(content), do: {:ok, [content]}
  defp content_lines(content) when is_map(content), do: {:ok, ["[unsupported content: object]"]}

  defp content_lines(content) when is_list(content) do
    Enum.reduce_while(content, {:ok, []}, fn block, {:ok, lines} ->
      case content_line(block) do
        {:ok, line} -> {:cont, {:ok, [line | lines]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      :error -> :error
    end
  end

  defp content_lines(_content), do: :error

  defp content_line(%{"type" => "text", "text" => text}) when is_binary(text),
    do: {:ok, text}

  defp content_line(%{"type" => "text"}), do: :error

  defp content_line(%{
         "type" => "image",
         "data" => %{"source" => source, "media_type" => mime}
       })
       when is_binary(source) and is_binary(mime),
       do: {:ok, "[image: #{mime}; source: #{source}]"}

  defp content_line(%{"type" => "image", "data" => data, "mimeType" => mime})
       when is_binary(data) and is_binary(mime),
       do: {:ok, "[image: #{mime}; source: base64]"}

  defp content_line(%{"type" => "image"}), do: :error

  defp content_line(%{"type" => type}) when is_binary(type),
    do: {:ok, "[unsupported content: #{type}]"}

  defp content_line(_block), do: :error

  defp error_lines(nil), do: {:ok, []}

  defp error_lines(%{"class" => class, "message" => message} = error)
       when is_binary(class) and is_binary(message) do
    lines = ["Error class: " <> class, "Error message: " <> message]

    case Map.get(error, "details") do
      nil -> {:ok, lines}
      details -> {:ok, lines ++ ["Error details: " <> Jason.encode!(details)]}
    end
  end

  defp error_lines(_error), do: :error

  defp truncate(text) do
    if String.length(text) > @preview_limit do
      String.slice(text, 0, @preview_limit - String.length(@truncation)) <> @truncation
    else
      text
    end
  end

  defp invalid, do: {true, "Tool result display error: invalid projection"}
end
