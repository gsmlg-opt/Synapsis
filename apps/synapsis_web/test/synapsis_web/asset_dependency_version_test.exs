defmodule SynapsisWeb.AssetDependencyVersionTest do
  use ExUnit.Case, async: true

  test "LiveView JavaScript matches the server dependency" do
    package_json =
      "../../package.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()

    javascript_version = get_in(package_json, ["dependencies", "phoenix_live_view"])
    server_version = :phoenix_live_view |> Application.spec(:vsn) |> to_string()

    assert javascript_version == server_version
  end
end
