defmodule Synapsis.MessageBuilder do
  @moduledoc "Builds provider-specific requests from session history."

  def build_request(messages, agent, provider_name) do
    provider_module = provider_module!(provider_name)

    tools = resolve_tools(agent[:tools])

    opts = %{
      model: agent[:model],
      system_prompt: agent[:system_prompt],
      max_tokens: agent[:max_tokens] || 8192,
      provider_type: provider_name
    }

    provider_module.format_request(messages, tools, opts)
  end

  defp provider_module!(provider_name) do
    case Synapsis.Provider.Registry.module_for(provider_name) do
      {:ok, mod} -> mod
      {:error, _} -> Synapsis.Provider.Adapter
    end
  end

  defp resolve_tools(nil), do: []
  defp resolve_tools(:all), do: Synapsis.Tool.Registry.list_for_llm()

  defp resolve_tools(tool_names) when is_list(tool_names) do
    all_tools = Synapsis.Tool.Registry.list_for_llm()

    all_tools
    |> Enum.filter(fn tool -> tool.name in tool_names end)
  end
end
