defmodule Synapsis.Session.ModelContextTest do
  use ExUnit.Case, async: false

  alias Synapsis.{Message, Models, Part, Providers, Session}
  alias Synapsis.Agent.ContextBuilder
  alias Synapsis.Session.Compactor

  setup do
    Synapsis.Session.Store.ensure_started()
    :ok
  end

  test "the configured provider context controls skill, memory and compaction budgets" do
    suffix = System.unique_integer([:positive])
    {:ok, small} = Providers.create(%{name: "small-#{suffix}", type: "openai"})
    {:ok, large} = Providers.create(%{name: "large-#{suffix}", type: "openai"})

    {:ok, smaller} =
      Models.create(%{provider_id: small.id, model: "same-model", context_window: 8_000})

    {:ok, larger} =
      Models.create(%{provider_id: large.id, model: "same-model", context_window: 80_000})

    id = Ecto.UUID.generate()

    :ok =
      Synapsis.Session.Store.put_meta(
        id,
        Session.to_meta(%Session{id: id, provider: small.name, model: "same-model"})
      )

    on_exit(fn ->
      Synapsis.Session.Store.delete_session(id)
      Models.delete(smaller)
      Models.delete(larger)
      Providers.delete(small.id)
      Providers.delete(large.id)
    end)

    small_window =
      ContextBuilder.skill_context_window([], %{provider: small.name, model: "same-model"})

    large_window =
      ContextBuilder.skill_context_window([], %{provider: large.name, model: "same-model"})

    assert small_window == 8_000
    assert large_window == 80_000
    assert ContextBuilder.memory_budget(small_window).max_tokens == 400
    assert ContextBuilder.memory_budget(large_window).max_tokens == 4_000

    messages =
      for n <- 1..14,
          do: %Message{
            session_id: id,
            role: "user",
            parts: [%Part.Text{content: "message #{n}"}],
            token_count: 1_000
          }

    :ok = Message.persist_list(id, messages)

    assert {:ok, :no_compaction_needed} =
             Compactor.maybe_compact(id, "same-model", provider: large.name)

    assert {:ok, %{removed: 4, kept: 10}} =
             Compactor.maybe_compact(id, "same-model", provider: small.name)
  end
end
