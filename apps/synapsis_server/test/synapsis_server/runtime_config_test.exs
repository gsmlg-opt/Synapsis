defmodule SynapsisServer.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../../../config/runtime.exs", __DIR__)
  @env_keys ~w(PHX_IP SECRET_KEY_BASE SYNAPSIS_ENCRYPTION_KEY)

  setup do
    original_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    System.put_env(
      "SECRET_KEY_BASE",
      "0123456789012345678901234567890123456789012345678901234567890123"
    )

    System.put_env("SYNAPSIS_ENCRYPTION_KEY", "01234567890123456789012345678901")

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "binds production HTTP to IPv4 loopback by default" do
    assert endpoint_ip(nil) == {127, 0, 0, 1}
  end

  test "accepts an explicit IPv4 bind address" do
    assert endpoint_ip("0.0.0.0") == {0, 0, 0, 0}
  end

  test "accepts an explicit IPv6 bind address" do
    assert endpoint_ip("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
  end

  test "rejects an invalid bind address" do
    assert_raise RuntimeError, ~r/invalid PHX_IP/, fn -> endpoint_ip("not-an-ip") end
  end

  defp endpoint_ip(nil) do
    System.delete_env("PHX_IP")
    read_endpoint_ip()
  end

  defp endpoint_ip(value) do
    System.put_env("PHX_IP", value)
    read_endpoint_ip()
  end

  defp read_endpoint_ip do
    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:synapsis_server)
    |> Keyword.fetch!(SynapsisServer.Endpoint)
    |> Keyword.fetch!(:http)
    |> Keyword.fetch!(:ip)
  end
end
