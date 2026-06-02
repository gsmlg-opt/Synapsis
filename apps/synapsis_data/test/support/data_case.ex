defmodule Synapsis.DataCase do
  @moduledoc "Test case for tests that require database access."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Changeset
      import Synapsis.DataCase
    end
  end

  # ADR-006 C4: no Ecto sandbox — the embedded Concord store is node-local; tests
  # isolate via unique ids rather than per-test DB transactions.
  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc "Kept for ConnCase/ChannelCase compatibility — ensures the store is up."
  def setup_sandbox(_tags) do
    Synapsis.Session.Store.ensure_started()
    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
