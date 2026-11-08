defmodule Synapsis.Backplane.SkillLoaderTest do
  use ExUnit.Case, async: false

  alias Backplane.SkillProtocol.{Bundle, SkillRef, Wire}
  alias Synapsis.Backplane.{Connection, SkillLoader}
  alias Synapsis.SkillCatalog.Entry

  setup %{test: test} do
    root =
      Path.join(System.tmp_dir!(), "synapsis_skill_loader_#{System.unique_integer([:positive])}")

    skill_root = Path.join(root, "review")
    archive = Path.join(root, "review.tar.gz")
    File.mkdir_p!(skill_root)

    File.write!(Path.join(skill_root, "SKILL.md"), """
    ---
    name: review
    description: Review exact revisions
    ---
    Full remote body for #{test}.
    """)

    ref = %SkillRef{source_id: "placeholder", skill_id: "review", revision: "release/7"}
    assert {:ok, bundle} = Bundle.pack(skill_root, archive, ref: ref)
    artifact = File.read!(archive)

    on_exit(fn -> File.rm_rf!(root) end)
    %{bundle: bundle, artifact: artifact}
  end

  test "resolves and prepares the exact frozen revision", %{bundle: bundle, artifact: artifact} do
    bypass = Gaoxy.Test.open()
    source_id = Ecto.UUID.generate()
    connection = connection!(source_id, bypass)
    manifest = %{bundle.manifest | ref: %{bundle.manifest.ref | source_id: source_id}}

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/resolve", fn conn ->
      assert URI.decode_query(conn.query_string) == %{
               "revision" => "release/7",
               "skill_id" => "review"
             }

      json(conn, Wire.manifest_map(manifest))
    end)

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/artifact", fn conn ->
      assert URI.decode_query(conn.query_string)["revision"] == "release/7"
      Plug.Conn.send_resp(conn, 200, artifact)
    end)

    assert {:ok, content} =
             SkillLoader.load(entry(source_id, manifest.artifact_digest), %{
               session_id: "session-1"
             })

    assert content =~ "Full remote body"

    assert {:ok, stored} = Connection.get(connection.id)
    assert stored.id == source_id
  end

  test "fails closed when the artifact does not match the exact manifest", %{bundle: bundle} do
    bypass = Gaoxy.Test.open()
    source_id = Ecto.UUID.generate()
    _connection = connection!(source_id, bypass)
    manifest = %{bundle.manifest | ref: %{bundle.manifest.ref | source_id: source_id}}

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/resolve", fn conn ->
      json(conn, Wire.manifest_map(manifest))
    end)

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/artifact", fn conn ->
      Plug.Conn.send_resp(conn, 200, "not-the-artifact")
    end)

    assert {:error, message} =
             SkillLoader.load(entry(source_id, manifest.artifact_digest), %{
               session_id: "session-2"
             })

    assert message =~ "digest"
  end

  test "linked skill reads use provider credentials per request and reject a disabled provider",
       %{bundle: bundle, artifact: artifact} do
    bypass = Gaoxy.Test.open()

    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "skill-linked-#{System.unique_integer([:positive])}",
        type: "openai",
        base_url: Gaoxy.Test.url(bypass, "/v1"),
        api_key_encrypted: "first"
      })

    {:ok, connection} =
      Connection.create(%{
        name: "provider-skill-#{System.unique_integer([:positive])}",
        provider_id: provider.id
      })

    on_exit(fn ->
      Connection.delete(connection)
      Synapsis.Providers.delete(provider.id)
    end)

    source_id = connection.id
    manifest = %{bundle.manifest | ref: %{bundle.manifest.ref | source_id: source_id}}

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/resolve", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer first"]
      {:ok, _} = Synapsis.Providers.update(provider.id, %{api_key_encrypted: "rotated"})
      json(conn, Wire.manifest_map(manifest))
    end)

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/artifact", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer rotated"]
      Plug.Conn.send_resp(conn, 200, artifact)
    end)

    assert {:ok, body} = SkillLoader.load(entry(source_id, manifest.artifact_digest), %{})
    assert body =~ "Full remote body"
    {:ok, _} = Synapsis.Providers.update(provider.id, %{enabled: false})
    assert {:error, message} = SkillLoader.load(entry(source_id, manifest.artifact_digest), %{})
    assert message =~ "provider_unavailable"
  end

  test "frozen SkillReader reads accept credential rotation between resolve and artifact",
       %{bundle: bundle, artifact: artifact} do
    bypass = Gaoxy.Test.open()

    {:ok, provider} =
      Synapsis.Providers.create(%{
        name: "skill-reader-rotation-#{System.unique_integer([:positive])}",
        type: "openai",
        base_url: Gaoxy.Test.url(bypass, "/v1"),
        api_key_encrypted: "first"
      })

    {:ok, connection} =
      Connection.create(%{
        name: "reader-rotation-#{System.unique_integer([:positive])}",
        provider_id: provider.id
      })

    source_id = connection.id
    manifest = %{bundle.manifest | ref: %{bundle.manifest.ref | source_id: source_id}}

    {:ok, skill} =
      Synapsis.Skills.create(%{
        scope: "global",
        name: "reader-rotation-review",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "review",
          "external_revision" => "release/7",
          "artifact_digest" => manifest.artifact_digest
        }
      })

    {:ok, agent} =
      Synapsis.AgentConfigs.create(%{
        name: "skill-reader-rotation-#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Synapsis.Skills.assign_skills(agent, [skill.id])
    previous_loader = Application.get_env(:synapsis_core, :skill_loader)
    Application.put_env(:synapsis_core, :skill_loader, &SkillLoader.load/2)

    on_exit(fn ->
      if previous_loader,
        do: Application.put_env(:synapsis_core, :skill_loader, previous_loader),
        else: Application.delete_env(:synapsis_core, :skill_loader)

      Synapsis.Config.Store.delete(:agent, agent.id)
      Synapsis.Config.Store.delete(:skill, skill.id)
      Connection.delete(connection)
      Synapsis.Providers.delete(provider.id)
      Synapsis.Credentials.delete(provider.credential_id)
    end)

    {:ok, snapshot} = Synapsis.SkillReader.snapshot(agent.id)
    {:ok, %{results: [hit]}} = Synapsis.SkillReader.search(snapshot, "reader-rotation")

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/resolve", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer first"]
      {:ok, rotated} = Synapsis.Providers.update(provider.id, %{api_key_encrypted: "rotated"})
      assert rotated.credential_id == provider.credential_id
      json(conn, Wire.manifest_map(manifest))
    end)

    Gaoxy.Test.expect_once(bypass, "GET", "/skill-protocol/v1/artifact", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer rotated"]
      Plug.Conn.send_resp(conn, 200, artifact)
    end)

    assert {:ok, %{content: body, artifact_digest: digest}} =
             Synapsis.SkillReader.read(snapshot, hit.locator)

    assert body =~ "Full remote body"
    assert digest == manifest.artifact_digest
    assert {:ok, %{results: [_]}} = Synapsis.SkillReader.search(snapshot, "reader-rotation")
  end

  defp connection!(source_id, bypass) do
    {:ok, connection} =
      Connection.create(%{
        id: source_id,
        name: "skill-loader-#{String.slice(source_id, 0, 8)}",
        endpoint: String.trim_trailing(Gaoxy.Test.url(bypass), "/"),
        sync_on_start: false
      })

    on_exit(fn -> Connection.delete(connection) end)
    connection
  end

  defp entry(source_id, digest) do
    %Entry{
      authority: :backplane,
      source_id: source_id,
      skill_id: "review",
      revision: "release/7",
      artifact_digest: digest,
      name: "review",
      description: "Review exact revisions",
      locator: "backplane://#{source_id}/review?revision=release%2F7",
      enabled: true,
      prompt_visible: true,
      scope: :agent,
      loader: %{type: :backplane, connection_id: source_id}
    }
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
