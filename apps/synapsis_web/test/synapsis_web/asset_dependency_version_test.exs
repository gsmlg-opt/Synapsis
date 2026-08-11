defmodule SynapsisWeb.AssetDependencyVersionTest do
  use ExUnit.Case, async: true

  test "every workspace LiveView JavaScript dependency matches the server dependency" do
    project_root = Path.expand("../../../..", __DIR__)

    javascript_versions =
      ["apps/*/package.json", "packages/*/package.json"]
      |> Enum.flat_map(&Path.wildcard(Path.join(project_root, &1)))
      |> Enum.flat_map(fn manifest ->
        package_json = manifest |> File.read!() |> Jason.decode!()

        case get_in(package_json, ["dependencies", "phoenix_live_view"]) do
          nil -> []
          version -> [{Path.relative_to(manifest, project_root), version}]
        end
      end)

    server_version = :phoenix_live_view |> Application.spec(:vsn) |> to_string()

    assert javascript_versions != []

    assert Enum.all?(javascript_versions, fn {_manifest, version} -> version == server_version end),
           "expected every workspace phoenix_live_view dependency to equal #{server_version}, " <>
             "got #{inspect(javascript_versions)}"
  end
end
