defmodule Synapsis.Backplane.SkillDiscoveryTest do
  use ExUnit.Case, async: false

  alias Synapsis.Backplane.{Connection, SkillDiscovery}
  alias Synapsis.{AgentConfigs, SkillReader, Skills}
  @moduletag :tmp_dir

  alias Synapsis.Config.Store

  setup do
    bypass = Gaoxy.Test.open()

    {:ok, source} =
      Connection.create(%{
        name: "discovery-#{System.unique_integer([:positive])}",
        endpoint: Gaoxy.Test.url(bypass),
        connection_options: %{"enabled_surfaces" => ["skills"]},
        sync_on_start: false
      })

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "remote-discovery-#{System.unique_integer([:positive])}",
        config: %{"backplane_skill_source_ids" => [source.id]}
      })

    on_exit(fn ->
      Store.delete(:agent, agent.id)
      Connection.delete(source)
    end)

    {:ok, snapshot} = SkillReader.snapshot(agent.id)
    %{bypass: bypass, source: source, agent: agent, snapshot: snapshot}
  end

  describe "cloud skill discovery" do
    test "always metadata is independent of imports and marks assignment requirements", ctx do
      original = Skills.list()

      Gaoxy.Test.expect_once(ctx.bypass, "GET", "/skill-protocol/v1/catalog", fn conn ->
        assert URI.decode_query(conn.query_string)["view"] == "always"

        json(conn, %{
          "protocol_version" => "1",
          "view" => "always",
          "data" => [descriptor("always"), descriptor("manual", true)],
          "next_cursor" => nil
        })
      end)

      assert %{sources: [%{entries: [entry], partial: false}], errors: %{}} =
               SkillDiscovery.always(ctx.agent.id, ctx.snapshot)

      assert entry.skill_id == "always"
      assert entry.description =~ "Agent assignment required"
      assert Skills.list() == original
      assert {:error, :not_found} = SkillReader.read(ctx.snapshot, entry.locator)
    end

    test "empty always catalog remains successful", ctx do
      Gaoxy.Test.expect_once(ctx.bypass, "GET", "/skill-protocol/v1/catalog", fn conn ->
        json(conn, %{
          "protocol_version" => "1",
          "view" => "always",
          "data" => [],
          "next_cursor" => nil
        })
      end)

      assert %{sources: [%{entries: []}], errors: errors} =
               SkillDiscovery.always(ctx.agent.id, ctx.snapshot)

      assert errors == %{}
    end

    test "an old server cannot silently supply its complete catalog", ctx do
      Gaoxy.Test.expect_once(ctx.bypass, "GET", "/skill-protocol/v1/catalog", fn conn ->
        json(conn, %{
          "protocol_version" => "1",
          "data" => [descriptor("all")],
          "next_cursor" => nil
        })
      end)

      assert %{sources: [], errors: errors} = SkillDiscovery.always(ctx.agent.id, ctx.snapshot)
      assert errors[ctx.source.id] == :unsupported_capability
    end

    test "search keeps exact references and only assigned matching locators are readable", ctx do
      descriptor = descriptor("searchable")

      {:ok, record} =
        Skills.create(%{
          name: "searchable",
          config_overrides: %{
            "source" => "backplane",
            "backplane_source_id" => ctx.source.id,
            "external_id" => descriptor["skill_id"],
            "source_metadata" => descriptor
          }
        })

      on_exit(fn -> Store.delete(:skill, record.id) end)

      Gaoxy.Test.expect(ctx.bypass, "GET", "/skill-protocol/v1/search", fn conn ->
        params = URI.decode_query(conn.query_string)
        assert params["q"] == "quartzneedle"

        json(conn, %{
          "protocol_version" => "1",
          "view" => "search",
          "data" => [descriptor],
          "next_cursor" => "next"
        })
      end)

      assert {:ok, %{results: [hit], truncated: true, next_cursor: "next"}} =
               SkillDiscovery.search(ctx.agent.id, ctx.snapshot, ctx.source.id, "quartzneedle",
                 limit: 5
               )

      assert hit.assignment_required
      refute hit.readable
      assert hit.revision == "rev-1"
      assert hit.artifact_digest == descriptor["artifact_digest"]
      assert {:ok, _} = Skills.assign_skills(ctx.agent, [record.id])
      {:ok, assigned_snapshot} = SkillReader.snapshot(ctx.agent.id)

      assert {:ok, %{results: [%{readable: true, assignment_required: false}]}} =
               SkillDiscovery.search(
                 ctx.agent.id,
                 assigned_snapshot,
                 ctx.source.id,
                 "quartzneedle"
               )
    end

    test "unselected or disabled sources cannot be searched and never change assignments", ctx do
      assert {:error, :source_unavailable} =
               SkillDiscovery.search(ctx.agent.id, ctx.snapshot, Ecto.UUID.generate(), "query")

      {:ok, _} = Connection.update(ctx.source, %{enabled: false})

      assert {:error, :source_unavailable} =
               SkillDiscovery.search(ctx.agent.id, ctx.snapshot, ctx.source.id, "query")

      assert Skills.list_skill_ids(ctx.agent.id) == []
    end

    test "native search and reads use the published revision and its inventoried resource", ctx do
      alias Backplane.SkillProtocol.{Bundle, SkillRef, Wire}
      alias Synapsis.Agent.{Resolver, ContextBuilder}
      alias Synapsis.Agent.Tools.Skills, as: NativeSkills
      root = Path.join(ctx.tmp_dir, "search-target")
      File.mkdir_p!(Path.join(root, "references"))

      File.write!(
        Path.join(root, "SKILL.md"),
        "---\nname: search-target\ndescription: Search metadata\n---\nquartzneedle instructions\n"
      )

      File.write!(Path.join(root, "references/checklist.md"), "joint-checklist-v1\n")
      ref = %SkillRef{source_id: ctx.source.id, skill_id: "search-target", revision: "rev-1"}
      {:ok, bundle} = Bundle.pack(root, Path.join(ctx.tmp_dir, "bundle.tar.gz"), ref: ref)

      descriptor =
        Map.put(descriptor("search-target"), "artifact_digest", bundle.manifest.artifact_digest)

      owner = self()

      Gaoxy.Test.expect(ctx.bypass, "GET", "/skill-protocol/v1/catalog", fn conn ->
        params = URI.decode_query(conn.query_string)

        body = %{
          "protocol_version" => "1",
          "data" => [Map.delete(descriptor, "disable_model_invocation")],
          "next_cursor" => nil
        }

        body =
          if params["view"] == "always",
            do: body |> Map.put("view", "always") |> Map.put("data", []),
            else: body

        json(conn, body)
      end)

      Gaoxy.Test.expect(ctx.bypass, "GET", "/skill-protocol/v1/search", fn conn ->
        assert URI.decode_query(conn.query_string)["q"] == "quartzneedle"

        json(conn, %{
          "protocol_version" => "1",
          "view" => "search",
          "data" => [descriptor],
          "next_cursor" => nil
        })
      end)

      Gaoxy.Test.expect(ctx.bypass, "GET", "/skill-protocol/v1/resolve", fn conn ->
        assert URI.decode_query(conn.query_string)["revision"] == "rev-1"
        json(conn, Wire.manifest_map(bundle.manifest))
      end)

      artifact = File.read!(bundle.archive_path)

      Gaoxy.Test.expect(ctx.bypass, "GET", "/skill-protocol/v1/artifact", fn conn ->
        send(owner, :artifact_requested)
        Plug.Conn.send_resp(conn, 200, artifact)
      end)

      {:ok, synced} = Synapsis.Backplane.Sync.run(ctx.source.id)
      record_id = synced.artifacts["skill_ids"]["search-target"]
      assert is_binary(record_id)
      on_exit(fn -> Store.delete(:skill, record_id) end)
      unassigned = Resolver.resolve(ctx.agent.name)
      prompt = ContextBuilder.build_system_prompt(:coding, agent_config: unassigned)
      refute prompt =~ "quartzneedle"

      {:ok, %{results: [%{assignment_required: true} = hit]}} =
        SkillDiscovery.search(
          ctx.agent.id,
          unassigned.skill_snapshot,
          ctx.source.id,
          "quartzneedle"
        )

      assert {:error, :not_found} = SkillReader.read(unassigned.skill_snapshot, hit.locator)
      refute_receive :artifact_requested
      {:ok, _} = Skills.assign_skills(ctx.agent, [record_id])
      resolved = Resolver.resolve(ctx.agent.name)

      context = %{
        snapshot: resolved.skill_snapshot,
        run_id: "native-read",
        incarnation: 1,
        catalog_revision: 1
      }

      operation = fn name, arguments ->
        %{
          tool_name: name,
          tool_revision: 2,
          arguments: arguments,
          run_id: "native-read",
          incarnation: 1,
          catalog_revision: 1,
          backend_context: context
        }
      end

      assert {:ok, %{structured: %{results: [%{readable: true} = selected]}}} =
               NativeSkills.execute(
                 operation.("synapsis::skills_search", %{
                   "query" => "quartzneedle",
                   "source_id" => ctx.source.id
                 })
               )

      refute_receive :artifact_requested

      assert {:ok, %{structured: %{content: body}}} =
               NativeSkills.execute(
                 operation.("synapsis::skills_read", %{"locator" => selected.locator})
               )

      assert body =~ "quartzneedle"
      assert_receive :artifact_requested

      assert {:ok, %{structured: %{content: "joint-checklist-v1\n"}}} =
               NativeSkills.execute(
                 operation.("synapsis::skills_read", %{
                   "locator" => selected.locator,
                   "resource" => "references/checklist.md"
                 })
               )

      assert_receive :artifact_requested
      assert selected.artifact_digest == bundle.manifest.artifact_digest
      assert selected.revision == "rev-1"
    end

    defp descriptor(name, manual \\ false) do
      %{
        "skill_id" => name,
        "name" => name,
        "description" => "Discovery metadata",
        "revision" => "rev-1",
        "artifact_digest" => "sha256:" <> String.duplicate("a", 64),
        "publication_status" => "ready",
        "disable_model_invocation" => manual
      }
    end

    defp json(conn, value), do: Plug.Conn.send_resp(conn, 200, Formata.JSON.encode!(value))
  end
end
