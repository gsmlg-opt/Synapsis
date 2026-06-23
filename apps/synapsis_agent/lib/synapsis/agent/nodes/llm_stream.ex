defmodule Synapsis.Agent.Nodes.LLMStream do
  @moduledoc """
  Requests Worker to start provider stream. Pauses while streaming.
  Resumes when Worker sends stream_acc or stream_error via Runner.resume/2.
  """
  @behaviour Synapsis.Agent.Runtime.Node

  import Synapsis.Agent.Nodes.Helpers, only: [worker_pid: 1]

  require Logger

  @impl true
  @spec run(map(), map()) :: {:next, atom(), map()} | {:wait, map()}
  def run(state, ctx) do
    if state[:awaiting_stream] do
      # Resumed after stream completed — read accumulated data from ctx
      cond do
        ctx[:stream_error] ->
          handle_stream_error(state, ctx[:stream_error])

        ctx[:stream_acc] ->
          acc = ctx[:stream_acc]

          new_state =
            Map.merge(state, %{
              pending_text: acc.pending_text,
              pending_tool_use: acc.pending_tool_use,
              pending_tool_input: acc.pending_tool_input,
              pending_reasoning: acc.pending_reasoning,
              pending_reasoning_signature: acc.pending_reasoning_signature,
              tool_uses: acc.tool_uses
            })
            |> Map.delete(:awaiting_stream)
            |> Map.delete(:request)

          {:next, :default, new_state}

        true ->
          new_state = Map.delete(state, :awaiting_stream)
          {:next, :default, new_state}
      end
    else
      # Request Worker to start streaming
      start_stream(state)
    end
  end

  defp handle_stream_error(state, reason) do
    case next_fallback(state) do
      {:ok, provider, model, tried} ->
        Logger.warning("llm_stream_fallback",
          session_id: state.session_id,
          provider: provider,
          model: model,
          reason: inspect(reason)
        )

        state
        |> Map.delete(:awaiting_stream)
        |> Map.delete(:stream_error)
        |> Map.delete(:pending_text)
        |> Map.put(:fallback_models_tried, tried)
        |> Map.put(
          :agent_config,
          fallback_agent_config(Map.get(state, :agent_config), provider, model)
        )
        |> Map.put(:request, fallback_request(state.request, model))
        |> start_stream()

      :error ->
        Logger.warning("llm_stream_error", reason: inspect(reason))

        new_state =
          state
          |> Map.delete(:awaiting_stream)
          |> Map.put(:stream_error, reason)
          |> Map.put(:pending_text, provider_error_text(reason))
          |> Map.put_new(:pending_reasoning_signature, "")

        {:next, :error, new_state}
    end
  end

  defp start_stream(state) do
    if pid = worker_pid(state.session_id) do
      send(pid, {:node_request, :start_stream, state.request, current_provider(state)})
    end

    {:wait, Map.put(state, :awaiting_stream, true)}
  end

  defp next_fallback(state) do
    provider = current_provider(state)
    model = current_model(state)
    tried = MapSet.put(fallback_models_tried(state), model_key(provider, model))

    state
    |> Map.get(:agent_config, %{})
    |> Map.get(:fallback_models, "")
    |> parse_fallback_models(provider)
    |> Enum.find(fn {fallback_provider, fallback_model} ->
      not MapSet.member?(tried, model_key(fallback_provider, fallback_model))
    end)
    |> case do
      {fallback_provider, fallback_model} -> {:ok, fallback_provider, fallback_model, tried}
      nil -> :error
    end
  end

  defp fallback_models_tried(state) do
    case Map.get(state, :fallback_models_tried) do
      %MapSet{} = tried -> tried
      tried when is_list(tried) -> MapSet.new(tried)
      _ -> MapSet.new()
    end
  end

  defp parse_fallback_models(models, current_provider) when is_binary(models) do
    models
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_fallback_model(&1, current_provider))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_fallback_models(models, current_provider) when is_list(models) do
    models
    |> Enum.map(&parse_fallback_model(&1, current_provider))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_fallback_models(_models, _current_provider), do: []

  defp parse_fallback_model(%{provider: provider, model: model}, _current_provider)
       when is_binary(provider) and is_binary(model) and provider != "" and model != "" do
    {provider, model}
  end

  defp parse_fallback_model(%{"provider" => provider, "model" => model}, current_provider) do
    parse_fallback_model(%{provider: provider, model: model}, current_provider)
  end

  defp parse_fallback_model(model, current_provider) when is_binary(model) do
    case String.split(String.trim(model), "/", parts: 2) do
      [provider, fallback_model] when provider != "" and fallback_model != "" ->
        {provider, fallback_model}

      [fallback_model] when fallback_model != "" ->
        {current_provider, fallback_model}

      _ ->
        nil
    end
  end

  defp parse_fallback_model(_model, _current_provider), do: nil

  defp fallback_agent_config(agent_config, provider, model) do
    (agent_config || %{})
    |> Map.put(:provider, provider)
    |> Map.put(:model, model)
  end

  defp fallback_request(request, model) when is_map(request), do: Map.put(request, :model, model)
  defp fallback_request(request, _model), do: request

  defp current_provider(state) do
    get_in(state, [:agent_config, :provider]) ||
      get_in(state, [:request, :provider]) ||
      get_in(state, [:request, "provider"]) ||
      "anthropic"
  end

  defp current_model(state) do
    get_in(state, [:request, :model]) ||
      get_in(state, [:request, "model"]) ||
      get_in(state, [:agent_config, :model])
  end

  defp model_key(provider, model), do: {to_string(provider || ""), to_string(model || "")}

  defp provider_error_text(reason) when is_binary(reason), do: "Provider error: #{reason}"
  defp provider_error_text(reason), do: "Provider error: #{inspect(reason)}"
end
