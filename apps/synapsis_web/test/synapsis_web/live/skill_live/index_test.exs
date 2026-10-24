defmodule SynapsisWeb.SkillLive.IndexTest do
  use SynapsisWeb.ConnCase
  import SynapsisWeb.ReactFormHelpers

  test "an open source picker refreshes providers added and deleted elsewhere", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings/skills")

    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "live-source-#{System.unique_integer([:positive])}",
        type: "openai",
        preset: "backplane",
        base_url: "https://backplane.example.test/v1"
      })

    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})

    assert has_element?(
             view,
             "[data-form-id='skill-source-form'] [data-dm-react-field*='#{provider.id}']"
           )

    assert {:ok, _} = Synapsis.Providers.delete(provider.id)
    Phoenix.PubSub.broadcast(Synapsis.PubSub, "providers:catalog", {:provider_catalog_changed})

    refute has_element?(
             view,
             "[data-form-id='skill-source-form'] [data-dm-react-field*='#{provider.id}']"
           )
  end

  setup do
    Synapsis.DataCase.clear_config_store(:skill)
    :ok
  end

  test "offers explicit provider sources without creating one on provider creation", %{conn: conn} do
    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "skill-provider-#{System.unique_integer([:positive])}",
        type: "openai",
        config: %{"preset" => "backplane"},
        base_url: "https://backplane.example.test/v1"
      })

    on_exit(fn -> Synapsis.Providers.delete(provider.id) end)
    refute Enum.any?(Synapsis.Backplane.Connection.list(), &(&1.provider_id == provider.id))
    {:ok, view, html} = live(conn, ~p"/settings/skills")
    assert html =~ "Remote skill sources"
    assert has_element?(view, "[data-form-id='skill-source-form']")
    react_form_submit(view, "skill-source-form", %{"provider_id" => provider.id})

    assert source =
             Enum.find(Synapsis.Backplane.Connection.list(), &(&1.provider_id == provider.id))

    assert source.connection_options["enabled_surfaces"] == ["skills"]
    Synapsis.Backplane.Connection.delete(source)
  end

  test "identifies a missing provider and explains the failed refresh", %{conn: conn} do
    {provider, source} = create_source()
    # Simulate an external config deletion without provider cleanup removing the source.
    :ok = Synapsis.Config.Store.Server.delete(:provider, provider.id)

    {:ok, view, _} = live(conn, ~p"/settings/skills")

    reason =
      "Provider #{provider.id} no longer exists. Choose a provider and click Add remote source."

    assert has_element?(view, "[data-source-id='#{source.id}']", reason)

    assert has_element?(
             view,
             "[data-source-id='#{source.id}'] a[href='/settings/providers']",
             "Manage providers"
           )

    view
    |> element("[phx-click='refresh_source'][phx-value-id='#{source.id}']")
    |> render_click()

    assert render_async(view) =~ "Remote skill discovery failed. #{reason}"
    assert {:ok, orphan} = Synapsis.Backplane.Connection.get(source.id)
    assert orphan.provider_id == provider.id
  end

  test "explains disabled providers", %{conn: conn} do
    {provider, source} = create_source()
    {:ok, _} = Synapsis.Providers.update(provider.id, %{enabled: false})

    {:ok, view, _} = live(conn, ~p"/settings/skills")

    assert has_element?(
             view,
             "[data-source-id='#{source.id}']",
             "Provider #{provider.name} is disabled. Enable it in Providers."
           )
  end

  test "explains an unavailable credential reference", %{conn: conn} do
    {:ok, credential} = Synapsis.Credentials.create(%{name: "skill-source-key", key: "test-key"})
    {provider, source} = create_source(%{credential_id: credential.id})
    on_exit(fn -> Synapsis.Credentials.delete(credential.id) end)
    :ok = Synapsis.Config.Store.Server.delete(:credential, credential.id)

    {:ok, view, _} = live(conn, ~p"/settings/skills")

    assert has_element?(
             view,
             "[data-source-id='#{source.id}']",
             "Provider #{provider.name} credential is unavailable. Update it in Providers."
           )
  end

  test "explains a missing provider endpoint", %{conn: conn} do
    {provider, source} = create_source()
    {:ok, _} = Synapsis.Providers.update(provider.id, %{base_url: nil})

    {:ok, view, _} = live(conn, ~p"/settings/skills")

    assert has_element?(
             view,
             "[data-source-id='#{source.id}']",
             "Provider #{provider.name} has no endpoint. Set its base URL in Providers."
           )
  end

  test "explains that a tools source requires explicit skill selection", %{conn: conn} do
    {_provider, source} = create_source(%{}, "tools")

    {:ok, view, _} = live(conn, ~p"/settings/skills")

    assert has_element?(
             view,
             "[data-source-id='#{source.id}']",
             "Skills not enabled. Choose this provider and click Add remote source to enable skill discovery."
           )

    assert has_element?(
             view,
             "[phx-click='refresh_source'][phx-value-id='#{source.id}'][disabled]"
           )

    assert render_click(view, "refresh_source", %{"id" => source.id}) =~
             "Skills not enabled. Choose this provider and click Add remote source to enable skill discovery."

    assert {:ok, unchanged} = Synapsis.Backplane.Connection.get(source.id)
    assert unchanged.connection_options["enabled_surfaces"] == ["tools"]
  end

  describe "skills page" do
    test "mounts and renders heading", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Skills"
      assert has_element?(view, "h1", "Skills")
    end

    test "shows breadcrumb navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Settings"
    end

    test "shows create form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Create"
    end

    test "lists existing skills", %{conn: conn} do
      Synapsis.Skills.create(%{name: "my-skill", scope: "global", description: "A test skill"})

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "my-skill"
      assert html =~ "global"
    end

    test "deletes a skill", %{conn: conn} do
      {:ok, skill} =
        Synapsis.Skills.create(%{name: "to-delete", scope: "global", description: "bye"})

      {:ok, view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "to-delete"

      view
      |> element(~s(button[phx-click="delete_skill"][phx-value-id="#{skill.id}"]))
      |> render_click()

      html = render(view)
      refute html =~ "to-delete"
    end

    test "create_skill with empty name shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills")
      view |> react_form_submit("create-skill-form", %{"name" => "", "scope" => "global"})
      assert render(view) =~ "Failed to create skill"
    end

    test "create_skill navigates to skill show page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills")

      assert {:error, {:live_redirect, %{to: "/settings/skills/" <> _}}} =
               view
               |> react_form_submit("create-skill-form", %{
                 "name" => "redirect-skill",
                 "scope" => "global"
               })
    end

    test "built-in skill does not show delete button", %{conn: conn} do
      {:ok, skill} =
        Synapsis.Skills.create(%{name: "builtin-skill", scope: "global", is_builtin: true})

      {:ok, view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "builtin-skill"
      # Built-in skills should not have a delete button
      refute has_element?(
               view,
               ~s(button[phx-click="delete_skill"][phx-value-id="#{skill.id}"])
             )
    end

    test "scope selector has global option only", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "Global"
      refute html =~ "Project"
    end

    test "heading displays Skills", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/skills")
      assert has_element?(view, "h1", "Skills")
    end

    test "skills are listed in order", %{conn: conn} do
      for name <- ["alpha-skill", "beta-skill", "gamma-skill"] do
        Synapsis.Skills.create(%{name: name, scope: "global"})
      end

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "alpha-skill"
      assert html =~ "beta-skill"
      assert html =~ "gamma-skill"
    end

    test "skill links to its show page", %{conn: conn} do
      {:ok, skill} = Synapsis.Skills.create(%{name: "link-test-skill", scope: "global"})

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "/settings/skills/#{skill.id}"
    end

    test "skill with global scope shows 'global' label", %{conn: conn} do
      Synapsis.Skills.create(%{name: "global-scoped", scope: "global"})

      {:ok, _view, html} = live(conn, ~p"/settings/skills")
      assert html =~ "global-scoped"
      assert html =~ "global"
    end
  end

  defp create_source(attrs \\ %{}, surface \\ "skills") do
    {:ok, provider} =
      Synapsis.Providers.create(
        Map.merge(
          %{
            name: "skill-status-#{System.unique_integer([:positive])}",
            type: "openai",
            preset: "backplane",
            base_url: "https://backplane.example.test/v1"
          },
          attrs
        )
      )

    {:ok, source} = Synapsis.Backplane.select_provider(provider.id, surface)

    on_exit(fn ->
      Synapsis.Backplane.Connection.delete(source)
      Synapsis.Providers.delete(provider.id)
    end)

    {provider, source}
  end
end
