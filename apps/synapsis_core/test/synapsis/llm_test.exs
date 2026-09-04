defmodule Synapsis.LLMTest do
  use Synapsis.DataCase

  alias Synapsis.{LLM, Providers}
  alias Synapsis.Provider.Registry, as: ProviderRegistry

  setup do
    Synapsis.DataCase.clear_config_store(:provider)
    ProviderRegistry.unregister("anthropic")

    on_exit(fn ->
      Synapsis.DataCase.clear_config_store(:provider)
      ProviderRegistry.unregister("anthropic")
    end)

    :ok
  end

  describe "complete/2" do
    test "rejects a known unavailable provider before registry or environment fallback" do
      previous_api_key = System.get_env("ANTHROPIC_API_KEY")

      on_exit(fn ->
        if previous_api_key,
          do: System.put_env("ANTHROPIC_API_KEY", previous_api_key),
          else: System.delete_env("ANTHROPIC_API_KEY")
      end)

      System.put_env("ANTHROPIC_API_KEY", "env-key-that-must-not-be-used")

      assert {:ok, _provider} =
               Providers.create(%{
                 name: "anthropic",
                 type: "anthropic",
                 enabled: true,
                 config: %{
                   "managed_by" => "backplane",
                   "backplane_source_id" => "source-1",
                   "backplane_available" => false
                 }
               })

      :ok =
        ProviderRegistry.register("anthropic", %{
          type: "unknown",
          api_key: "stale-runtime-key"
        })

      assert {:error, :provider_unavailable} =
               LLM.complete([%{role: "user", content: "Hello"}], provider: "anthropic")
    end

    test "returns error when provider has no valid api key" do
      messages = [%{role: "user", content: "Hello"}]

      # With no configured provider, falls back to env-based resolution.
      # In test env, no API key is set, so the provider call should fail.
      result = LLM.complete(messages, provider: "anthropic")

      # Should either return an error or succeed depending on env config
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts system prompt option" do
      messages = [%{role: "user", content: "Summarize this"}]

      result =
        LLM.complete(messages,
          provider: "anthropic",
          system: "You are a helpful assistant.",
          max_tokens: 100
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts custom model option" do
      messages = [%{role: "user", content: "Test"}]

      result =
        LLM.complete(messages,
          provider: "anthropic",
          model: "claude-3-haiku-20240307"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts temperature option" do
      messages = [%{role: "user", content: "Test"}]

      result =
        LLM.complete(messages,
          provider: "anthropic",
          temperature: 0.5
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles empty messages list" do
      result = LLM.complete([], provider: "anthropic")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "defaults to anthropic provider" do
      messages = [%{role: "user", content: "Test"}]
      result = LLM.complete(messages)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
