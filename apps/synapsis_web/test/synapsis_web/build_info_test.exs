defmodule SynapsisWeb.BuildInfoTest do
  use ExUnit.Case, async: false

  test "reports application version and the captured build timestamp" do
    info = SynapsisWeb.BuildInfo.info()

    assert info.version == to_string(Application.spec(:synapsis_web, :vsn))
    assert info.environment == :test
    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(info.build_time)
    assert info.release_time == SynapsisWeb.BuildInfo.Source.release_time()
  end

  test "changing injected metadata invalidates cached build information" do
    original = System.get_env("SYNAPSIS_GIT_REF")

    on_exit(fn ->
      if original do
        System.put_env("SYNAPSIS_GIT_REF", original)
      else
        System.delete_env("SYNAPSIS_GIT_REF")
      end
    end)

    System.put_env("SYNAPSIS_GIT_REF", "changed-#{SynapsisWeb.BuildInfo.info().git_ref}")

    assert SynapsisWeb.BuildInfo.__mix_recompile__?()
  end

  test "missing Git and empty Docker build arguments leave metadata unavailable" do
    original =
      Map.new(["PATH", "SYNAPSIS_GIT_REF", "SYNAPSIS_RELEASE_TIME"], fn key ->
        {key, System.get_env(key)}
      end)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env("PATH", "")
    System.put_env("SYNAPSIS_GIT_REF", "")
    System.put_env("SYNAPSIS_RELEASE_TIME", "")

    assert SynapsisWeb.BuildInfo.Source.git_ref() == nil
    assert SynapsisWeb.BuildInfo.Source.release_time() == nil
  end
end
