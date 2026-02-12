defmodule Synapsis.LSP.Manager do
  @moduledoc "Manages LSP servers - auto-detects languages and starts servers."

  def start_for_project(project_path) do
    languages = detect_languages(project_path)

    results =
      for lang <- languages do
        start_server(lang, project_path)
      end

    {:ok, results}
  end

  def start_server(language, root_path) do
    spec = {Synapsis.LSP.Server, language: language, root_path: root_path}

    case DynamicSupervisor.start_child(Synapsis.LSP.DynamicSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_server(language, root_path) do
    case Registry.lookup(Synapsis.LSP.Registry, {language, root_path}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Synapsis.LSP.DynamicSupervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  def get_all_diagnostics(project_path) do
    languages = detect_languages(project_path)

    diagnostics =
      for lang <- languages, reduce: %{} do
        acc ->
          case Synapsis.LSP.Server.get_diagnostics(lang, project_path) do
            {:ok, diags} -> Map.merge(acc, diags)
            {:error, _} -> acc
          end
      end

    {:ok, diagnostics}
  end

  def detect_languages(project_path) do
    languages = []

    languages =
      if has_files?(project_path, "**/*.ex") or has_files?(project_path, "**/*.exs") do
        ["elixir" | languages]
      else
        languages
      end

    languages =
      if has_files?(project_path, "**/*.ts") or has_files?(project_path, "**/*.tsx") do
        ["typescript" | languages]
      else
        languages
      end

    languages =
      if has_files?(project_path, "**/*.go") do
        ["go" | languages]
      else
        languages
      end

    languages
  end

  defp has_files?(project_path, pattern) do
    project_path
    |> Path.join(pattern)
    |> Path.wildcard()
    |> Enum.any?()
  end
end
