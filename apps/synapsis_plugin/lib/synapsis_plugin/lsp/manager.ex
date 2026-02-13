defmodule SynapsisPlugin.LSP.Manager do
  @moduledoc """
  Manages LSP plugins - language detection, starting servers, aggregating diagnostics.
  """

  def start_for_project(project_path) do
    languages = detect_languages(project_path)

    results =
      for lang <- languages do
        config = %{
          name: lang,
          language: lang,
          root_path: project_path
        }

        SynapsisPlugin.start_plugin(SynapsisPlugin.LSP, "lsp:#{lang}", config)
      end

    {:ok, results}
  end

  def get_all_diagnostics(project_path) do
    languages = detect_languages(project_path)

    diagnostics =
      for lang <- languages, reduce: %{} do
        acc ->
          name = "lsp:#{lang}"

          case Registry.lookup(SynapsisPlugin.Registry, name) do
            [{pid, _}] ->
              try do
                state = GenServer.call(pid, :get_state, 5_000)
                Map.merge(acc, state.diagnostics || %{})
              catch
                :exit, _ -> acc
              end

            [] ->
              acc
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
