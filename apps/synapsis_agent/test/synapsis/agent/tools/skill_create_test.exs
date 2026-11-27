defmodule Synapsis.Agent.Tools.SkillCreateTest do
  use ExUnit.Case, async: false
  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Tools.SkillCreate
  alias Synapsis.Backplane.Connection
  alias Synapsis.{AgentConfigs, Skills}
  alias Synapsis.Config.Store

  @name "synapsis::skills_create"
  @moduletag :tmp_dir

  setup do
    bypass = Gaoxy.Test.open()

    {:ok, source} =
      Connection.create(%{
        name: "create-#{System.unique_integer([:positive])}",
        endpoint: Gaoxy.Test.url(bypass),
        credential: "first-test-token",
        sync_on_start: false,
        connection_options: %{"enabled_surfaces" => ["skills"]}
      })

    {:ok, agent} =
      AgentConfigs.create(%{
        name: "remote-author-#{System.unique_integer([:positive])}",
        config: %{"backplane_skill_source_ids" => [source.id]}
      })

    on_exit(fn ->
      Store.delete(:agent, agent.id)
      Connection.delete(source)
    end)

    context = %{agent_id: agent.id, run_id: "create-run", incarnation: 1, catalog_revision: 1}

    attrs = %{
      "source_id" => source.id,
      "slug" => "release-guide",
      "name" => "Release Guide",
      "description" => "Publish a release",
      "content" => "Check exact artifacts before publishing.\n"
    }

    %{bypass: bypass, source: source, agent: agent, context: context, attrs: attrs}
  end

  test "the required source selector and write safety are explicit", ctx do
    assert {:ok, [descriptor]} = SkillCreate.descriptors(ctx.context)
    assert descriptor.tool_name == @name
    assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert SkillCreate.permission_level(@name) == :write
    assert {:ok, _} = InputSchema.validate(descriptor.schema, ctx.attrs)

    for attrs <- [
          Map.delete(ctx.attrs, "source_id"),
          Map.put(ctx.attrs, "enabled", true),
          Map.put(ctx.attrs, "slug", "Unsafe/Name")
        ] do
      assert {:error, _} = InputSchema.validate(descriptor.schema, attrs)
      assert {:error, %Error{class: :validation}} = SkillCreate.execute(operation(ctx, attrs))
    end

    assert {:ok, target} = SkillCreate.classify(ctx.context, operation(ctx, ctx.attrs))
    assert target.action == "skill.write"
    assert target.permission_level == :write
    assert target.resource =~ ctx.source.id
    assert target.resource =~ "release-guide"
    forged = %{operation(ctx, ctx.attrs) | run_id: "another-run"}
    assert {:error, %Error{class: :forbidden}} = SkillCreate.execute(forged)
  end

  test "an unselected or disabled source is refused before HTTP", ctx do
    {:ok, _} = AgentConfigs.update(ctx.agent, %{config: %{}})
    assert {:error, %Error{class: :forbidden}} = SkillCreate.execute(operation(ctx, ctx.attrs))

    {:ok, _} =
      AgentConfigs.update(ctx.agent, %{config: %{"backplane_skill_source_ids" => [ctx.source.id]}})

    {:ok, _} = Connection.update(ctx.source, %{enabled: false})
    assert {:error, %Error{class: :forbidden}} = SkillCreate.execute(operation(ctx, ctx.attrs))
    assert Skills.list_skill_ids(ctx.agent.id) == []
  end

  describe "cloud skill creation" do
    test "POST JSON uses the current credential and returns only the exact receipt", ctx do
      {:ok, provider} =
        Synapsis.Providers.create(%{
          name: "create-provider-#{System.unique_integer([:positive])}",
          type: "openai",
          base_url: Gaoxy.Test.url(ctx.bypass, "/v1"),
          api_key_encrypted: "first-provider-token"
        })

      on_exit(fn -> Synapsis.Providers.delete(provider.id) end)
      {:ok, _} = Connection.update(ctx.source, %{provider_id: provider.id})

      {:ok, _} =
        Synapsis.Providers.update(provider.id, %{api_key_encrypted: "rotated-test-token"})

      original_skills = Skills.list()
      manifest = manifest(ctx)

      Gaoxy.Test.expect_once(ctx.bypass, "POST", "/skill-protocol/v1/skills", fn conn ->
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer rotated-test-token"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Formata.JSON.decode!(body) == Map.delete(ctx.attrs, "source_id")

        Plug.Conn.send_resp(
          conn,
          201,
          Formata.JSON.encode!(Backplane.SkillProtocol.Wire.manifest_map(manifest))
        )
      end)

      assert {:ok, %{structured: receipt} = result} =
               SkillCreate.execute(operation(ctx, ctx.attrs))

      assert receipt.skill_id == "skill/release-guide"
      assert receipt.revision == manifest.ref.revision
      assert receipt.artifact_digest == manifest.ref.artifact_digest
      assert receipt.source_id == ctx.source.id
      assert receipt.locator =~ "backplane://#{ctx.source.id}/"

      assert {:ok, _} =
               Synapsis.Agent.Tools.ResultProjection.to_part("create-result", result,
                 tool_name: @name
               )

      assert Skills.list() == original_skills
      assert Skills.list_skill_ids(ctx.agent.id) == []
      assert {:ok, source} = Connection.get(ctx.source.id)
      assert source.enabled
      assert source.artifacts == ctx.source.artifacts
      refute inspect(result) =~ "test-token"
      refute Map.has_key?(receipt, :content)
    end

    for {status, code, class} <- [
          {403, "forbidden", :forbidden},
          {409, "already_exists", :resource_conflict},
          {503, "temporarily_unavailable", :unknown_outcome}
        ] do
      test "HTTP #{status} is returned without replay", ctx do
        owner = self()

        Gaoxy.Test.expect_once(ctx.bypass, "POST", "/skill-protocol/v1/skills", fn conn ->
          send(owner, :creation_request)

          Plug.Conn.send_resp(
            conn,
            unquote(status),
            Formata.JSON.encode!(%{
              "protocol_version" => "1",
              "error" => %{
                "code" => unquote(code),
                "message" => "Rejected test creation",
                "retryable" => true,
                "context" => %{}
              }
            })
          )
        end)

        assert {:error, %Error{class: unquote(class)}} =
                 SkillCreate.execute(operation(ctx, ctx.attrs))

        assert_received :creation_request
        refute_receive :creation_request
        assert length(Gaoxy.Test.requests(ctx.bypass).entries) == 1
      end
    end

    defp manifest(ctx) do
      alias Backplane.SkillProtocol.{Bundle, SkillRef}
      root = Path.join(ctx.tmp_dir, "release-guide")
      File.mkdir_p!(root)

      File.write!(
        Path.join(root, "SKILL.md"),
        "---\nname: release-guide\ndescription: Publish a release\n---\n" <> ctx.attrs["content"]
      )

      ref = %SkillRef{
        source_id: ctx.source.id,
        skill_id: "skill/release-guide",
        revision: "created-v1"
      }

      {:ok, bundle} = Bundle.pack(root, Path.join(ctx.tmp_dir, "bundle.tar.gz"), ref: ref)
      bundle.manifest
    end
  end

  defp operation(ctx, attrs) do
    %{
      tool_name: @name,
      tool_revision: 1,
      arguments: attrs,
      run_id: "create-run",
      incarnation: 1,
      catalog_revision: 1,
      backend_context: ctx.context
    }
  end
end
