defmodule Synapsis.MusicGeneration.TaskStatus do
  @moduledoc """
  Pure music-task status and duplicate projections from OpenClaw 488631c.

  The caller supplies a complete, ordered snapshot of portable operation facts,
  already selected for the current session and Agent and pruned by its owner.
  Facts use the source's string keys (`taskId`, `taskKind`, `sourceId`, `status`,
  `task`, `requestKey`, and optional status fields). This module reads no store,
  chooses no scope, starts no task and installs no native tool or runtime owner.
  UUID-sorted current Store pages do not establish this snapshot or its order.

  Active music facts are queued or running with music_generate source identity.
  Running facts precede queued facts, preserving snapshot order within each
  group. An optional prompt compares JS-trimmed labels. Delivering-completion
  progress remains active for status and duplicate lookup.

  A matching active prompt wins before request-key comparison. Otherwise the
  last matching exact key in snapshot order can reuse a successful completion.
  Keys are caller-prepared canonical strings; neither submission identity nor
  the Store's SHA256 digest replaces them. This module does not construct keys,
  choose retention, sort timestamps, or impose a single active task.

  Status/action maps retain source string keys, complete literal text and raw
  optional progress/source fields. They are inactive projections: completion
  instructions describe the reference contract, not installed delivery behavior.
  Failure, blocked and lifecycle branches are not execution-qualified.
  """

  @kind "music_generation"
  @tool "music_generate"
  @js_space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @js_trim Regex.compile!("\\A#{@js_space}+|#{@js_space}+\\z", "u")

  @type operation :: %{String.t() => term()}

  @spec active([operation()], String.t() | nil) :: operation() | nil
  def active(tasks, prompt \\ nil) do
    label = optional_string(prompt)

    matches =
      Enum.filter(tasks, fn task ->
        music?(task) and active?(task) and
          (is_nil(label) or optional_string(task["task"]) == label)
      end)

    {running, queued} = Enum.split_with(matches, &(&1["status"] == "running"))
    List.first(running ++ queued)
  end

  @spec duplicate([operation()], map()) :: operation() | nil
  def duplicate(tasks, request \\ %{}) do
    case active(tasks, request[:prompt]) do
      nil -> recent_duplicate(tasks, request[:request_key])
      task -> task
    end
  end

  @spec details(operation()) :: map()
  def details(task) do
    identity = %{"taskId" => task["taskId"]} |> optional("runId", task["runId"])

    %{
      "async" => true,
      "active" => active?(task),
      "existingTask" => true,
      "status" => task["status"],
      "task" => identity
    }
    |> optional("taskKind", task["taskKind"])
    |> optional("progressSummary", task["progressSummary"])
    |> optional("sourceId", task["sourceId"])
    |> optional("provider", provider(task))
  end

  @spec text(operation(), boolean()) :: String.t()
  def text(task, duplicate_guard \\ false) do
    provider = provider(task)
    active = active?(task) or task["terminalOutcome"] == "blocked"
    position = if active, do: "is already", else: "recently"
    with_provider = if provider, do: " with " <> provider, else: ""

    instruction =
      cond do
        duplicate_guard and active ->
          "Do not call music_generate again for this request. Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished music here."

        duplicate_guard ->
          "Do not call music_generate again for the same request; this recent music generation already completed."

        true ->
          "Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished music here."
      end

    progress =
      if truthy?(task["progressSummary"]), do: "Progress: #{task["progressSummary"]}."

    [
      "Music generation task #{task["taskId"]} #{position} #{task["status"]}#{with_provider}.",
      progress,
      instruction
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @spec status_result([operation()]) :: map()
  def status_result(tasks) do
    case active(tasks) do
      nil ->
        result(
          "No active music generation task is currently running for this session.",
          %{"action" => "status", "active" => false}
        )

      task ->
        result(text(task), Map.put(details(task), "action", "status"))
    end
  end

  @spec duplicate_result([operation()], map()) :: map() | nil
  def duplicate_result(tasks, request \\ %{}) do
    case duplicate(tasks, request) do
      nil ->
        nil

      task ->
        details = details(task) |> Map.merge(%{"action" => "status", "duplicateGuard" => true})
        result(text(task, true), details)
    end
  end

  defp recent_duplicate(tasks, key) do
    if truthy?(key) do
      task = Enum.find(Enum.reverse(tasks), &(music?(&1) and &1["requestKey"] === key))

      if task && task["status"] == "succeeded" && task["terminalOutcome"] != "blocked",
        do: task
    end
  end

  defp active?(task), do: task["status"] in ["queued", "running"]

  defp music?(task) do
    source = optional_string(task["sourceId"]) || ""
    task["taskKind"] == @kind and (source == @tool or String.starts_with?(source, @tool <> ":"))
  end

  defp provider(task) do
    source = optional_string(task["sourceId"]) || ""

    if String.starts_with?(source, @tool <> ":"),
      do: source |> String.replace_prefix(@tool <> ":", "") |> optional_string()
  end

  defp result(text, details),
    do: %{"content" => [%{"type" => "text", "text" => text}], "details" => details}

  defp optional(map, key, value),
    do: if(truthy?(value), do: Map.put(map, key, value), else: map)

  defp truthy?(value), do: value not in [nil, false, 0, 0.0, ""]

  defp optional_string(value) when is_binary(value) do
    case Regex.replace(@js_trim, value, "") do
      "" -> nil
      text -> text
    end
  end

  defp optional_string(_), do: nil
end
