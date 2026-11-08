Code.require_file("diffs_viewer_plugin.exs", __DIR__)
["--", capsule] = System.argv()
source = Path.join(capsule, "packages/tool-host/src/diffs/openclaw")
{:ok, _} = Application.ensure_all_started(:duskmoon_bundler)

{:ok, result} =
  DuskmoonBundler.Builder.build(
    entry: Path.join(source, "extensions/diffs/src/viewer-client.js"),
    outdir: Path.join(capsule, "assets"),
    node_modules: Path.join(capsule, "node_modules"),
    plugins: [
      {Synapsis.Diffs.ViewerBuildPlugin,
       shiki: Path.join(source, "scripts/diffs-shiki-curated.js")}
    ],
    define: %{"__OPENCLAW_DIFFS_LANGUAGE_PACK__" => "false", "NaN" => "Number.NaN"},
    format: :esm,
    target: "es2020",
    code_splitting: false,
    hash: false,
    sourcemap: false,
    public_dir: false,
    minify: true,
    name: "viewer-runtime"
  )

IO.inspect(result, label: "Diffs viewer build")
