defmodule SynapsisPlugin.Server do
  @moduledoc """
  GenServer wrapper for any Plugin implementation.

  Manages the lifecycle of a plugin: init, tool registration/unregistration,
  tool execution dispatch, and side effect forwarding.
  """
  use GenServer
  require Logger

  defstruct [
    :plugin_module,
    :plugin_state,
    :name,
    :config,
    :registered_tools
  ]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    gen_name = {:via, Registry, {SynapsisPlugin.Registry, name}}
    GenServer.start_link(__MODULE__, opts, name: gen_name)
  end

  @impl true
  def init(opts) do
    plugin_module = Keyword.fetch!(opts, :plugin_module)
    name = Keyword.fetch!(opts, :name)
    config = Keyword.get(opts, :config, %{})

    case plugin_module.init(config) do
      {:ok, plugin_state} ->
        tools = plugin_module.tools(plugin_state)
        registered = register_tools(name, tools)

        # Subscribe to tool effects if the plugin handles them
        if function_exported?(plugin_module, :handle_effect, 3) do
          Phoenix.PubSub.subscribe(Synapsis.PubSub, "tool_effects:*")
        end

        Logger.info("plugin_started", name: name, tools: length(registered))

        state = %__MODULE__{
          plugin_module: plugin_module,
          plugin_state: plugin_state,
          name: name,
          config: config,
          registered_tools: registered
        }

        {:ok, state}

      {:error, reason} ->
        Logger.warning("plugin_init_failed", name: name, reason: inspect(reason))
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:execute, tool_name, input, _context}, from, state) do
    case state.plugin_module.execute(tool_name, input, state.plugin_state) do
      {:ok, result, new_plugin_state} ->
        {:reply, {:ok, result}, %{state | plugin_state: new_plugin_state}}

      {:async, new_plugin_state} ->
        # Plugin will reply later via handle_info
        {:noreply, %{state | plugin_state: put_pending_from(new_plugin_state, from)}}

      {:error, reason, new_plugin_state} ->
        {:reply, {:error, reason}, %{state | plugin_state: new_plugin_state}}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.plugin_state, state}
  end

  @impl true
  def handle_info({:tool_effect, effect, payload}, state) do
    if function_exported?(state.plugin_module, :handle_effect, 3) do
      case state.plugin_module.handle_effect(effect, payload, state.plugin_state) do
        {:ok, new_plugin_state} ->
          {:noreply, %{state | plugin_state: new_plugin_state}}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    if function_exported?(state.plugin_module, :handle_info, 2) do
      case state.plugin_module.handle_info(msg, state.plugin_state) do
        {:ok, new_plugin_state} ->
          {:noreply, %{state | plugin_state: new_plugin_state}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    unregister_tools(state.registered_tools)

    if function_exported?(state.plugin_module, :terminate, 2) do
      state.plugin_module.terminate(reason, state.plugin_state)
    end

    :ok
  end

  defp register_tools(plugin_name, tools) do
    for tool <- tools do
      full_name = tool.name
      Synapsis.Tool.Registry.register_process(full_name, self(),
        description: tool.description,
        parameters: tool.parameters,
        timeout: Map.get(tool, :timeout, 30_000),
        plugin: plugin_name
      )
      full_name
    end
  end

  defp unregister_tools(tool_names) do
    for name <- tool_names do
      Synapsis.Tool.Registry.unregister(name)
    end
  end

  defp put_pending_from(plugin_state, from) when is_map(plugin_state) do
    Map.put(plugin_state, :_pending_from, from)
  end

  defp put_pending_from(plugin_state, _from), do: plugin_state
end
