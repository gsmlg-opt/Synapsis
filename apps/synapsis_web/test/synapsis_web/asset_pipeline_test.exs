defmodule SynapsisWeb.AssetPipelineTest do
  use ExUnit.Case, async: true

  test "development Tailwind scan covers every configured source root" do
    build_config = DuskmoonBundler.Config.build(:synapsis_web)
    server_config = DuskmoonBundler.Config.server(:synapsis_web)

    tailwind_source_roots =
      :synapsis_web
      |> DuskmoonBundler.Config.tailwind()
      |> Keyword.fetch!(:sources)
      |> Enum.map(&Path.expand(&1.base))
      |> MapSet.new()

    development_source_roots =
      [build_config.root | server_config.watch_dirs]
      |> Enum.map(&Path.expand/1)
      |> MapSet.new()

    assert MapSet.subset?(tailwind_source_roots, development_source_roots)
  end
end
