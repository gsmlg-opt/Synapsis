defmodule Synapsis.SkillReaderTest do
  use ExUnit.Case, async: false

  alias Synapsis.{AgentConfigs, SkillReader, Skills}
  alias Synapsis.Config.Store

  @moduletag :tmp_dir

  setup do
    {:ok, agent} =
      AgentConfigs.create(%{name: "native-skills-#{System.unique_integer([:positive])}"})

    on_exit(fn -> Store.delete(:agent, agent.id) end)
    %{agent: agent}
  end

  test "metadata search preserves persisted UUIDs and distinct source-qualified duplicate names",
       ctx do
    first =
      skill(%{
        name: "review",
        description: "Inspect changes",
        system_prompt_fragment: "SECRET BODY"
      })

    second =
      skill(%{
        name: "review",
        description: "Inspect changes",
        config_overrides: %{
          "source" => "local",
          "source_id" => "project",
          "skill_id" => "review",
          "root" => ctx.tmp_dir
        }
      })

    assign(ctx.agent, [first.id, second.id])

    assert {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    assert {:ok, %{results: results, truncated: false}} = SkillReader.search(snapshot, "inspect")
    assert Enum.sort(Enum.map(results, & &1.record_id)) == Enum.sort([first.id, second.id])
    assert length(Enum.uniq(Enum.map(results, & &1.locator))) == 2
    encoded = Jason.encode!(results)
    refute encoded =~ "SECRET BODY"
    refute encoded =~ ctx.tmp_dir
    refute encoded =~ "loader"
    refute encoded =~ "config_overrides"
  end

  test "read returns inert legacy and canonical text with honest source identity", ctx do
    legacy =
      skill(%{
        name: "legacy",
        system_prompt_fragment: "Do not execute $(touch /tmp/native-skill-proof)"
      })

    canonical =
      skill(%{
        name: "canonical",
        system_prompt_fragment: canonical("canonical", "Read-only instructions")
      })

    assign(ctx.agent, [legacy.id, canonical.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)

    for record <- [legacy, canonical] do
      locator = "synapsis://skills/#{record.id}"
      assert {:ok, page} = SkillReader.read(snapshot, locator)
      assert page.record_id == record.id
      assert page.source_authority == "synapsis"
      refute Map.has_key?(page, :authority)
      assert page.source_id == "synapsis"
      assert page.content == record.system_prompt_fragment
      assert page.citation == locator
      assert page.revision == nil
      assert page.artifact_digest == nil

      assert page.document_digest ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, page.content), case: :lower)
    end
  end

  test "assignment changes, disablement, content changes and agent disablement invalidate frozen reads",
       ctx do
    record = skill(%{name: "frozen", system_prompt_fragment: "initial"})
    assign(ctx.agent, [record.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    locator = "synapsis://skills/#{record.id}"

    assign(ctx.agent, [])
    assert {:error, :stale_snapshot} = SkillReader.read(snapshot, locator)
    assign(ctx.agent, [record.id])
    {:ok, _} = Skills.update(record, %{enabled: false})
    assert {:error, :stale_snapshot} = SkillReader.search(snapshot, "frozen")
    {:ok, _} = Skills.update(record, %{enabled: true, system_prompt_fragment: "changed"})
    assert {:error, :stale_snapshot} = SkillReader.read(snapshot, locator)
    {:ok, fresh} = SkillReader.snapshot(ctx.agent.id)
    {:ok, _} = AgentConfigs.update(ctx.agent, %{enabled: false})
    assert {:error, :stale_snapshot} = SkillReader.read(fresh, locator)
  end

  test "automatic eligibility excludes manual-only entries without changing explicit legacy behavior",
       ctx do
    records = [
      skill(%{
        name: "manual",
        system_prompt_fragment:
          "---\nname: manual\ndescription: Manual only\ndisable-model-invocation: true\n---\nbody\n"
      }),
      skill(%{name: "hidden", config_overrides: %{"prompt_visible" => false}}),
      skill(%{name: "disabled", enabled: false})
    ]

    assign(ctx.agent, Enum.map(records, & &1.id))
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    assert {:ok, %{results: []}} = SkillReader.search(snapshot, "manual")

    for record <- records do
      assert {:error, :not_found} = SkillReader.read(snapshot, "synapsis://skills/#{record.id}")
    end
  end

  test "local canonical files use trusted root and reject links, oversized or changed pinned contents",
       ctx do
    path = Path.join([ctx.tmp_dir, "review", "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    content = canonical("review", "Local instructions")
    File.write!(path, content)
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

    record =
      skill(%{
        name: "review",
        config_overrides: %{
          "source" => "local",
          "source_id" => "project",
          "skill_id" => "review",
          "root" => ctx.tmp_dir,
          "artifact_digest" => digest
        }
      })

    assign(ctx.agent, [record.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    assert {:ok, %{content: ^content}} = SkillReader.read(snapshot, "local://project/review")
    File.write!(path, canonical("review", "Changed"))
    assert {:error, :digest_mismatch} = SkillReader.read(snapshot, "local://project/review")
    File.write!(path, String.duplicate("x", 65_537))
    assert {:error, :file_limit} = SkillReader.read(snapshot, "local://project/review")
    File.rm!(path)
    outside = Path.join(ctx.tmp_dir, "outside.md")
    File.write!(outside, content)
    File.ln_s!(outside, path)
    assert {:error, :unsafe_path} = SkillReader.read(snapshot, "local://project/review")
  end

  test "strict inputs and bounded candidate selection reject limits without silent truncation",
       ctx do
    record = skill(%{name: "bounded", system_prompt_fragment: "small"})
    assign(ctx.agent, [record.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)

    for {query, opts} <- [
          {"", []},
          {<<255>>, []},
          {"x", [limit: 0]},
          {"x", [limit: 21]},
          {"x", [limit: 1.0]},
          {"x", [root: "/"]}
        ] do
      assert {:error, :invalid_input} = SkillReader.search(snapshot, query, opts)
    end

    assert {:error, :not_found} = SkillReader.read(snapshot, "synapsis://skills/unassigned")
    assert {:error, :invalid_input} = SkillReader.read(snapshot, "")
    assign(ctx.agent, Enum.map(1..129, fn _ -> Ecto.UUID.generate() end))
    assert {:error, :candidate_limit} = SkillReader.snapshot(ctx.agent.id)
  end

  test "remote reads preserve exact source revision and digest and reject live source changes before loading",
       ctx do
    source_id = Ecto.UUID.generate()

    source = %{
      "id" => source_id,
      "enabled" => true,
      "endpoint" => "http://127.0.0.1:9",
      "metadata" => %{}
    }

    {:ok, _} = Store.put(:backplane, source)
    on_exit(fn -> Store.delete(:backplane, source_id) end)

    record =
      skill(%{
        name: "remote",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "review",
          "external_revision" => "rev-7",
          "artifact_digest" => "sha256:artifact"
        }
      })

    assign(ctx.agent, [record.id])
    previous = Application.get_env(:synapsis_core, :skill_loader)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :skill_loader, previous),
        else: Application.delete_env(:synapsis_core, :skill_loader)
    end)

    owner = self()

    Application.put_env(:synapsis_core, :skill_loader, fn entry, context ->
      send(owner, {:loaded, entry, context.agent_id})
      {:ok, canonical("remote", "Remote inert body")}
    end)

    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    {:ok, %{results: [hit]}} = SkillReader.search(snapshot, "remote")
    refute_receive {:loaded, _, _}
    assert hit.record_id == record.id
    assert hit.skill_id == "review"
    assert hit.revision == "rev-7"
    assert hit.artifact_digest == "sha256:artifact"

    assert {:ok, %{revision: "rev-7", artifact_digest: "sha256:artifact"}} =
             SkillReader.read(snapshot, hit.locator)

    assert_receive {:loaded, %{source_id: ^source_id, skill_id: "review", revision: "rev-7"},
                    agent_id}

    assert agent_id == ctx.agent.id

    for changed <- [
          Map.put(source, "enabled", false),
          Map.put(source, "endpoint", "http://127.0.0.1:10"),
          Map.put(source, "metadata", %{"runtime_blocked_surfaces" => ["skills"]})
        ] do
      {:ok, _} = Store.put(:backplane, changed)
      assert {:error, :stale_snapshot} = SkillReader.read(snapshot, hit.locator)
      refute_receive {:loaded, _, _}
    end

    {:ok, _} = Store.put(:backplane, source)

    {:ok, _} =
      Skills.update(record, %{
        config_overrides: Map.put(record.config_overrides, "external_revision", "rev-8")
      })

    assert {:error, :stale_snapshot} = SkillReader.read(snapshot, hit.locator)
    refute_receive {:loaded, _, _}
  end

  test "remote loader errors are sanitized and malformed documents fail instead of returning empty success",
       ctx do
    source_id = Ecto.UUID.generate()
    {:ok, _} = Store.put(:backplane, %{"id" => source_id, "enabled" => true})
    on_exit(fn -> Store.delete(:backplane, source_id) end)

    record =
      skill(%{
        name: "remote",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "review",
          "external_revision" => "rev-7"
        }
      })

    assign(ctx.agent, [record.id])
    previous = Application.get_env(:synapsis_core, :skill_loader)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :skill_loader, previous),
        else: Application.delete_env(:synapsis_core, :skill_loader)
    end)

    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    {:ok, %{results: [hit]}} = SkillReader.search(snapshot, "remote")

    for result <- [
          {:error, "Bearer secret credential at /private/root"},
          {:ok, "not a canonical skill"}
        ] do
      Application.put_env(:synapsis_core, :skill_loader, fn _, _ -> result end)
      assert {:error, reason} = SkillReader.read(snapshot, hit.locator)
      assert reason in [:unavailable, :invalid_document]
      refute inspect(reason) =~ "secret"
    end
  end

  test "absolute deadline and owner loss cooperatively unwind the remote loader", ctx do
    source_id = Ecto.UUID.generate()
    {:ok, _} = Store.put(:backplane, %{"id" => source_id, "enabled" => true})
    on_exit(fn -> Store.delete(:backplane, source_id) end)

    record =
      skill(%{
        name: "remote-cancel",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "review",
          "external_revision" => "rev-7"
        }
      })

    assign(ctx.agent, [record.id])
    previous = Application.get_env(:synapsis_core, :skill_loader)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :skill_loader, previous),
        else: Application.delete_env(:synapsis_core, :skill_loader)
    end)

    owner = self()

    Application.put_env(:synapsis_core, :skill_loader, fn _, context ->
      send(owner, {:loader_started, self(), context.deadline})

      try do
        await_cancel(context.cancelled?)
        {:error, :cancelled}
      after
        send(owner, {:loader_cleaned, self()})
      end
    end)

    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    {:ok, %{results: [hit]}} = SkillReader.search(snapshot, "remote-cancel")
    deadline = System.monotonic_time(:millisecond) + 100
    assert {:error, :timeout} = SkillReader.read(snapshot, hit.locator, deadline: deadline)
    assert_receive {:loader_started, worker, ^deadline}
    monitor = Process.monitor(worker)
    assert_receive {:loader_cleaned, ^worker}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000

    caller = spawn(fn -> SkillReader.read(snapshot, hit.locator) end)
    assert_receive {:loader_started, owner_worker, _}, 1_000
    owner_monitor = Process.monitor(owner_worker)
    Process.exit(caller, :kill)
    assert_receive {:loader_cleaned, ^owner_worker}, 1_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_worker, _}, 1_000
  end

  test "explicit reads keep manual and hidden assignments separate from automatic eligibility",
       ctx do
    manual =
      skill(%{
        name: "manual-explicit",
        system_prompt_fragment:
          "---\nname: manual-explicit\ndescription: Manual only\ndisable-model-invocation: true\nuser-invocable: false\n---\nInert body\n"
      })

    hidden =
      skill(%{
        name: "hidden-explicit",
        config_overrides: %{"prompt_visible" => false},
        system_prompt_fragment: "Hidden inert body"
      })

    disabled = skill(%{name: "disabled-explicit", enabled: false})
    foreign = skill(%{name: "foreign-explicit"})
    assign(ctx.agent, [manual.id, hidden.id, disabled.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)

    for record <- [manual, hidden] do
      locator = "synapsis://skills/#{record.id}"
      assert {:error, :not_found} = SkillReader.read(snapshot, locator)
      assert {:ok, %{results: []}} = SkillReader.search(snapshot, record.name)
      assert {:ok, binding} = SkillReader.select_explicit(snapshot, %{"locator" => locator})
      assert binding.record_id == record.id

      assert {:ok, page} = SkillReader.read_explicit(snapshot, %{"locator" => locator})
      assert page.source_authority == "synapsis"
      assert page.content == record.system_prompt_fragment
      assert page.record_id == record.id
      assert page.citation == locator
      assert page.artifact_digest == nil
    end

    for record <- [disabled, foreign] do
      assert {:error, :not_found} =
               SkillReader.read_explicit(snapshot, %{
                 "locator" => "synapsis://skills/#{record.id}"
               })
    end
  end

  test "explicit selection preserves unique-name compatibility and locator precedence", ctx do
    first = skill(%{name: "duplicate-explicit", system_prompt_fragment: "First"})
    second = skill(%{name: "duplicate-explicit", system_prompt_fragment: "Second"})
    unique = skill(%{name: "unique-explicit", system_prompt_fragment: "Unique"})
    assign(ctx.agent, [first.id, second.id, unique.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)

    assert {:ok, %{content: "Unique"}} =
             SkillReader.read_explicit(snapshot, %{"name" => unique.name})

    assert {:ok, %{content: "Unique"}} =
             SkillReader.read_explicit(snapshot, %{"locator" => "", "name" => unique.name})

    assert {:error, :ambiguous} =
             SkillReader.read_explicit(snapshot, %{"name" => first.name})

    assert {:ok, %{content: "First"}} =
             SkillReader.read_explicit(snapshot, %{
               "locator" => "synapsis://skills/#{first.id}",
               "name" => unique.name
             })

    assert {:error, :not_found} =
             SkillReader.read_explicit(snapshot, %{
               "locator" => "synapsis://skills/unassigned",
               "name" => unique.name
             })

    for input <- [
          %{},
          %{"name" => ""},
          %{"locator" => <<255>>},
          %{"name" => unique.name, "root" => "/"},
          %{"locator" => String.duplicate("x", 4097)},
          %{"name" => 12}
        ] do
      assert {:error, :invalid_input} = SkillReader.read_explicit(snapshot, input)
    end

    assert {:error, :invalid_input} =
             SkillReader.read_explicit(snapshot, %{"name" => unique.name}, root: "/")
  end

  test "duplicate exact local locators retain first-assigned selection while names stay ambiguous",
       ctx do
    records =
      for {directory, body} <- [
            {"first-source", "First source body"},
            {"second-source", "Second source body"}
          ] do
        root = Path.join(ctx.tmp_dir, directory)
        path = Path.join([root, "duplicate-local", "SKILL.md"])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, canonical("duplicate-local", body))

        skill(%{
          name: "duplicate-local",
          config_overrides: %{
            "source" => "local",
            "source_id" => "project",
            "skill_id" => "duplicate-local",
            "root" => root
          }
        })
      end

    [first, second] = records
    assert first.id != second.id
    locator = "local://project/duplicate-local"

    for {assigned, expected_body} <- [
          {[second, first], "Second source body"},
          {[first, second], "First source body"}
        ] do
      assign(ctx.agent, Enum.map(assigned, & &1.id))
      {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
      assert Enum.map(snapshot.bindings, & &1.entry.locator) == [locator, locator]
      [expected | _] = assigned

      assert {:ok, binding} =
               SkillReader.select_explicit(snapshot, %{"locator" => locator})

      assert binding.record_id == expected.id

      assert {:ok, page} =
               SkillReader.read_explicit(snapshot, %{
                 "locator" => locator,
                 "name" => "unassigned-name"
               })

      assert page.record_id == expected.id
      assert page.content =~ expected_body
      assert page.citation == locator

      assert {:error, :ambiguous} =
               SkillReader.read_explicit(snapshot, %{"name" => "duplicate-local"})

      assert {:error, :not_found} =
               SkillReader.read_explicit(snapshot, %{
                 "locator" => "local://project/unassigned",
                 "name" => "duplicate-local"
               })
    end
  end

  test "explicit frozen reads reject reassignment, record changes and disabled agents", ctx do
    record = skill(%{name: "explicit-frozen", system_prompt_fragment: "Original"})
    assign(ctx.agent, [record.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    input = %{"locator" => "synapsis://skills/#{record.id}"}
    assign(ctx.agent, [])
    assert {:error, :stale_snapshot} = SkillReader.read_explicit(snapshot, input)
    assign(ctx.agent, [record.id])
    {:ok, _} = Skills.update(record, %{system_prompt_fragment: "Changed"})
    assert {:error, :stale_snapshot} = SkillReader.read_explicit(snapshot, input)
    {:ok, fresh} = SkillReader.snapshot(ctx.agent.id)
    {:ok, _} = AgentConfigs.update(ctx.agent, %{enabled: false})
    assert {:error, :stale_snapshot} = SkillReader.read_explicit(fresh, input)
  end

  test "explicit local manual files retain digest and path guards", ctx do
    content =
      "---\nname: local-manual\ndescription: Local manual\ndisable-model-invocation: true\n---\nBody\n"

    path = Path.join([ctx.tmp_dir, "local-manual", "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

    record =
      skill(%{
        name: "local-manual",
        config_overrides: %{
          "source" => "local",
          "source_id" => "project",
          "skill_id" => "local-manual",
          "root" => ctx.tmp_dir,
          "artifact_digest" => digest
        }
      })

    assign(ctx.agent, [record.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    input = %{"locator" => "local://project/local-manual"}

    assert {:ok, %{content: ^content, artifact_digest: ^digest}} =
             SkillReader.read_explicit(snapshot, input)

    assert {:error, :invalid_document} = SkillReader.read(snapshot, input["locator"])
    File.write!(path, content <> "Changed")
    assert {:error, :digest_mismatch} = SkillReader.read_explicit(snapshot, input)
    File.rm!(path)
    outside = Path.join(ctx.tmp_dir, "explicit-outside.md")
    File.write!(outside, content)
    File.ln_s!(outside, path)
    assert {:error, :unsafe_path} = SkillReader.read_explicit(snapshot, input)
  end

  test "explicit remote reads preserve source pins, live credentials and fixed failures", ctx do
    {:ok, credential} =
      Synapsis.Credentials.create(%{name: "explicit-credential", key: "first-secret"})

    provider_id = Ecto.UUID.generate()
    source_id = Ecto.UUID.generate()

    {:ok, _} =
      Store.put(:provider, %{
        "id" => provider_id,
        "enabled" => true,
        "credential_id" => credential.id,
        "base_url" => "http://127.0.0.1:9/v1"
      })

    source = %{
      "id" => source_id,
      "enabled" => true,
      "provider_id" => provider_id,
      "endpoint" => "http://127.0.0.1:9"
    }

    {:ok, _} = Store.put(:backplane, source)
    previous = Application.get_env(:synapsis_core, :skill_loader)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:synapsis_core, :skill_loader, previous),
        else: Application.delete_env(:synapsis_core, :skill_loader)

      Store.delete(:backplane, source_id)
      Store.delete(:provider, provider_id)
      Synapsis.Credentials.delete(credential.id)
    end)

    record =
      skill(%{
        name: "explicit-remote",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "manual",
          "external_revision" => "rev-7",
          "artifact_digest" => "sha256:artifact",
          "prompt_visible" => false
        }
      })

    assign(ctx.agent, [record.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    [binding] = snapshot.bindings
    input = %{"locator" => binding.entry.locator}
    owner = self()

    content =
      "---\nname: manual\ndescription: Remote manual\ndisable-model-invocation: true\n---\nBody\n"

    Application.put_env(:synapsis_core, :skill_loader, fn entry, context ->
      assert {:ok, secret} = Synapsis.Credentials.resolve(credential.id)
      send(owner, {:explicit_loaded, entry, context.agent_id, secret})
      {:ok, content}
    end)

    assert {:ok, %{revision: "rev-7", artifact_digest: "sha256:artifact", content: ^content}} =
             SkillReader.read_explicit(snapshot, input)

    assert_receive {:explicit_loaded,
                    %{
                      source_id: ^source_id,
                      skill_id: "manual",
                      revision: "rev-7",
                      artifact_digest: "sha256:artifact"
                    }, agent_id, "first-secret"}

    assert agent_id == ctx.agent.id
    assert {:ok, _} = Synapsis.Credentials.update(credential, %{key: "second-secret"})
    assert {:ok, _} = SkillReader.read_explicit(snapshot, input)
    assert_receive {:explicit_loaded, _, ^agent_id, "second-secret"}

    for result <- [{:error, "Bearer secret at /private/root"}, {:ok, "malformed"}] do
      Application.put_env(:synapsis_core, :skill_loader, fn _, _ -> result end)
      assert {:error, reason} = SkillReader.read_explicit(snapshot, input)
      assert reason in [:unavailable, :invalid_document]
    end

    Application.put_env(:synapsis_core, :skill_loader, fn _, _ ->
      send(owner, :unexpected_explicit_load)
      {:ok, content}
    end)

    for changed <- [
          Map.put(source, "enabled", false),
          Map.put(source, "endpoint", "http://127.0.0.1:10")
        ] do
      {:ok, _} = Store.put(:backplane, changed)
      assert {:error, :stale_snapshot} = SkillReader.read_explicit(snapshot, input)
      refute_receive :unexpected_explicit_load
    end
  end

  test "explicit reads share absolute deadline and owner-loss cancellation", ctx do
    source_id = Ecto.UUID.generate()
    {:ok, _} = Store.put(:backplane, %{"id" => source_id, "enabled" => true})
    previous = Application.get_env(:synapsis_core, :skill_loader)

    on_exit(fn ->
      Store.delete(:backplane, source_id)

      if previous,
        do: Application.put_env(:synapsis_core, :skill_loader, previous),
        else: Application.delete_env(:synapsis_core, :skill_loader)
    end)

    record =
      skill(%{
        name: "explicit-cancel",
        config_overrides: %{
          "source" => "backplane",
          "managed_by" => "backplane",
          "backplane_source_id" => source_id,
          "external_id" => "manual",
          "external_revision" => "rev-7",
          "prompt_visible" => false
        }
      })

    assign(ctx.agent, [record.id])
    {:ok, snapshot} = SkillReader.snapshot(ctx.agent.id)
    input = %{"locator" => hd(snapshot.bindings).entry.locator}
    owner = self()

    Application.put_env(:synapsis_core, :skill_loader, fn _, context ->
      send(owner, {:explicit_started, self(), context.deadline})

      try do
        await_cancel(context.cancelled?)
        {:error, :cancelled}
      after
        send(owner, {:explicit_cleaned, self()})
      end
    end)

    deadline = System.monotonic_time(:millisecond) + 100
    assert {:error, :timeout} = SkillReader.read_explicit(snapshot, input, deadline: deadline)
    assert_receive {:explicit_started, worker, ^deadline}
    monitor = Process.monitor(worker)
    assert_receive {:explicit_cleaned, ^worker}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    caller = spawn(fn -> SkillReader.read_explicit(snapshot, input) end)
    assert_receive {:explicit_started, owner_worker, _}, 1_000
    owner_monitor = Process.monitor(owner_worker)
    Process.exit(caller, :kill)
    assert_receive {:explicit_cleaned, ^owner_worker}, 1_000
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner_worker, _}, 1_000
  end

  defp await_cancel(cancelled?) do
    if cancelled?.() do
      :ok
    else
      receive do
      after
        5 -> await_cancel(cancelled?)
      end
    end
  end

  defp skill(attrs) do
    {:ok, record} =
      Skills.create(
        Map.merge(%{scope: "global", name: "skill-#{System.unique_integer([:positive])}"}, attrs)
      )

    on_exit(fn -> Store.delete(:skill, record.id) end)
    record
  end

  defp assign(agent, ids), do: Skills.assign_skills(agent, ids)

  defp canonical(name, body),
    do: "---\nname: #{name}\ndescription: Review code carefully\n---\n#{body}\n"
end
