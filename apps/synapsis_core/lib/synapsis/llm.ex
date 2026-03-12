defmodule Synapsis.LLM do
  @moduledoc """
  Simple request/response LLM completion abstraction.

  Distinct from the full agent loop in Session.Worker — this is a single-shot
  completion with no tool use, no streaming, and no agent loop. Intended for:

  - Summarization (session_summarize tool)
  - Commit message generation
  - Code review
  - Any tool that needs LLM reasoning without spawning a full agent

  Uses `Synapsis.Provider.Adapter.complete/2` under the hood.
  """

  require Logger

  @default_max_tokens 1024

  @type message :: %{role: String.t(), content: String.t()}

  @type opts :: [
          provider: String.t(),
          model: String.t(),
          system: String.t(),
          max_tokens: pos_integer(),
          temperature: float()
        ]

  @doc """
  Makes a single-shot LLM completion call.

  ## Parameters

  - `messages` — list of `%{role: "user"|"assistant", content: "..."}` maps
  - `opts` — keyword list:
    - `:provider` — provider name (default: `"anthropic"`)
    - `:model` — model ID (default: provider's fast tier model)
    - `:system` — system prompt string
    - `:max_tokens` — max response tokens (default: 1024)
    - `:temperature` — sampling temperature

  ## Returns

  - `{:ok, text}` — the completion text
  - `{:error, reason}` — on failure
  """
  @spec complete([message()], opts()) :: {:ok, String.t()} | {:error, term()}
  def complete(messages, opts \\ []) do
    provider_name = Keyword.get(opts, :provider, "anthropic")
    provider_config = resolve_provider_config(provider_name)

    model =
      Keyword.get(opts, :model) ||
        provider_config[:default_model] ||
        Synapsis.Providers.model_for_tier(provider_name, :fast)

    provider_type = provider_config[:type] || provider_config["type"] || provider_name

    request =
      %{
        model: model,
        max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
        messages: messages
      }
      |> maybe_put(:system, Keyword.get(opts, :system))
      |> maybe_put(:temperature, Keyword.get(opts, :temperature))

    config = Map.put(provider_config, :type, provider_type)

    Logger.info("llm_complete_started",
      provider: provider_name,
      model: model,
      message_count: length(messages)
    )

    case Synapsis.Provider.Adapter.complete(request, config) do
      {:ok, text} = result ->
        Logger.info("llm_complete_succeeded",
          provider: provider_name,
          model: model,
          response_length: byte_size(text)
        )

        result

      {:error, reason} = result ->
        Logger.warning("llm_complete_failed",
          provider: provider_name,
          model: model,
          reason: inspect(reason)
        )

        result
    end
  end

  # Resolve provider config using the same fallback chain as Session.Worker.
  defp resolve_provider_config(provider_name) do
    case Synapsis.Provider.Registry.get(provider_name) do
      {:ok, config} ->
        config

      {:error, _} ->
        case Synapsis.Providers.get_by_name(provider_name) do
          {:ok, provider} ->
            %{
              api_key: provider.api_key_encrypted,
              base_url: provider.base_url || Synapsis.Providers.default_base_url(provider_name),
              type: provider.type
            }

          {:error, _} ->
            auth = Synapsis.Config.load_auth()
            api_key = get_in(auth, [provider_name, "apiKey"]) || get_env_key(provider_name)

            %{
              api_key: api_key,
              base_url: Synapsis.Providers.default_base_url(provider_name),
              type: provider_name
            }
        end
    end
  end

  defp get_env_key(provider_name) do
    case Synapsis.Providers.env_var_name(provider_name) do
      nil -> nil
      var -> System.get_env(var)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
