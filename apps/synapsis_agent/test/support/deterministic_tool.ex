defmodule Synapsis.Agent.TestSupport.DeterministicTool do
  @moduledoc """
  Controllable tool double for lifecycle and characterization tests.

  Behaviors (configured via `register/2`):

  - `:read_success` — returns ok text (permission `:read`)
  - `:timeout` — sleeps past a short registry timeout; Executor returns `:timeout`
  - `:crash` — raises inside `execute/2`
  - `:idempotent_side_effect` — increments a counter and returns ok (safe retry)
  - `:uncertain_outcome` — records a side-effect intent then raises (crash after intent)

  Denial is exercised via permission policy (`:deny` registration sets
  `permission_level: :destructive` for use with a deny/ask session config), not
  by returning a special execute result.
  """

  use Synapsis.Tool

  @table :synapsis_deterministic_tool_state
  @active_env :deterministic_tool_active

  @impl true
  def name, do: "deterministic_tool"

  @impl true
  def description, do: "Deterministic tool double for agent runtime tests."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "string"},
        "path" => %{"type" => "string"}
      },
      "required" => []
    }
  end

  @impl true
  def permission_level, do: :read

  @impl true
  def execute(input, _context) do
    key = active_name!()
    state = fetch_state!(key)
    record_execution(key, input)

    case state.behavior do
      :read_success ->
        value = Map.get(input, "value") || Map.get(input, :value) || "ok"
        {:ok, "deterministic read: #{value}"}

      :timeout ->
        Process.sleep(state.sleep_ms)
        {:ok, "should have timed out"}

      :crash ->
        raise "deterministic tool crash"

      :idempotent_side_effect ->
        bump_side_effect(key)
        {:ok, "idempotent side effect applied"}

      :uncertain_outcome ->
        record_intent(key, input)
        raise "deterministic uncertain outcome after side-effect intent"

      :deny ->
        # Permission layer should deny before execute; if we get here, fail closed.
        {:error, :capability_denied}
    end
  end

  @doc """
  Register this module under `name` with the given behavior.

  Options:

  - `:timeout` / `:max_retries` — forwarded to the tool registry
  - `:sleep_ms` — sleep duration for `:timeout` behavior (default 500)
  - `:permission_level` — override (`:destructive` for deny scenarios)
  """
  @spec register(String.t(), atom(), keyword()) :: :ok
  def register(name, behavior, opts \\ []) when is_binary(name) and is_atom(behavior) do
    ensure_table()

    sleep_ms = Keyword.get(opts, :sleep_ms, 500)

    :ets.insert(
      @table,
      {name,
       %{
         behavior: behavior,
         sleep_ms: sleep_ms,
         executions: [],
         intents: [],
         side_effects: 0
       }}
    )

    Application.put_env(:synapsis_agent, @active_env, name)

    registry_opts =
      opts
      |> Keyword.take([:timeout, :max_retries, :permission_level, :deferred])
      |> Keyword.put_new(:max_retries, 0)
      |> maybe_timeout_opts(behavior)

    registry_opts =
      if behavior == :deny do
        Keyword.put_new(registry_opts, :permission_level, :destructive)
      else
        registry_opts
      end

    :ok = Synapsis.Tool.Registry.register_module(name, __MODULE__, registry_opts)
    :ok
  end

  @spec unregister(String.t()) :: :ok
  def unregister(name) when is_binary(name) do
    if table_alive?() do
      :ets.delete(@table, name)
    end

    if Application.get_env(:synapsis_agent, @active_env) == name do
      Application.delete_env(:synapsis_agent, @active_env)
    end

    Synapsis.Tool.Registry.unregister(name)
    :ok
  end

  @spec executions(String.t()) :: [map()]
  def executions(name) do
    case lookup(name) do
      {:ok, state} -> Enum.reverse(state.executions)
      :error -> []
    end
  end

  @spec intents(String.t()) :: [map()]
  def intents(name) do
    case lookup(name) do
      {:ok, state} -> Enum.reverse(state.intents)
      :error -> []
    end
  end

  @spec side_effect_count(String.t()) :: non_neg_integer()
  def side_effect_count(name) do
    case lookup(name) do
      {:ok, state} -> state.side_effects
      :error -> 0
    end
  end

  defp maybe_timeout_opts(opts, :timeout) do
    opts
    |> Keyword.put_new(:timeout, 100)
    |> Keyword.put_new(:max_retries, 0)
  end

  defp maybe_timeout_opts(opts, _behavior), do: opts

  defp ensure_table do
    if table_alive?() do
      :ok
    else
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      :ok
    end
  end

  defp table_alive? do
    :ets.whereis(@table) != :undefined
  end

  defp active_name! do
    Application.get_env(:synapsis_agent, @active_env) ||
      raise "no active deterministic tool; call DeterministicTool.register/2 first"
  end

  defp lookup(name) do
    if table_alive?() do
      case :ets.lookup(@table, name) do
        [{^name, state}] -> {:ok, state}
        [] -> :error
      end
    else
      :error
    end
  end

  defp fetch_state!(key) do
    case lookup(key) do
      {:ok, state} -> state
      :error -> raise "deterministic tool #{inspect(key)} is not registered"
    end
  end

  defp record_execution(key, input) do
    update!(key, fn state -> %{state | executions: [input | state.executions]} end)
  end

  defp record_intent(key, input) do
    update!(key, fn state -> %{state | intents: [input | state.intents]} end)
  end

  defp bump_side_effect(key) do
    update!(key, fn state -> %{state | side_effects: state.side_effects + 1} end)
  end

  defp update!(key, fun) do
    state = fetch_state!(key)
    :ets.insert(@table, {key, fun.(state)})
  end
end
