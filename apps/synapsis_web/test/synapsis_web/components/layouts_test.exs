defmodule SynapsisWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SynapsisWeb.Layouts

  @build_info %{
    version: "1.2.3",
    environment: :prod,
    git_ref: "abcdef0123456789",
    release_time: "2026-10-10T01:00:00Z",
    build_time: "2026-10-10T01:02:00Z"
  }

  test "the shared appbar places the current version next to the brand" do
    html = render_component(&Layouts.app/1, flash: %{}, inner_content: "Page content")
    document = LazyHTML.from_fragment(html)
    version = SynapsisWeb.BuildInfo.info().version

    assert LazyHTML.query(document, "header > a.appbar-brand + #app-version-trigger")
           |> LazyHTML.text() =~ "v#{version}"
  end

  test "development version adds the dev suffix and distinguishes unpublished builds" do
    html =
      render_component(&Layouts.version_badge/1,
        info: %{@build_info | environment: :dev, release_time: nil}
      )

    assert html =~ "v1.2.3-dev"
    assert html =~ "Environment: dev"
    assert html =~ "Release time: Not released"
    assert html =~ "Build time: 2026-10-10T01:02:00Z"
  end

  test "release version exposes build details through a keyboard-accessible tooltip" do
    html = render_component(&Layouts.version_badge/1, info: @build_info)
    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#app-version-trigger") |> LazyHTML.text() =~ "v1.2.3"
    refute html =~ "v1.2.3-dev"

    assert [_] =
             LazyHTML.query(
               document,
               "button[aria-describedby='app-version-tooltip'][interestfor='app-version-tooltip'][title]"
             )
             |> LazyHTML.to_tree()

    tooltip = LazyHTML.query(document, "#app-version-tooltip[role='tooltip']") |> LazyHTML.text()
    assert tooltip =~ "Git ref: abcdef0123456789"
    assert tooltip =~ "Release time: 2026-10-10T01:00:00Z"
    assert tooltip =~ "Build time: 2026-10-10T01:02:00Z"
  end

  test "builds without release metadata remain renderable" do
    html =
      render_component(&Layouts.version_badge/1,
        info: %{@build_info | environment: :test, git_ref: nil, release_time: nil}
      )

    assert html =~ "v1.2.3"
    refute html =~ "v1.2.3-dev"
    assert html =~ "Git ref: Unknown"
    assert html =~ "Release time: Not provided"
  end
end
