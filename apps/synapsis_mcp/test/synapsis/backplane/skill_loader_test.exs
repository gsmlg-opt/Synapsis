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
    bypass = Bypass.open()
    source_id = Ecto.UUID.generate()
    connection = connection!(source_id, bypass)
    manifest = %{bundle.manifest | ref: %{bundle.manifest.ref | source_id: source_id}}

    Bypass.expect_once(bypass, "GET", "/skill-protocol/v1/resolve", fn conn ->
      assert URI.decode_query(conn.query_string) == %{
               "revision" => "release/7",
               "skill_id" => "review"
             }

      json(conn, Wire.manifest_map(manifest))
    end)

    Bypass.expect_once(bypass, "GET", "/skill-protocol/v1/artifact", fn conn ->
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
    bypass = Bypass.open()
    source_id = Ecto.UUID.generate()
    _connection = connection!(source_id, bypass)
    manifest = %{bundle.manifest | ref: %{bundle.manifest.ref | source_id: source_id}}

    Bypass.expect_once(bypass, "GET", "/skill-protocol/v1/resolve", fn conn ->
      json(conn, Wire.manifest_map(manifest))
    end)

    Bypass.expect_once(bypass, "GET", "/skill-protocol/v1/artifact", fn conn ->
      Plug.Conn.send_resp(conn, 200, "not-the-artifact")
    end)

    assert {:error, message} =
             SkillLoader.load(entry(source_id, manifest.artifact_digest), %{
               session_id: "session-2"
             })

    assert message =~ "digest"
  end

  defp connection!(source_id, bypass) do
    {:ok, connection} =
      Connection.create(%{
        id: source_id,
        name: "skill-loader-#{String.slice(source_id, 0, 8)}",
        endpoint: "http://localhost:#{bypass.port}",
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
