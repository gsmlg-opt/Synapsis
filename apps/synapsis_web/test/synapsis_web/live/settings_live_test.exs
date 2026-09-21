defmodule SynapsisWeb.SettingsLiveTest do
  use SynapsisWeb.ConnCase

  test "settings root renders Appearance", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "h1", "Appearance")
    assert page_title(view) =~ "Appearance"
  end

  test "renders accessible Auto, Light, and Dark theme choices", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             view,
             "#appearance-theme.theme-controller[role='radiogroup'][aria-label='Theme'][phx-hook='ThemeSwitcher']"
           )

    for {value, label} <- [{"auto", "Auto"}, {"sunshine", "Light"}, {"moonlight", "Dark"}] do
      assert has_element?(view, "#appearance-theme label", label)

      assert has_element?(
               view,
               "#appearance-theme input[type='radio'][name='theme-mode'][value='#{value}']"
             )
    end
  end

  test "keeps other settings in the sidebar instead of overview cards", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    for path <- ["providers", "models", "memory", "mcp"] do
      assert has_element?(view, "[data-testid='settings-sidebar'] a[href='/settings/#{path}']")

      refute has_element?(
               view,
               "[data-testid='settings-layout'] main a[href='/settings/#{path}']"
             )
    end

    refute has_element?(view, "[data-testid='settings-sidebar']", "Overview")
  end

  test "theme control is absent from the appbar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    refute has_element?(view, "header.appbar [phx-hook='ThemeSwitcher']")
    refute has_element?(view, "header.appbar input[type='radio']")
  end
end
