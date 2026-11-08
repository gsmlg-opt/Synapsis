defmodule SynapsisWeb.AgentLive.TaskSuggestions do
  @moduledoc "Presentation of process-local follow-up proposals and their launch receipts."
  use SynapsisWeb, :html

  attr :suggestions, :list, required: true
  attr :error, :string, default: nil
  attr :notice, :string, default: nil

  def panel(assigns) do
    ~H"""
    <section
      id="task-suggestions"
      aria-labelledby="task-suggestions-heading"
      class="shrink-0 border-b border-outline-variant px-4 py-2 text-on-surface"
    >
      <div class="flex items-center justify-between gap-3">
        <div>
          <h2 id="task-suggestions-heading" class="text-sm font-semibold">
            <.dm_mdi name="lightbulb-outline" class="inline-block h-4 w-4" /> Suggested follow-ups
          </h2>
          <p class="text-xs text-on-surface-variant">
            Review and start proposed next steps for this session
          </p>
        </div>
        <.dm_btn
          variant="ghost"
          size="xs"
          phx-click="refresh_task_suggestions"
          aria-label="Refresh suggested follow-ups"
        >
          <.dm_mdi name="refresh" class="h-4 w-4" /> {if @error, do: "Retry", else: "Refresh"}
        </.dm_btn>
      </div>
      <p :if={@error} role="alert" class="mt-2 text-sm text-error">{@error}</p>
      <p :if={@notice} role="status" class="mt-2 text-xs text-on-surface-variant">{@notice}</p>
      <p :if={@suggestions == [] and is_nil(@error)} class="mt-2 text-xs text-on-surface-variant">
        No pending follow-ups
      </p>
      <div :if={@suggestions != []} class="mt-2 max-h-60 overflow-y-auto space-y-2">
        <.dm_card
          :for={suggestion <- @suggestions}
          id={"task-suggestion-#{suggestion.id}"}
          data-task-suggestion-id={suggestion.id}
          data-task-suggestion-status={status(suggestion)}
          variant="compact"
          body_class="p-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h3 class="text-sm font-semibold break-words">{suggestion.title}</h3>
              <p class="text-sm break-words">{suggestion.tldr}</p>
              <p class="mt-1 text-xs text-on-surface-variant break-all">
                <span class="font-medium">Directory:</span> {suggestion.cwd}
              </p>
              <p class="mt-1 text-xs text-on-surface-variant" role="status">
                {status_label(suggestion)}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-2">
              <.dm_btn
                :if={status(suggestion) == "pending"}
                size="xs"
                phx-click="accept_task_suggestion"
                phx-value-task-id={suggestion.id}
                phx-disable-with="Starting…"
              >
                Start in this folder
              </.dm_btn>
              <.dm_btn
                :if={status(suggestion) == "pending"}
                variant="ghost"
                size="xs"
                phx-click="dismiss_task_suggestion"
                phx-value-task-id={suggestion.id}
                aria-label={"Dismiss #{suggestion.title}"}
              >
                Dismiss
              </.dm_btn>
              <.link
                :if={status(suggestion) == "accepted"}
                patch={
                  ~p"/agent/agents/#{suggestion.agent_id}/sessions/#{suggestion.receipt.session_id}"
                }
                class="text-sm underline"
              >Open session</.link>
              <.link
                :if={
                  status(suggestion) == "unknown_outcome" and
                    Map.get(suggestion, :destination_session_id)
                }
                patch={
                  ~p"/agent/agents/#{suggestion.agent_id}/sessions/#{suggestion.destination_session_id}"
                }
                class="text-sm underline"
              >Check session</.link>
            </div>
          </div>
          <details class="mt-2 text-xs">
            <summary class="cursor-pointer text-on-surface-variant">Full prompt</summary>
            <p class="mt-2 whitespace-pre-wrap break-words">{suggestion.prompt}</p>
          </details>
        </.dm_card>
      </div>
    </section>
    """
  end

  defp status(suggestion), do: Map.get(suggestion, :status, "pending")

  defp status_label(suggestion) do
    case status(suggestion) do
      "pending" ->
        "Not started"

      "accepting" ->
        "Starting in this folder…"

      "accepted" ->
        "Started"

      "unknown_outcome" ->
        "Launch is unconfirmed. Check the associated session before taking further action."
    end
  end
end
