defmodule SynapsisServer.ProviderControllerTest do
  use SynapsisServer.ConnCase

  alias Synapsis.Providers

  @valid_attrs %{
    "name" => "test-anthropic",
    "type" => "anthropic",
    "api_key" => "sk-ant-secret"
  }

  defp create_provider(_ctx) do
    {:ok, provider} =
      Providers.create(%{
        name: "test-anthropic",
        type: "anthropic",
        api_key_encrypted: "sk-ant-secret",
        enabled: true
      })

    %{provider: provider}
  end

  describe "GET /api/providers" do
    test "returns empty list when no providers", %{conn: conn} do
      conn = get(conn, "/api/providers")
      response = json_response(conn, 200)
      assert is_list(response["data"])
    end

    setup [:create_provider]

    test "returns provider list from DB", %{conn: conn, provider: provider} do
      conn = get(conn, "/api/providers")
      %{"data" => providers} = json_response(conn, 200)
      assert is_list(providers)

      db_provider = Enum.find(providers, fn p -> p["id"] == provider.id end)
      assert db_provider
      assert db_provider["name"] == "test-anthropic"
      assert db_provider["type"] == "anthropic"
      assert db_provider["has_api_key"] == true
      refute Map.has_key?(db_provider, "api_key_encrypted")
      refute Map.has_key?(db_provider, "api_key")
    end
  end

  describe "POST /api/providers" do
    test "creates provider with valid attrs", %{conn: conn} do
      conn = post(conn, "/api/providers", @valid_attrs)
      %{"data" => provider} = json_response(conn, 201)

      assert provider["name"] == "test-anthropic"
      assert provider["type"] == "anthropic"
      assert provider["has_api_key"] == true
      assert provider["id"]
      refute Map.has_key?(provider, "api_key_encrypted")
      refute Map.has_key?(provider, "api_key")
    end

    test "returns 422 for invalid attrs", %{conn: conn} do
      conn = post(conn, "/api/providers", %{"name" => "", "type" => ""})
      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["name"]
      assert errors["type"]
    end

    test "returns 422 for invalid type", %{conn: conn} do
      conn = post(conn, "/api/providers", %{"name" => "test", "type" => "invalid"})
      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["type"]
    end

    test "returns 422 for duplicate name", %{conn: conn} do
      post(conn, "/api/providers", @valid_attrs)
      conn = post(conn, "/api/providers", @valid_attrs)
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/providers/:id" do
    setup [:create_provider]

    test "returns provider by id", %{conn: conn, provider: provider} do
      conn = get(conn, "/api/providers/#{provider.id}")
      %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "test-anthropic"
      assert data["has_api_key"] == true
    end

    test "returns 404 for missing provider", %{conn: conn} do
      conn = get(conn, "/api/providers/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "PUT /api/providers/:id" do
    setup [:create_provider]

    test "updates provider", %{conn: conn, provider: provider} do
      conn = put(conn, "/api/providers/#{provider.id}", %{"base_url" => "https://custom.api.com"})
      %{"data" => data} = json_response(conn, 200)
      assert data["base_url"] == "https://custom.api.com"
    end

    test "updates api key", %{conn: conn, provider: provider} do
      conn = put(conn, "/api/providers/#{provider.id}", %{"api_key" => "new-key"})
      %{"data" => data} = json_response(conn, 200)
      assert data["has_api_key"] == true
    end

    test "returns 404 for missing provider", %{conn: conn} do
      conn = put(conn, "/api/providers/#{Ecto.UUID.generate()}", %{"enabled" => false})
      assert json_response(conn, 404)
    end

    test "returns 422 for invalid update", %{conn: conn, provider: provider} do
      conn = put(conn, "/api/providers/#{provider.id}", %{"type" => "invalid"})
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/providers/:id" do
    setup [:create_provider]

    test "deletes provider", %{conn: conn, provider: provider} do
      conn = delete(conn, "/api/providers/#{provider.id}")
      assert response(conn, 204)

      conn = get(build_conn(), "/api/providers/#{provider.id}")
      assert json_response(conn, 404)
    end

    test "returns 404 for missing provider", %{conn: conn} do
      conn = delete(conn, "/api/providers/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/auth/:provider" do
    setup [:create_provider]

    test "authenticates provider with api key", %{conn: conn} do
      conn = post(conn, "/api/auth/test-anthropic", %{"api_key" => "new-secret-key"})
      %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "test-anthropic"
      assert data["has_api_key"] == true
    end

    test "returns 404 for unknown provider name", %{conn: conn} do
      conn = post(conn, "/api/auth/nonexistent", %{"api_key" => "key"})
      assert json_response(conn, 404)
    end

    test "returns 422 when api_key missing", %{conn: conn} do
      conn = post(conn, "/api/auth/test-anthropic", %{})
      assert json_response(conn, 422)
    end
  end

  describe "GET /api/providers/by-name/:name/models" do
    test "returns models for anthropic", %{conn: conn} do
      conn = get(conn, "/api/providers/by-name/anthropic/models")
      %{"data" => models} = json_response(conn, 200)
      assert is_list(models)
      assert length(models) > 0
    end

    test "returns 404 for unknown provider", %{conn: conn} do
      conn = get(conn, "/api/providers/by-name/unknown_xyz/models")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/providers/:id/models" do
    setup [:create_provider]

    test "returns models for DB provider", %{conn: conn, provider: provider} do
      conn = get(conn, "/api/providers/#{provider.id}/models")
      %{"data" => models} = json_response(conn, 200)
      assert is_list(models)
      assert length(models) > 0
    end

    test "returns 404 for missing provider id", %{conn: conn} do
      conn = get(conn, "/api/providers/#{Ecto.UUID.generate()}/models")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/providers/:id/test" do
    setup [:create_provider]

    test "returns ok status for provider with static models", %{conn: conn, provider: provider} do
      conn = post(conn, "/api/providers/#{provider.id}/test", %{})
      response = json_response(conn, 200)
      assert response["data"]["status"] == "ok"
      assert is_integer(response["data"]["models_count"])
    end

    test "returns 404 for missing provider", %{conn: conn} do
      conn = post(conn, "/api/providers/#{Ecto.UUID.generate()}/test", %{})
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/providers (env detection)" do
    test "includes env provider when ANTHROPIC_API_KEY is set", %{conn: conn} do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-env-test")

      conn = get(conn, "/api/providers")
      response = json_response(conn, 200)

      env_provider = Enum.find(response["data"], fn p -> p["source"] == "env" end)
      assert env_provider, "expected an env-sourced provider in response"
      assert env_provider["name"] == "anthropic"
      assert env_provider["has_api_key"] == true

      System.delete_env("ANTHROPIC_API_KEY")
    end

    test "excludes env provider when same name exists in DB", %{conn: conn} do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-env-dup")

      {:ok, _} =
        Providers.create(%{
          name: "anthropic",
          type: "anthropic",
          api_key_encrypted: "sk-ant-db",
          enabled: true
        })

      conn = get(conn, "/api/providers")
      response = json_response(conn, 200)

      anthropic_entries = Enum.filter(response["data"], fn p -> p["name"] == "anthropic" end)
      assert length(anthropic_entries) == 1

      System.delete_env("ANTHROPIC_API_KEY")
    end
  end
end
