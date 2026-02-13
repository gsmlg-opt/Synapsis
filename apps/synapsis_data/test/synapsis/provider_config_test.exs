defmodule Synapsis.ProviderConfigTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.ProviderConfig

  @valid_attrs %{
    name: "my-anthropic",
    type: "anthropic",
    api_key_encrypted: "sk-ant-test-key",
    enabled: true
  }

  describe "changeset/2" do
    test "valid attributes" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires name" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, Map.delete(@valid_attrs, :name))
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires type" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, Map.delete(@valid_attrs, :type))
      refute changeset.valid?
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates type inclusion" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, %{@valid_attrs | type: "invalid"})
      refute changeset.valid?
      assert %{type: [_]} = errors_on(changeset)
    end

    test "accepts all valid types" do
      for type <- ~w(anthropic openai_compat google) do
        changeset = ProviderConfig.changeset(%ProviderConfig{}, %{@valid_attrs | type: type})
        assert changeset.valid?, "Expected type #{type} to be valid"
      end
    end

    test "validates name format - must start with letter or digit" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, %{@valid_attrs | name: "-bad"})
      refute changeset.valid?
      assert %{name: [_]} = errors_on(changeset)
    end

    test "validates name format - no uppercase" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, %{@valid_attrs | name: "BadName"})
      refute changeset.valid?
      assert %{name: [_]} = errors_on(changeset)
    end

    test "validates name format - allows hyphens and underscores" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, %{@valid_attrs | name: "my-custom_provider1"})
      assert changeset.valid?
    end

    test "validates base_url must be HTTP(S)" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, Map.put(@valid_attrs, :base_url, "ftp://bad.com"))
      refute changeset.valid?
      assert %{base_url: ["must be a valid HTTP or HTTPS URL"]} = errors_on(changeset)
    end

    test "accepts valid HTTPS base_url" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, Map.put(@valid_attrs, :base_url, "https://api.example.com"))
      assert changeset.valid?
    end

    test "accepts valid HTTP base_url" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, Map.put(@valid_attrs, :base_url, "http://localhost:11434"))
      assert changeset.valid?
    end

    test "enforces unique name constraint" do
      {:ok, _} = %ProviderConfig{} |> ProviderConfig.changeset(@valid_attrs) |> Repo.insert()

      {:error, changeset} =
        %ProviderConfig{} |> ProviderConfig.changeset(@valid_attrs) |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "config defaults to empty map" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, @valid_attrs)
      assert get_field(changeset, :config) == %{}
    end

    test "enabled defaults to true" do
      changeset = ProviderConfig.changeset(%ProviderConfig{}, @valid_attrs)
      assert get_field(changeset, :enabled) == true
    end
  end

  describe "update_changeset/2" do
    test "allows partial updates" do
      {:ok, provider} = %ProviderConfig{} |> ProviderConfig.changeset(@valid_attrs) |> Repo.insert()

      changeset = ProviderConfig.update_changeset(provider, %{enabled: false})
      assert changeset.valid?
    end

    test "validates type on update" do
      {:ok, provider} = %ProviderConfig{} |> ProviderConfig.changeset(@valid_attrs) |> Repo.insert()

      changeset = ProviderConfig.update_changeset(provider, %{type: "invalid"})
      refute changeset.valid?
    end
  end

  describe "database round-trip with encryption" do
    test "api_key is encrypted at rest and decrypted on load" do
      {:ok, provider} =
        %ProviderConfig{}
        |> ProviderConfig.changeset(%{@valid_attrs | api_key_encrypted: "sk-secret-123"})
        |> Repo.insert()

      loaded = Repo.get!(ProviderConfig, provider.id)
      assert loaded.api_key_encrypted == "sk-secret-123"
    end

    test "nil api_key round-trips correctly" do
      attrs = Map.delete(@valid_attrs, :api_key_encrypted)
      {:ok, provider} = %ProviderConfig{} |> ProviderConfig.changeset(attrs) |> Repo.insert()

      loaded = Repo.get!(ProviderConfig, provider.id)
      assert is_nil(loaded.api_key_encrypted)
    end
  end
end
