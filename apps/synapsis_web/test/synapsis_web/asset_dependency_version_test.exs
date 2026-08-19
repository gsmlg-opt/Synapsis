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
          nil ->
            []

          version ->
            resolved = resolve_js_version(project_root, Path.dirname(manifest), version)
            [{Path.relative_to(manifest, project_root), resolved}]
        end
      end)

    server_version = :phoenix_live_view |> Application.spec(:vsn) |> to_string()

    assert javascript_versions != []

    assert Enum.all?(javascript_versions, fn {_manifest, version} -> version == server_version end),
           "expected every workspace phoenix_live_view dependency to equal #{server_version}, " <>
             "got #{inspect(javascript_versions)}"
  end

  # duskmoon_npm installs Phoenix JS from Hex deps via `file:../../deps/...`.
  defp resolve_js_version(_project_root, package_dir, "file:" <> relative_path) do
    package_dir
    |> Path.join(relative_path)
    |> Path.expand()
    |> Path.join("package.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("version")
  end

  defp resolve_js_version(_project_root, _package_dir, version) when is_binary(version),
    do: version
end
