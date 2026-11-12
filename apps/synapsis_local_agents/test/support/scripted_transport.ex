defmodule SynapsisLocalAgents.Test.ScriptedTransport do
  @moduledoc false
  # In-memory SamgitaCodexDriver.Transport: reports every sent wire to the
  # observer and accepts {:incoming, wire} / :drop_connection sent to the Session.
  import Kernel, except: [send: 2]
  @behaviour SamgitaCodexDriver.Transport

  @impl true
  def open(opts) do
    Kernel.send(Keyword.fetch!(opts, :observer), {:transport_opened, self()})
    {:ok, Map.new(opts)}
  end

  @impl true
  def send(state, body) do
    Kernel.send(state.observer, {:sent, self(), Jason.decode!(body)})
    {:ok, state}
  end

  @impl true
  def handle_info({:incoming, wire}, state), do: {:ok, [{:message, Jason.encode!(wire)}], state}
  def handle_info(:drop_connection, state), do: {:ok, [{:closed, %{}}], state}
  def handle_info(_, _), do: :unknown

  @impl true
  def close(state) do
    Kernel.send(state.observer, {:transport_closed, self()})
    :ok
  end

  @impl true
  def metadata(_state), do: %{transport: :scripted, connected: true}
end
