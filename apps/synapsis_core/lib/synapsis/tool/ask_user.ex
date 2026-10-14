defmodule Synapsis.Tool.AskUser do
  @moduledoc "Present structured questions to the user and wait for response."
  use Synapsis.Tool

  @response_timeout 300_000

  @impl true
  def name, do: "ask_user"

  @impl true
  def description, do: "Ask the user a question and wait for their response."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "question" => %{"type" => "string", "description" => "The question to ask"},
        "options" => %{
          "type" => "array",
          "description" => "Optional list of choices",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "label" => %{"type" => "string"},
              "description" => %{"type" => "string"}
            },
            "required" => ["label"]
          }
        }
      },
      "required" => ["question"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :interaction

  @impl true
  def execute(input, context) do
    # Sub-agents cannot use ask_user
    if context[:parent_agent] do
      {:error, "Sub-agents cannot interact with the user directly"}
    else
      session_id = context[:session_id]

      if is_nil(session_id) do
        {:error, "No session context available for user interaction"}
      else
        question = input["question"]
        options = input["options"]
        ref = Ecto.UUID.generate()
        timeout = context[:ask_user_timeout_ms] || @response_timeout

        # Subscribe to response topic before broadcasting to avoid race condition
        Phoenix.PubSub.subscribe(Synapsis.PubSub, "ask_user_response:#{session_id}")

        # Broadcast question to session — include ref so clients can echo it back
        try do
          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "session:#{session_id}",
            {:ask_user, ref,
             %{
               ref: ref,
               question: question,
               options: options,
               session_id: session_id,
               session_epoch: context[:session_epoch],
               owner: self(),
               deadline_ms: System.monotonic_time(:millisecond) + timeout
             }}
          )

          receive do
            {:user_response, ^ref, response} -> {:ok, response}
            {:ask_user_cancelled, ^ref} -> {:error, "Question cancelled"}
          after
            timeout -> {:error, "User did not respond within 5 minutes"}
          end
        after
          Phoenix.PubSub.unsubscribe(Synapsis.PubSub, "ask_user_response:#{session_id}")

          Phoenix.PubSub.broadcast(
            Synapsis.PubSub,
            "session:#{session_id}",
            {:ask_user_closed, ref}
          )
        end
      end
    end
  end
end
