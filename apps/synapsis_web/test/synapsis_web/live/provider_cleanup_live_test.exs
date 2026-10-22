defmodule SynapsisWeb.ProviderCleanupLiveTest do
  use SynapsisWeb.ConnCase

  import SynapsisWeb.ReactFormHelpers

  alias Synapsis.{Backplane, MCPConfigs, Providers, Skills}

  defmodule ObservedRefresh do
    def refresh do
      send(Application.fetch_env!(:synapsis_web, :cleanup_refresh_owner), :cleanup_refresh)
      %{}
    end
  end

  setup do
    original = Application.get_env(:synapsis_core, :mcp_refresh)
    Application.put_env(:synapsis_core, :mcp_refresh, {ObservedRefresh, :refresh, []})
    Application.put_env(:synapsis_web, :cleanup_refresh_owner, self())

    {:ok, provider} =
      Providers.create(%{
        name: "cleanup-live-#{System.unique_integer([:positive])}",
        type: "openai",
        preset: "backplane",
        base_url: "https://cleanup.example.test/v1",
        config: %{"model_catalog_migrated" => true}
      })

    on_exit(fn ->
      Providers.delete(provider.id)

      if original,
        do: Application.put_env(:synapsis_core, :mcp_refresh, original),
        else: Application.delete_env(:synapsis_core, :mcp_refresh)

      Application.delete_env(:synapsis_web, :cleanup_refresh_owner)
    end)

    {:ok, provider: provider}
  end

  test "an open agent skill list removes skills deleted with their provider", %{
    conn: conn,
    provider: provider
  } do
    skill = remote_skill(provider)
    {:ok, view, _} = live(conn, ~p"/agent/skills")
    assert has_element?(view, "a[href='/agent/skills/#{skill.id}/edit']")

    assert {:ok, _} = Providers.delete(provider.id)

    refute has_element?(view, "a[href='/agent/skills/#{skill.id}/edit']")
  end

  test "an open agent skill editor redirects when its provider deletes the skill", %{
    conn: conn,
    provider: provider
  } do
    skill = remote_skill(provider)
    {:ok, view, _} = live(conn, ~p"/agent/skills/#{skill.id}/edit")

    assert {:ok, _} = Providers.delete(provider.id)

    assert_redirect(view, ~p"/agent/skills")
  end

  test "an open skill detail redirects when its provider deletes the skill", %{
    conn: conn,
    provider: provider
  } do
    skill = remote_skill(provider)
    {:ok, view, _} = live(conn, ~p"/settings/skills/#{skill.id}")

    assert {:ok, _} = Providers.delete(provider.id)

    assert_redirect(view, ~p"/settings/skills")
  end

  test "an open MCP detail redirects when its provider deletes the config", %{
    conn: conn,
    provider: provider
  } do
    {:ok, config} = Backplane.select_mcp_provider(provider.id)
    {:ok, view, _} = live(conn, ~p"/settings/mcp/#{config.id}")
    render_async(view)
    assert_receive :cleanup_refresh

    assert {:ok, _} = Providers.delete(provider.id)
    assert is_nil(MCPConfigs.get(config.id))

    assert_redirect(view, ~p"/settings/mcp")
  end

  test "provider notifications preserve an MCP draft without restarting discovery", %{
    conn: conn,
    provider: provider
  } do
    {:ok, config} = Backplane.select_mcp_provider(provider.id)
    {:ok, view, _} = live(conn, ~p"/settings/mcp/#{config.id}")
    render_async(view)
    assert_receive :cleanup_refresh

    react_form_change(view, "mcp-config-form", %{"headers" => "X-Draft: retained"})
    assert {:ok, _} = Providers.update(provider.id, %{name: provider.name <> "-updated"})
    render(view)

    [json] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-form-id='mcp-config-form']")
      |> LazyHTML.attribute("data-initial-values")

    assert Jason.decode!(json)["headers"] == "X-Draft: retained"
    refute_receive :cleanup_refresh, 20
  end

  defp remote_skill(provider) do
    {:ok, source} = Backplane.select_provider(provider.id, "skills")

    {:ok, skill} =
      Skills.create(%{
        name: "cleanup-remote-#{System.unique_integer([:positive])}",
        scope: "global",
        config_overrides: %{
          "managed_by" => "backplane",
          "backplane_source_id" => source.id,
          "external_id" => "cleanup-remote",
          "external_revision" => "r1"
        }
      })

    skill
  end
end
