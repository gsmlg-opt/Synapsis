defmodule Synapsis.SkillSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.{AgentConfigs, SkillReader, SkillSearch, Skills}
  alias Synapsis.Config.Store

  @fixture Path.expand(
             "../../../synapsis_agent/test/fixtures/openclaw/488631c/skill-search-ranking.json",
             __DIR__
           )

  test "multiword metadata queries rank complementary terms regardless of word order" do
    entries = [
      %{name: "alpha", description: "Review repository reference", opaque: :first},
      %{name: "workflow", description: "Review repository changes", opaque: :second}
    ]

    assert SkillSearch.rank(entries, "changes repository") == Enum.reverse(entries)
    assert SkillSearch.rank(entries, "repository changes") == Enum.reverse(entries)
  end

  test "ordinary inflected words reach their metadata roots" do
    for {description, query} <- [
          {"Running tasks", "run"},
          {"Remind", "reminders"},
          {"policy", "policies"},
          {"cookie", "cookies"},
          {"Process logs", "processing"},
          {"Call notes", "called"}
        ] do
      entry = %{name: "guide", description: description, retained: {:query, query}}
      assert SkillSearch.rank([entry], query) == [entry]
    end
  end

  test "identifier parts, ordinary nonLatin text and contextual case folding match metadata" do
    for {entry, query} <- [
          {%{name: "HTTPServer42_reader", description: "Parse responses"}, "server reader 42"},
          {%{name: "知识整理", description: "团队知识 整理"}, "整理 团队知识"},
          {%{name: "greek-guide", description: "ΟΣ"}, "ος"},
          {%{name: "İSTANBUL", description: "Travel notes"}, "İstanbul"}
        ] do
      assert SkillSearch.rank([entry], query) == [entry]
    end
  end

  test "exact names take priority with case-sensitive then first folded selection and trimmed queries" do
    upper = %{name: "Review", description: "review review", marker: :upper}
    lower = %{name: "review", description: "general guide", marker: :lower}
    assert SkillSearch.rank([upper, lower], "review") == [lower, upper]

    first = %{name: "REVIEW", description: "general guide", marker: :first}
    assert SkillSearch.rank([first, upper], "reView") == [first, upper]
    assert SkillSearch.rank([upper, lower], " \tReview \n") == [upper, lower]
    punctuation = %{name: ".", description: "", marker: :punctuation}
    assert SkillSearch.rank([punctuation], ".") == [punctuation]
  end

  test "BM25 favors repeated matches and concise metadata while duplicate query terms keep their weight" do
    alpha = %{name: "alpha", description: "signal"}
    beta = %{name: "beta", description: "signal signal signal"}
    assert SkillSearch.rank([alpha, beta], "signal") == [beta, alpha]
    assert SkillSearch.rank([alpha, beta], "signal signal signal") == [beta, alpha]

    long = %{name: "alpha", description: "signal additional ordinary reference context"}
    short = %{name: "beta", description: "signal"}
    assert SkillSearch.rank([long, short], "signal") == [short, long]
  end

  test "score ties use UTF16 name order and retain equal-name input order and complete maps" do
    zeta = %{name: "zeta", description: "signal", locator: "source://zeta"}
    alpha = %{name: "alpha", description: "signal", locator: "source://alpha"}
    assert SkillSearch.rank([zeta, alpha], "signal") == [alpha, zeta]

    bmp = %{name: "\uE000", description: "catalog", source: {:kept, 1}}
    astral = %{name: "😀", description: "catalog", source: {:kept, 2}}
    assert SkillSearch.rank([bmp, astral], "catalog") == [astral, bmp]

    first = %{name: "same", description: "signal", locator: "source://first"}
    second = %{name: "same", description: "signal", locator: "source://second"}
    assert SkillSearch.rank([first, second], "signal") == [first, second]
  end

  test "all frozen ordinary source results agree without changing original metadata entries" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(fixture["observations"]) == 22

    for row <- fixture["observations"] do
      entries =
        Enum.map(row["entries"], fn entry ->
          %{
            name: entry["name"],
            description: entry["description"],
            location: entry["location"],
            marker: entry["marker"]
          }
        end)

      ranked = SkillSearch.rank(entries, row["query"])
      assert Enum.all?(ranked, &(&1 in entries)), row["id"]

      projected =
        Enum.map(ranked, fn entry ->
          %{
            "name" => entry.name,
            "description" => entry.description,
            "location" => entry.location
          }
        end)

      assert projected == row["result"]["skills"], row["id"]
    end
  end

  test "persisted assigned metadata search preserves locators, output shape, snapshots and inert reads" do
    {:ok, agent} =
      AgentConfigs.create(%{name: "skill-search-#{System.unique_integer([:positive])}"})

    on_exit(fn -> Store.delete(:agent, agent.id) end)

    skills =
      for {name, description, body} <- [
            {"alpha", "Review repository reference", "Reference instructions"},
            {"workflow", "Review repository changes", "Review the selected change carefully."}
          ] do
        {:ok, record} =
          Skills.create(%{
            scope: "global",
            name: name,
            description: description,
            system_prompt_fragment: body
          })

        on_exit(fn -> Store.delete(:skill, record.id) end)
        record
      end

    [weak, relevant] = skills
    assert {:ok, _} = Skills.assign_skills(agent, Enum.map(skills, & &1.id))
    assert {:ok, snapshot} = SkillReader.snapshot(agent.id)

    assert {:ok, %{results: results, truncated: false}} =
             SkillReader.search(snapshot, "changes repository")

    assert Enum.map(results, & &1.record_id) == [relevant.id, weak.id]

    for {result, record} <- Enum.zip(results, [relevant, weak]) do
      assert result == %{
               record_id: record.id,
               source_authority: "synapsis",
               source_id: "synapsis",
               skill_id: record.id,
               revision: nil,
               artifact_digest: nil,
               name: record.name,
               description: record.description,
               locator: "synapsis://skills/#{record.id}"
             }
    end

    assert {:ok, %{results: ^results, truncated: false}} =
             SkillReader.search(snapshot, "repository changes")

    assert {:ok, %{results: [best], truncated: true}} =
             SkillReader.search(snapshot, "changes repository", limit: 1)

    assert best == hd(results)
    assert {:ok, ^snapshot} = SkillReader.snapshot(agent.id)
    assert {:ok, page} = SkillReader.read(snapshot, hd(results).locator)
    assert page.content == relevant.system_prompt_fragment
    assert page.citation == hd(results).locator
    assert page.record_id == relevant.id
    assert page.source_authority == "synapsis"
    assert page.revision == nil
    assert page.artifact_digest == nil

    assert page.document_digest ==
             "sha256:" <> Base.encode16(:crypto.hash(:sha256, page.content), case: :lower)
  end
end
