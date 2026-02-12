defmodule Synapsis.Config do
  @moduledoc """
  Configuration loader and merger.
  Merges: defaults < user config < project config < env overrides.
  """

  @config_dir "~/.config/synapsis"
  @user_config_file "config.json"
  @auth_file "auth.json"
  @project_config_file ".opencode.json"

  def resolve(project_path) do
    defaults()
    |> deep_merge(load_user_config())
    |> deep_merge(load_project_config(project_path))
    |> deep_merge(load_env_overrides())
  end

  def defaults do
    %{
      "agents" => %{
        "build" => %{
          "name" => "build",
          "systemPrompt" => default_system_prompt(),
          "tools" => [
            "file_read",
            "file_edit",
            "file_write",
            "bash",
            "grep",
            "glob",
            "diagnostics",
            "fetch"
          ],
          "model" => nil,
          "reasoningEffort" => "medium",
          "readOnly" => false
        },
        "plan" => %{
          "name" => "plan",
          "systemPrompt" =>
            "You are a planning assistant. Analyze the codebase and create implementation plans. Do NOT make changes.",
          "tools" => ["file_read", "grep", "glob", "diagnostics"],
          "model" => nil,
          "reasoningEffort" => "high",
          "readOnly" => true
        }
      },
      "providers" => %{},
      "mcpServers" => %{},
      "lsp" => %{}
    }
  end

  def load_user_config do
    path = Path.expand(Path.join(@config_dir, @user_config_file))
    load_json_file(path)
  end

  def load_auth do
    path = Path.expand(Path.join(@config_dir, @auth_file))
    load_json_file(path)
  end

  def load_project_config(nil), do: %{}

  def load_project_config(project_path) do
    path = Path.join(project_path, @project_config_file)
    load_json_file(path)
  end

  def load_env_overrides do
    overrides = %{}

    overrides =
      case System.get_env("ANTHROPIC_API_KEY") do
        nil -> overrides
        key -> put_in_nested(overrides, ["providers", "anthropic", "apiKey"], key)
      end

    overrides =
      case System.get_env("OPENAI_API_KEY") do
        nil -> overrides
        key -> put_in_nested(overrides, ["providers", "openai", "apiKey"], key)
      end

    overrides =
      case System.get_env("GOOGLE_API_KEY") do
        nil -> overrides
        key -> put_in_nested(overrides, ["providers", "google", "apiKey"], key)
      end

    overrides
  end

  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, v1, v2 when is_map(v1) and is_map(v2) -> deep_merge(v1, v2)
      _key, _v1, v2 -> v2
    end)
  end

  def deep_merge(_base, override), do: override

  defp load_json_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp put_in_nested(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_in_nested(map, [key | rest], value) do
    inner = Map.get(map, key, %{})
    Map.put(map, key, put_in_nested(inner, rest, value))
  end

  defp default_system_prompt do
    """
    You are Synapsis, an AI coding assistant. You help developers write, edit, and understand code.
    You have access to tools for reading files, editing files, running shell commands, and searching code.
    Always explain your reasoning before making changes. Be concise and precise.
    """
  end
end
