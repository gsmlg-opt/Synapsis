defmodule Synapsis.Agent.TestSupport.BackplaneRuntimeProof do
  @moduledoc """
  Shared in-memory native Conversation/provider proof helpers.

  The provider runs a deterministic script. EchoTool supplies an inert schema;
  production adapters and host tools retain their separate native contracts.
  """
  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}

  defmodule Provider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    @impl true
    def stream(request, context), do: context.script.(request)
  end

  defmodule EchoTool do
    use Synapsis.Tool

    @impl true
    def name, do: "backplane_proof_echo"

    @impl true
    def description, do: "Inert runtime contract test tool"

    @impl true
    def permission_level, do: :read

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"],
        "additionalProperties" => false
      }
    end

    @impl true
    def execute(%{"text" => text}, context) do
      send(context.test_pid, {:proof_tool_executed, text, context})
      {:ok, text}
    end
  end

  def options(run_id, script, opts \\ []) do
    {:ok, store} = EphemeralStore.new(1)

    Keyword.merge(
      [
        run_id: run_id,
        store: EphemeralStore,
        context: store,
        provider: Provider,
        provider_context: %{script: script},
        subscriber: self(),
        registry: %ToolRegistry{},
        authority: %{caller: "synapsis-proof", run_id: run_id, grants: [], tool_revision: 1},
        work: 3,
        run_timeout: 5_000,
        effect_timeout: 1_000,
        commit_timeout: 1_000,
        cleanup_timeout: 1_000
      ],
      opts
    )
  end

  # The runtime call itself has an infinite timeout. Keep the proof caller bounded
  # without pretending a timed-out call was rejected by the runtime.
  def prompt(supervisor, pid, content) do
    task = Task.Supervisor.async_nolink(supervisor, fn -> Conversation.prompt(pid, content) end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :prompt_outcome_unknown}
    end
  end

  def completed(text),
    do: %{type: :response_completed, message: %{role: :assistant, content: text}}

  def call(name, arguments),
    do: %{
      type: :tool_call_completed,
      tool_call: %{id: "call-1", name: name, arguments: arguments}
    }
end
