defmodule Synapsis.MessageBuilder do
  @moduledoc "Builds provider-specific requests from session history."

  def build_request(messages, agent, provider_name) do
    provider_module = provider_module!(provider_name)

    tools =
      (agent[:tools] || [])
      |> Enum.map(&tool_definition/1)
      |> Enum.reject(&is_nil/1)

    opts = %{
      model: agent[:model],
      system_prompt: agent[:system_prompt],
      max_tokens: agent[:max_tokens] || 8192
    }

    provider_module.format_request(messages, tools, opts)
  end

  defp provider_module!(provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, mod} -> mod
      {:error, _} -> Synapsis.Provider.Anthropic
    end
  end

  defp tool_definition(tool_name) when is_binary(tool_name) do
    case Synapsis.Tool.Registry.get(tool_name) do
      {:ok, tool} -> tool
      {:error, _} -> nil
    end
  end

  defp tool_definition(tool_name) when is_atom(tool_name) do
    tool_definition(to_string(tool_name))
  end

  defp tool_definition(_), do: nil
end
