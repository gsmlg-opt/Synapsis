defmodule SynapsisServer.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../../../config/runtime.exs", __DIR__)
  @build_config Path.expand("../../../../config/config.exs", __DIR__)
  @prod_config Path.expand("../../../../config/prod.exs", __DIR__)
  @env_keys ~w(PHX_IP SECRET_KEY_BASE SYNAPSIS_ENCRYPTION_KEY SYNAPSIS_CONCORD_DATA_DIR)

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

  test "enables the endpoint in production releases" do
    assert read_endpoint_config() |> Keyword.fetch!(:server)
  end

  @tag :tmp_dir
  test "overrides packaged Concord paths on each boot while retaining store options", %{
    tmp_dir: tmp_dir
  } do
    System.put_env("SYNAPSIS_CONCORD_DATA_DIR", Path.join(tmp_dir, "build-store"))
    packaged_config = Config.Reader.read!(@build_config, env: :prod)
    packaged_concord = Keyword.fetch!(packaged_config, :concord)

    for boot <- ["first-boot", "second-boot"] do
      data_dir = Path.join(tmp_dir, boot)
      System.put_env("SYNAPSIS_CONCORD_DATA_DIR", data_dir)

      runtime_config = Config.Reader.read!(@runtime_config, env: :prod)
      boot_config = Config.Reader.merge(packaged_config, runtime_config)
      concord = Keyword.fetch!(boot_config, :concord)
      turso = Keyword.fetch!(concord, :turso)

      assert concord[:data_dir] == data_dir
      assert turso[:database] == Path.join(data_dir, "turso.db")

      assert Map.new(Keyword.drop(concord, [:data_dir, :turso])) ==
               Map.new(Keyword.drop(packaged_concord, [:data_dir, :turso]))

      assert Map.new(Keyword.delete(turso, :database)) ==
               Map.new(Keyword.delete(packaged_concord[:turso], :database))
    end
  end

  test "retains packaged Concord defaults when no runtime directory is set" do
    System.delete_env("SYNAPSIS_CONCORD_DATA_DIR")
    packaged_config = Config.Reader.read!(@build_config, env: :prod)
    runtime_config = Config.Reader.read!(@runtime_config, env: :prod)
    boot_config = Config.Reader.merge(packaged_config, runtime_config)

    assert boot_config[:concord] == packaged_config[:concord]
  end

  @tag :tmp_dir
  test "resolves production asset manifests from the installed application", %{tmp_dir: tmp_dir} do
    original_code_path =
      :synapsis_web |> :code.lib_dir() |> Path.join("ebin") |> String.to_charlist()

    original_bundler = Application.fetch_env(:duskmoon_bundler, :synapsis_web)
    original_runtime = Application.fetch_env(:duskmoon_bundler_runtime, :synapsis_web)
    app_dir = Path.join(tmp_dir, "synapsis_web-0.0.0")
    ebin = Path.join(app_dir, "ebin")
    outdir = Path.join(app_dir, "priv/static/assets")
    File.mkdir_p!(ebin)
    File.mkdir_p!(outdir)

    on_exit(fn ->
      :code.replace_path(:synapsis_web, original_code_path)

      for {app, original} <- [
            duskmoon_bundler: original_bundler,
            duskmoon_bundler_runtime: original_runtime
          ] do
        case original do
          {:ok, value} -> Application.put_env(app, :synapsis_web, value)
          :error -> Application.delete_env(app, :synapsis_web)
        end
      end
    end)

    assert :code.replace_path(:synapsis_web, String.to_charlist(ebin))

    File.write!(
      Path.join(outdir, "manifest.json"),
      Jason.encode!(%{
        "manifest_version" => 1,
        "entries" => %{
          "css/app.css" => %{"file" => "app-installed.css"},
          "js/app.js" => %{"file" => "app-installed.js"}
        }
      })
    )

    runtime_profile =
      @runtime_config
      |> Config.Reader.read!(env: :prod)
      |> Keyword.fetch!(:duskmoon_bundler_runtime)
      |> Keyword.fetch!(:synapsis_web)

    assert runtime_profile[:outdir] == outdir

    Application.put_env(:duskmoon_bundler, :synapsis_web,
      outdir: Path.join(tmp_dir, "missing-build-checkout/assets")
    )

    Application.put_env(:duskmoon_bundler_runtime, :synapsis_web, runtime_profile)

    for {source, installed} <- [
          {"/assets/css/app.css", "/assets/app-installed.css"},
          {"/assets/js/app.js", "/assets/app-installed.js"}
        ] do
      assert {:ok, ^installed} =
               DuskmoonBundler.StaticPath.resolve(SynapsisServer.Endpoint, source,
                 profile: :synapsis_web
               )
    end
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

  test "trusts Caddy's forwarded protocol while permitting loopback health checks" do
    force_ssl =
      @prod_config
      |> Config.Reader.read!(env: :prod)
      |> Keyword.fetch!(:synapsis_server)
      |> Keyword.fetch!(SynapsisServer.Endpoint)
      |> Keyword.fetch!(:force_ssl)

    assert force_ssl[:rewrite_on] == [:x_forwarded_proto]
    assert force_ssl[:exclude] == [hosts: ["localhost", "127.0.0.1"]]
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
    read_endpoint_config()
    |> Keyword.fetch!(:http)
    |> Keyword.fetch!(:ip)
  end

  defp read_endpoint_config do
    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> Keyword.fetch!(:synapsis_server)
    |> Keyword.fetch!(SynapsisServer.Endpoint)
  end
end
