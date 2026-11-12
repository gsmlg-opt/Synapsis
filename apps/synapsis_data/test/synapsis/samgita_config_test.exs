defmodule Synapsis.SamgitaConfigTest do
  use Synapsis.DataCase

  alias Synapsis.Config.Store
  alias Synapsis.SamgitaConfig

  setup do
    clear_config_store(:samgita)
    :ok
  end

  test "rotated secrets resolve but are stored encrypted" do
    assert {:ok, token} = SamgitaConfig.rotate_secret(:app_server_token)
    assert byte_size(token) == 43
    assert {:ok, ^token} = SamgitaConfig.resolve_secret(:app_server_token)

    file = File.read!(Store.file_path(:samgita))
    refute file =~ token
    assert file =~ "enc:v1:"
  end

  test "get/0 reports configured secrets without exposing them" do
    assert {:ok, token} = SamgitaConfig.rotate_secret(:app_server_token)
    config = SamgitaConfig.get()

    assert config.app_server_token? == true
    assert config.agent_credential? == false
    refute inspect(config) =~ token
  end

  test "rotating one secret keeps the other and the base url" do
    :ok = SamgitaConfig.put_base_url("http://10.100.10.28:4870")
    {:ok, credential} = SamgitaConfig.rotate_secret(:agent_credential)
    {:ok, _token} = SamgitaConfig.rotate_secret(:app_server_token)

    assert {:ok, ^credential} = SamgitaConfig.resolve_secret(:agent_credential)
    assert SamgitaConfig.get().base_url == "http://10.100.10.28:4870"
  end

  test "put_base_url/1 accepts only http(s) urls with a host" do
    assert {:error, _} = SamgitaConfig.put_base_url("ftp://x")
    assert {:error, _} = SamgitaConfig.put_base_url("http://")
    assert :ok = SamgitaConfig.put_base_url("http://10.100.10.28:4870")
    assert SamgitaConfig.get().base_url == "http://10.100.10.28:4870"
  end

  test "resolve_secret/1 fails closed when nothing is configured" do
    assert {:error, :not_configured} = SamgitaConfig.resolve_secret(:agent_credential)
    assert SamgitaConfig.get().base_url == nil
  end
end
