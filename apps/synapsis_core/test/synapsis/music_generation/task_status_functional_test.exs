defmodule Synapsis.MusicGeneration.TaskStatusFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.MusicGeneration.TaskStatus

  test "active tasks prefer running while preserving snapshot order within each status" do
    queued_first = task("queued-first", "queued")
    running_first = task("running-first", "running")
    queued_second = task("queued-second", "queued")
    running_second = task("running-second", "running")
    completed = task("completed", "succeeded")
    snapshot = [queued_first, running_first, queued_second, running_second, completed]

    assert TaskStatus.active(snapshot) === running_first
    assert TaskStatus.active([queued_first, queued_second, running_second]) === running_second
    assert TaskStatus.active([queued_first, queued_second]) === queued_first
    assert snapshot === [queued_first, running_first, queued_second, running_second, completed]
  end

  test "prompt selection uses JavaScript trimming and still prefers the first matching running task" do
    queued = task("queued-song", "queued", %{"task" => "  夜 café 😀\n"})
    other = task("other-song", "running", %{"task" => "other melody"})
    matching = task("running-song", "running", %{"task" => "\uFEFF 夜 café 😀 \u00A0"})
    later = task("later-song", "running", %{"task" => "夜 café 😀"})
    snapshot = [queued, other, matching, later]

    assert TaskStatus.active(snapshot, "\u00A0夜 café 😀\uFEFF") === matching
    assert TaskStatus.active([queued, other], " 夜 café 😀 ") === queued
    assert TaskStatus.active(snapshot, "\uFEFF \u00A0\n") === other
  end

  test "an active matching prompt is the duplicate even when opaque request keys differ" do
    queued = task("queued", "queued", %{"task" => "same song", "requestKey" => "queued-key"})
    running = task("running", "running", %{"task" => " same song ", "requestKey" => "old-key"})
    recent = task("recent", "succeeded", %{"task" => "same song", "requestKey" => "new-key"})
    snapshot = [queued, running, recent]

    assert TaskStatus.duplicate(snapshot, %{
             prompt: "\uFEFFsame song\u00A0",
             request_key: "new-key"
           }) === running

    assert TaskStatus.duplicate(snapshot) === running
  end

  test "recent succeeded duplicates use exact opaque keys and original order rather than completion timestamps" do
    key = " opaque canonical key \n"

    earlier =
      task("earlier-row", "succeeded", %{
        "requestKey" => key,
        "task" => "earlier prompt",
        "endedAt" => 90_000
      })

    selected =
      task("later-row", "succeeded", %{
        "requestKey" => key,
        "task" => "stored prompt differs from lookup",
        "endedAt" => 1_000
      })

    trailing =
      task("different-key-row", "succeeded", %{
        "requestKey" => "opaque canonical key",
        "endedAt" => 100_000
      })

    snapshot = [earlier, selected, trailing]

    assert TaskStatus.duplicate(snapshot, %{prompt: "new lookup prompt", request_key: key}) ===
             selected

    assert TaskStatus.duplicate([selected, earlier], %{request_key: key}) === earlier
  end

  test "full details retain raw optional fields and trim the complete provider suffix" do
    fact = %{
      "taskId" => " task-full ",
      "runId" => " run raw ",
      "taskKind" => "music_generation",
      "sourceId" => "\uFEFF music_generate: provider:variant \u00A0",
      "task" => "full song",
      "requestKey" => "opaque",
      "status" => "running",
      "progressSummary" => "  arranging!\nready. ",
      "startedAt" => 123,
      "revision" => 7
    }

    assert TaskStatus.details(fact) === %{
             "async" => true,
             "active" => true,
             "existingTask" => true,
             "status" => "running",
             "task" => %{"taskId" => " task-full ", "runId" => " run raw "},
             "taskKind" => "music_generation",
             "progressSummary" => "  arranging!\nready. ",
             "sourceId" => "\uFEFF music_generate: provider:variant \u00A0",
             "provider" => "provider:variant"
           }

    assert TaskStatus.text(fact) ===
             "Music generation task  task-full  is already running with provider:variant.\n" <>
               "Progress:   arranging!\nready. .\n" <>
               "Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished music here."
  end

  test "minimal queued details omit absent optional fields and text retains the default completion instruction" do
    fact = %{"taskId" => "minimal", "status" => "queued", "runId" => "", "progressSummary" => ""}

    assert TaskStatus.details(fact) === %{
             "async" => true,
             "active" => true,
             "existingTask" => true,
             "status" => "queued",
             "task" => %{"taskId" => "minimal"}
           }

    assert TaskStatus.text(fact) ===
             "Music generation task minimal is already queued.\n" <>
               "Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished music here."
  end

  test "delivering completion remains active and status returns the exact full single-task envelope" do
    queued = task("queued", "queued")

    delivering =
      task("delivery", "running", %{
        "runId" => "run-delivery",
        "sourceId" => " music_generate: comfy ",
        "progressSummary" => "Generated media; delivering completion"
      })

    assert TaskStatus.active([queued, delivering]) === delivering

    assert TaskStatus.duplicate([queued, delivering], %{prompt: "song", request_key: "different"}) ===
             delivering

    assert TaskStatus.status_result([queued, delivering]) === %{
             "content" => [
               %{
                 "type" => "text",
                 "text" =>
                   "Music generation task delivery is already running with comfy.\n" <>
                     "Progress: Generated media; delivering completion.\n" <>
                     "Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished music here."
               }
             ],
             "details" => %{
               "action" => "status",
               "async" => true,
               "active" => true,
               "existingTask" => true,
               "status" => "running",
               "task" => %{"taskId" => "delivery", "runId" => "run-delivery"},
               "taskKind" => "music_generation",
               "sourceId" => " music_generate: comfy ",
               "progressSummary" => "Generated media; delivering completion",
               "provider" => "comfy"
             }
           }
  end

  test "active duplicate result contains the exact guard instruction and unmodified progress punctuation" do
    fact =
      task("queued-duplicate", "queued", %{
        "runId" => "run-queued",
        "sourceId" => "music_generate: provider:variant ",
        "progressSummary" => "Preparing.",
        "requestKey" => "existing-key"
      })

    expected_text =
      "Music generation task queued-duplicate is already queued with provider:variant.\n" <>
        "Progress: Preparing..\n" <>
        "Do not call music_generate again for this request. Do not wait, poll, or yield for it: end this turn; the completion arrives as a later turn and sends the finished music here."

    assert TaskStatus.text(fact, true) === expected_text

    expected_result = %{
      "content" => [%{"type" => "text", "text" => expected_text}],
      "details" => %{
        "action" => "status",
        "duplicateGuard" => true,
        "async" => true,
        "active" => true,
        "existingTask" => true,
        "status" => "queued",
        "task" => %{"taskId" => "queued-duplicate", "runId" => "run-queued"},
        "taskKind" => "music_generation",
        "sourceId" => "music_generate: provider:variant ",
        "progressSummary" => "Preparing.",
        "provider" => "provider:variant"
      }
    }

    assert TaskStatus.duplicate_result([fact], %{prompt: " song ", request_key: "new-key"}) ===
             expected_result

    assert TaskStatus.duplicate_result([fact]) === expected_result
  end

  test "recent completion returns the exact duplicate result while successful status reports no active task" do
    fact =
      task("finished", "succeeded", %{
        "requestKey" => "exact-completed-key",
        "sourceId" => "music_generate: google",
        "progressSummary" => "Created two tracks"
      })

    expected_text =
      "Music generation task finished recently succeeded with google.\n" <>
        "Progress: Created two tracks.\n" <>
        "Do not call music_generate again for the same request; this recent music generation already completed."

    assert TaskStatus.text(fact, true) === expected_text

    assert TaskStatus.duplicate_result([fact], %{request_key: "exact-completed-key"}) === %{
             "content" => [%{"type" => "text", "text" => expected_text}],
             "details" => %{
               "action" => "status",
               "duplicateGuard" => true,
               "async" => true,
               "active" => false,
               "existingTask" => true,
               "status" => "succeeded",
               "task" => %{"taskId" => "finished"},
               "taskKind" => "music_generation",
               "sourceId" => "music_generate: google",
               "progressSummary" => "Created two tracks",
               "provider" => "google"
             }
           }

    inactive = %{
      "content" => [
        %{
          "type" => "text",
          "text" => "No active music generation task is currently running for this session."
        }
      ],
      "details" => %{"action" => "status", "active" => false}
    }

    assert TaskStatus.status_result([fact]) === inactive
    assert TaskStatus.status_result([]) === inactive
  end

  defp task(id, status, extra \\ %{}) do
    Map.merge(
      %{
        "taskId" => id,
        "taskKind" => "music_generation",
        "sourceId" => "music_generate",
        "task" => "song",
        "status" => status
      },
      extra
    )
  end
end
