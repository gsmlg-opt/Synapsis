defmodule Synapsis.Provider.MessageMapper do
  @moduledoc """
  Pure functions for converting `Part.*` domain structs into provider-specific
  wire format request bodies.

  Two directions:
  - Outbound: `Part.*` messages → provider HTTP request body
  - Tool formatting per provider
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Build a provider-specific request body from domain messages, tools, and opts.

  `provider_type` is an atom: `:anthropic`, `:openai`, or `:google`.
  """
  def build_request(:anthropic, messages, tools, opts) do
    request = %{
      model: opts[:model] || Synapsis.Providers.default_model("anthropic"),
      max_tokens: opts[:max_tokens] || 8192,
      stream: true,
      messages: Enum.map(messages, &format_anthropic_message/1)
    }

    request =
      case opts[:system_prompt] do
        nil -> request
        prompt -> Map.put(request, :system, prompt)
      end

    case tools do
      [] -> request
      _ -> Map.put(request, :tools, Enum.map(tools, &format_anthropic_tool/1))
    end
  end

  def build_request(:openai, messages, tools, opts) do
    request = %{
      model: opts[:model] || Synapsis.Providers.default_model("openai"),
      stream: true,
      messages: format_openai_messages(messages, opts)
    }

    case tools do
      [] -> request
      _ -> Map.put(request, :tools, Enum.map(tools, &format_openai_tool/1))
    end
  end

  def build_request(:google, messages, tools, opts) do
    request = %{
      model: opts[:model] || Synapsis.Providers.default_model("google"),
      stream: true,
      contents: Enum.map(messages, &format_google_message/1)
    }

    request =
      case opts[:system_prompt] do
        nil -> request
        prompt -> Map.put(request, :systemInstruction, %{parts: [%{text: prompt}]})
      end

    case tools do
      [] ->
        request

      _ ->
        Map.put(request, :tools, [%{functionDeclarations: Enum.map(tools, &format_google_tool/1)}])
    end
  end

  # ---------------------------------------------------------------------------
  # Anthropic message formatting — native format, minimal transform
  # ---------------------------------------------------------------------------

  defp format_anthropic_message(%{role: role, parts: parts}) do
    %{role: to_string(role), content: Enum.map(parts, &format_anthropic_content/1)}
  end

  defp format_anthropic_message(%{"role" => role, "parts" => parts}) do
    %{role: role, content: Enum.map(parts, &format_anthropic_content/1)}
  end

  defp format_anthropic_content(%Synapsis.Part.Text{content: content}) do
    %{type: "text", text: content}
  end

  defp format_anthropic_content(%Synapsis.Part.ToolUse{tool: tool, tool_use_id: id, input: input}) do
    %{type: "tool_use", id: id, name: tool, input: input}
  end

  defp format_anthropic_content(%Synapsis.Part.ToolResult{
         tool_use_id: id,
         content: content,
         is_error: is_error
       }) do
    %{type: "tool_result", tool_use_id: id, content: content, is_error: is_error}
  end

  defp format_anthropic_content(%Synapsis.Part.Image{media_type: mt, data: data}) do
    %{
      type: "image",
      source: %{
        type: "base64",
        media_type: mt,
        data: data
      }
    }
  end

  defp format_anthropic_content(%Synapsis.Part.Reasoning{content: content}) do
    %{type: "text", text: "[thinking] #{content}"}
  end

  defp format_anthropic_content(%{content: content}) do
    %{type: "text", text: to_string(content)}
  end

  defp format_anthropic_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.parameters
    }
  end

  # ---------------------------------------------------------------------------
  # OpenAI message formatting — chat completions format
  # ---------------------------------------------------------------------------

  defp format_openai_messages(messages, opts) do
    system_messages =
      case opts[:system_prompt] do
        nil -> []
        prompt -> [%{role: "system", content: prompt}]
      end

    system_messages ++ Enum.map(messages, &format_openai_message/1)
  end

  defp format_openai_message(%{role: role, parts: parts}) do
    content_items = Enum.map(parts, &format_openai_content/1)
    content = merge_openai_content(content_items)
    %{role: to_string(role), content: content}
  end

  defp format_openai_message(%{"role" => role, "parts" => parts}) do
    content_items = Enum.map(parts, &format_openai_content/1)
    content = merge_openai_content(content_items)
    %{role: role, content: content}
  end

  defp format_openai_content(%Synapsis.Part.Text{content: content}), do: content

  defp format_openai_content(%Synapsis.Part.Image{media_type: mt, data: data}) do
    %{
      type: "image_url",
      image_url: %{
        url: "data:#{mt};base64,#{data}"
      }
    }
  end

  defp format_openai_content(%Synapsis.Part.ToolResult{content: content}), do: content
  defp format_openai_content(%{content: content}), do: to_string(content)

  defp merge_openai_content(items) do
    has_multimodal = Enum.any?(items, &is_map/1)

    if has_multimodal do
      # When images are present, use content array format
      Enum.map(items, fn
        text when is_binary(text) -> %{type: "text", text: text}
        map when is_map(map) -> map
      end)
    else
      merge_text_content(items)
    end
  end

  defp merge_text_content([single]) when is_binary(single), do: single
  defp merge_text_content(parts), do: Enum.join(parts, "\n")

  defp format_openai_tool(tool) do
    %{
      type: "function",
      function: %{
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    }
  end

  # ---------------------------------------------------------------------------
  # Google message formatting — Gemini API format
  # ---------------------------------------------------------------------------

  defp format_google_message(%{role: role, parts: parts}) do
    google_role = if to_string(role) == "assistant", do: "model", else: "user"
    %{role: google_role, parts: Enum.map(parts, &format_google_content/1)}
  end

  defp format_google_message(%{"role" => role, "parts" => parts}) do
    google_role = if role == "assistant", do: "model", else: "user"
    %{role: google_role, parts: Enum.map(parts, &format_google_content/1)}
  end

  defp format_google_content(%Synapsis.Part.Text{content: content}), do: %{text: content}

  defp format_google_content(%Synapsis.Part.Image{media_type: mt, data: data}) do
    %{
      inlineData: %{
        mimeType: mt,
        data: data
      }
    }
  end

  defp format_google_content(%{content: content}), do: %{text: to_string(content)}

  defp format_google_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  end
end
