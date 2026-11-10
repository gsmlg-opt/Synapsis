defmodule Synapsis.SkillBodySearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.{AgentConfigs, SkillReader, SkillSearch, Skills}
  alias Synapsis.Config.Store

  @moduletag :tmp_dir
  @fixture Path.expand(
             "../../../synapsis_agent/test/fixtures/openclaw/488631c/installed-skills.json",
             __DIR__
           )

  setup do
    {:ok, agent} =
      AgentConfigs.create(%{name: "body-search-#{System.unique_integer([:positive])}"})

    on_exit(fn -> Store.delete(:agent, agent.id) end)
    %{agent: agent}
  end

  test "metadata retains weight two while body contributes weight one" do
    entries = [
      %{name: "alpha", description: "signal"},
      %{name: "beta", description: ""}
    ]

    index =
      SkillSearch.prepare_bodies([
        %{position: 0, content: "ordinary"},
        %{position: 1, content: "signal"}
      ])

    assert SkillSearch.rank(entries, "signal", index) == entries
  end

  test "metadata and body use separate BM25 populations" do
    entries = [
      %{name: "alpha", description: "signal"},
      %{name: "beta", description: ""},
      %{name: "gamma", description: "signal"},
      %{name: "delta", description: "signal"},
      %{name: "epsilon", description: "signal"}
    ]

    index =
      SkillSearch.prepare_bodies([
        %{position: 0, content: "ordinary"},
        %{position: 1, content: "signal"}
      ])

    assert Enum.map(SkillSearch.rank(entries, "signal", index), & &1.name) ==
             ["beta", "alpha", "delta", "epsilon", "gamma"]
  end

  test "whole pinned source observations independently fix ordinary body ranking" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    for row <- fixture["observations"] do
      entries =
        Enum.map(row["entries"], fn entry ->
          %{name: entry["name"], description: entry["description"], location: entry["location"]}
        end)

      bodies =
        row["entries"]
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, position} ->
          if entry["mode"] in ["inline", "bounded-reader", "local-file"] do
            [%{position: position, content: entry["content"]}]
          else
            []
          end
        end)

      index = SkillSearch.prepare_bodies(bodies)

      for search <- row["searches"] do
        actual = SkillSearch.rank(entries, search["argumentsBefore"]["query"], index)
        expected = search["result"]["details"]["skills"]

        assert Enum.map(actual, &Map.new(&1, fn {key, value} -> {Atom.to_string(key), value} end)) ==
                 expected,
               "source observation #{row["id"]}"
      end
    end
  end

  test "assigned inline prefixes make body-only results while whole reads remain unchanged",
       ctx do
    content = "Use canary deployment. Keep rollback instructions whole."
    record = skill(%{name: "guide", description: "Operations", system_prompt_fragment: content})
    assign(ctx.agent, [record])
    assert {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    [binding] = snapshot.bindings

    assert {:ok, %{content: ^content, truncated: false}} =
             SkillReader.search_body(snapshot, binding, 16_384, recheck: fn -> :ok end)

    view = body_view(snapshot, [%{position: 0, content: content}], 0)

    assert {:ok, %{results: [hit], truncated: false} = result} =
             SkillReader.search(snapshot, "canary", body_view: view)

    assert hit.record_id == record.id
    assert hit.locator == "synapsis://skills/#{record.id}"
    assert hit.source_authority == "synapsis"
    assert hit.artifact_digest == nil
    assert Map.get(result, :coverage) == nil
    assert {:ok, page} = SkillReader.read(snapshot, hit.locator)
    assert page.content == content
    assert page.document_digest == digest(content)
  end

  test "actual small digest-pinned local canonical body stays source-qualified beside its duplicate name",
       ctx do
    content = canonical("guide", "Use canary deployment. Keep rollback instructions whole.")
    path = Path.join([ctx.tmp_dir, "guide", "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    inline = skill(%{name: "guide", description: "Operations", system_prompt_fragment: "Canary"})

    local =
      skill(%{
        name: "guide",
        description: "Local operations",
        config_overrides: %{
          "source" => "local",
          "source_id" => "project",
          "skill_id" => "guide",
          "root" => ctx.tmp_dir,
          "artifact_digest" => digest(content)
        }
      })

    assign(ctx.agent, [inline, local])
    assert {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    [inline_binding, local_binding] = snapshot.bindings

    assert {:ok, %{content: "Canary", truncated: false}} =
             SkillReader.search_body(snapshot, inline_binding, 16_384, recheck: fn -> :ok end)

    assert {:ok, %{content: ^content, truncated: false}} =
             SkillReader.search_body(snapshot, local_binding, 16_384, recheck: fn -> :ok end)

    view =
      body_view(
        snapshot,
        [%{position: 0, content: "Canary"}, %{position: 1, content: content}],
        0
      )

    assert {:ok, %{results: hits, truncated: false}} =
             SkillReader.search(snapshot, "canary", body_view: view)

    assert Enum.map(hits, & &1.record_id) == [inline.id, local.id]

    assert Enum.map(hits, & &1.locator) == [
             "synapsis://skills/#{inline.id}",
             "local://project/guide"
           ]

    assert Enum.map(hits, & &1.source_authority) == ["synapsis", "local"]
    assert Enum.map(hits, & &1.artifact_digest) == [nil, digest(content)]
    assert {:ok, page} = SkillReader.read(snapshot, "local://project/guide")
    assert page.content == content
    assert page.artifact_digest == digest(content)
    assert page.document_digest == digest(content)
  end

  test "opaque assigned sources participate through metadata with honest body coverage", ctx do
    source_id = Ecto.UUID.generate()
    assert {:ok, _} = Store.put(:backplane, %{"id" => source_id, "enabled" => true})
    on_exit(fn -> Store.delete(:backplane, source_id) end)

    record =
      skill(%{
        name: "remote",
        description: "Canary operations",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "guide",
          "external_revision" => "rev-7",
          "artifact_digest" => "sha256:artifact"
        }
      })

    assign(ctx.agent, [record])
    assert {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    [binding] = snapshot.bindings

    assert {:metadata_only, _reason} =
             SkillReader.search_body(snapshot, binding, 16_384, recheck: fn -> :ok end)

    view = body_view(snapshot, [], 1)

    assert {:ok, %{results: [hit], coverage: coverage}} =
             SkillReader.search(snapshot, "canary", body_view: view)

    assert coverage == %{bodyIndexed: 0, metadataOnly: 1, truncatedBodies: 0}
    assert hit.record_id == record.id
    assert hit.source_authority == "backplane"
    assert hit.source_id == source_id
    assert hit.skill_id == "guide"
    assert hit.revision == "rev-7"
    assert hit.artifact_digest == "sha256:artifact"
  end

  defp body_view(snapshot, bodies, metadata_only) do
    %{
      snapshot: snapshot,
      index: SkillSearch.prepare_bodies(bodies),
      coverage: %{bodyIndexed: length(bodies), metadataOnly: metadata_only, truncatedBodies: 0}
    }
  end

  defp skill(attrs) do
    assert {:ok, record} = Skills.create(Map.merge(%{scope: "global"}, attrs))
    on_exit(fn -> Store.delete(:skill, record.id) end)
    record
  end

  defp assign(agent, records) do
    assert {:ok, _} = Skills.assign_skills(agent, Enum.map(records, & &1.id))
  end

  defp canonical(name, body),
    do: "---\nname: #{name}\ndescription: Local operations\n---\n#{body}\n"

  defp digest(content),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
end
