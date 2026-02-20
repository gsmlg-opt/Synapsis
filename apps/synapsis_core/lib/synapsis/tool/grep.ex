defmodule Synapsis.Tool.Grep do
  @moduledoc "Search file contents using ripgrep or grep."
  use Synapsis.Tool

  @impl true
  def name, do: "grep"

  @impl true
  def description,
    do: "Search for a pattern in files. Uses ripgrep (rg) if available, otherwise grep."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Regex pattern to search for"},
        "path" => %{
          "type" => "string",
          "description" => "Directory or file to search in (default: project root)"
        },
        "include" => %{
          "type" => "string",
          "description" => "Glob pattern to filter files (e.g. '*.ex')"
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(input, context) do
    pattern = input["pattern"]
    search_path = input["path"] || "."
    cwd = context[:project_path] || "."
    include = input["include"]

    with :ok <- validate_path(search_path, cwd) do
      execute_search(pattern, search_path, cwd, include)
    end
  end

  defp validate_path(_path, nil), do: :ok

  defp validate_path(path, project_path) do
    abs_path = Path.expand(Path.join(project_path, path))
    abs_project = Path.expand(project_path)

    if String.starts_with?(abs_path, abs_project) do
      :ok
    else
      {:error, "Path #{path} is outside project root"}
    end
  end

  defp execute_search(pattern, search_path, cwd, include) do
    {cmd, args} = build_command(pattern, search_path, include)

    port =
      Port.open({:spawn_executable, cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: cwd
      ])

    collect_output(port, "", 10_000)
  end

  defp build_command(pattern, path, include) do
    case System.find_executable("rg") do
      nil -> build_grep_command(pattern, path, include)
      rg_path -> build_rg_command(rg_path, pattern, path, include)
    end
  end

  defp build_rg_command(rg_path, pattern, path, include) do
    args = ["-n", "--no-heading", "--color", "never"]
    args = if include, do: args ++ ["-g", include], else: args
    args = args ++ [pattern, path]
    {rg_path, args}
  end

  defp build_grep_command(pattern, path, include) do
    grep_path = System.find_executable("grep") || "/usr/bin/grep"
    args = ["-rn", "--color=never"]
    args = if include, do: args ++ ["--include=#{include}"], else: args
    args = args ++ [pattern, path]
    {grep_path, args}
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, String.trim_trailing(acc)}

      {^port, {:exit_status, 1}} ->
        {:ok, "No matches found."}

      {^port, {:exit_status, _status}} ->
        {:ok, String.trim_trailing(acc)}
    after
      timeout ->
        Port.close(port)
        {:error, "Search timed out"}
    end
  end
end
