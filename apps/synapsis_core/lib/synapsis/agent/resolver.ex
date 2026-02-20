defmodule Synapsis.Agent.Resolver do
  @moduledoc "Resolves agent configuration by merging defaults with project overrides."

  def resolve(agent_name, project_config \\ %{}) do
    default = default_agent(to_string(agent_name))
    overrides = get_in(project_config, ["agents", to_string(agent_name)]) || %{}

    %{
      name: to_string(agent_name),
      model: overrides["model"] || default.model,
      provider: overrides["provider"] || default.provider,
      system_prompt: overrides["systemPrompt"] || default.system_prompt,
      tools: resolve_tools(default.tools, overrides["tools"]),
      reasoning_effort: overrides["reasoningEffort"] || default.reasoning_effort,
      read_only: Map.get(overrides, "readOnly", default.read_only),
      max_tokens: overrides["maxTokens"] || default.max_tokens
    }
  end

  defp default_agent("build") do
    %{
      model: nil,
      provider: nil,
      system_prompt: """
      You are Synapsis, an AI coding assistant. You help developers write, edit, and understand code.
      You have access to tools for reading files, editing files, running shell commands, and searching code.
      Always explain your reasoning before making changes. Be concise and precise.
      """,
      tools: [
        "file_read",
        "file_edit",
        "file_write",
        "bash",
        "grep",
        "glob",
        "diagnostics",
        "fetch"
      ],
      reasoning_effort: "medium",
      read_only: false,
      max_tokens: 8192
    }
  end

  defp default_agent("plan") do
    %{
      model: nil,
      provider: nil,
      system_prompt:
        "You are a planning assistant. Analyze the codebase and create implementation plans. Do NOT make changes.",
      tools: ["file_read", "grep", "glob", "diagnostics"],
      reasoning_effort: "high",
      read_only: true,
      max_tokens: 8192
    }
  end

  defp default_agent(_) do
    default_agent("build")
  end

  defp resolve_tools(default_tools, nil), do: default_tools

  defp resolve_tools(_default_tools, override_tools) when is_list(override_tools),
    do: override_tools

  defp resolve_tools(default_tools, _), do: default_tools
end
