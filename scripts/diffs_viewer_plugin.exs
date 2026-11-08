defmodule Synapsis.Diffs.ViewerBuildPlugin do
  @moduledoc false
  @behaviour DuskmoonBundler.Plugin
  @impl true
  def name, do: "synapsis-diffs-curated"

  # Match only the bare Shiki import. Subpaths such as shiki/themes and
  # shiki/wasm must continue through the real package exports.
  def resolve("shiki", _importer, opts), do: {:ok, Keyword.fetch!(opts, :shiki)}

  def resolve("diff", importer, _opts) when is_binary(importer) do
    if String.ends_with?(importer, "/@pierre/diffs/dist/utils/parseDiffDecorations.js"),
      do: {:ok, Path.expand("diffs-empty-side-effect.js", __DIR__)},
      else: nil
  end

  def resolve(_specifier, _importer, _opts), do: nil

  @impl true
  def load(path) do
    if path == Path.expand("diffs-empty-side-effect.js", __DIR__),
      do: {:ok, "export {};\n", ".js"},
      else: nil
  end
end
