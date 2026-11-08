defmodule Synapsis.Agent.Tools.FreshnessTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolCatalog}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof
  alias Synapsis.Agent.Tools.{Approval, Freshness, PermissionSnapshot}
  alias Synapsis.{Credentials, Providers, Session.Store}
  alias Synapsis.Config.Store, as: ConfigStore

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.owner, :freshness_effect)
      {:ok, %{content: "executed"}}
    end
  end

  # Isolated host composition: production Policy/Approval remain unchanged.
  defmodule Hooks do
    def prepare_tool(invocation, context) do
      with {:ok, current} <- context.capture.(),
           :ok <- Synapsis.Agent.Tools.Freshness.check(context.expected, current) do
        Synapsis.Agent.Tools.Policy.prepare_tool(invocation, context)
      else
        {:error, reason} -> {:deny, reason}
      end
    end
  end

  setup do
    Store.ensure_started()
    session = Ecto.UUID.generate()
    raw = permission(session)
    :ok = Store.put_value(session, "permission", raw)
    on_exit(fn -> Store.delete_session(session) end)
    %{session: session, raw: raw, deps: %{provider_ids: [], credential_ids: []}}
  end

  test "default readers capture explicit finite dependencies without auth material", ctx do
    {provider, credential} = provider!()
    deps = %{provider_ids: [provider.id], credential_ids: [credential.id]}

    assert {:ok, evidence} = Freshness.capture(ctx.session, deps)
    assert evidence.session_id == ctx.session
    assert evidence.permission_fingerprint == PermissionSnapshot.fingerprint(ctx.raw)
    assert Map.keys(evidence.providers) == [provider.id]
    assert Map.keys(evidence.credentials) == [credential.id]
    assert :ok = Freshness.check(evidence, evidence)
    assert {:ok, json} = Jason.encode(evidence)
    refute json =~ "fixture-secret"
    refute json =~ "base_url"
    refute json =~ "api_key"

    assert {:ok, empty} = Freshness.capture(ctx.session, ctx.deps)
    assert empty.providers == %{}
    assert empty.credentials == %{}

    other = %Synapsis.SessionPermission{session_id: ctx.session, tool_contract_version: 1}
    :ok = Store.put_value(ctx.session, "permission", other)
    assert {:ok, struct_evidence} = Freshness.capture(ctx.session, ctx.deps)
    assert struct_evidence.permission_fingerprint == PermissionSnapshot.fingerprint(other)
  end

  @tag :contract_version
  test "legacy permissions fail before provider and credential readers even with no overrides",
       ctx do
    owner = self()

    for version <- [0, nil, "1", 2, 1.0] do
      raw = %{ctx.raw | tool_contract_version: version}

      readers = %{
        permission: fn _ -> {:ok, raw} end,
        provider: fn _ ->
          send(owner, :unexpected_version_provider_read)
          {:error, :unavailable}
        end,
        credential: fn _ ->
          send(owner, :unexpected_version_credential_read)
          {:error, :unavailable}
        end
      }

      assert {:error, :invalid_permission_snapshot} =
               Freshness.capture(
                 ctx.session,
                 %{provider_ids: ["provider"], credential_ids: ["credential"]},
                 readers
               )

      refute_received :unexpected_version_provider_read
      refute_received :unexpected_version_credential_read
    end
  end

  test "canonical evidence ignores dependency order and rejects duplicate or implicit dependencies",
       ctx do
    readers = readers(ctx.raw)
    deps = %{provider_ids: ["b", "a"], credential_ids: ["d", "c"]}
    assert {:ok, first} = Freshness.capture(ctx.session, deps, readers)

    assert {:ok, second} =
             Freshness.capture(
               ctx.session,
               %{provider_ids: ["a", "b"], credential_ids: ["c", "d"]},
               readers
             )

    assert first === second
    assert :ok = Freshness.check(first, second)

    for deps <- [
          %{},
          %{provider_ids: []},
          %{provider_ids: [], credential_ids: [], extra: []},
          %{provider_ids: ["a", "a"], credential_ids: []},
          %{provider_ids: [" "], credential_ids: []},
          %{provider_ids: [], credential_ids: [nil]},
          %{"provider_ids" => [], "credential_ids" => []}
        ] do
      assert {:error, :invalid_dependencies} = Freshness.capture(ctx.session, deps, readers)
    end

    assert {:error, :invalid_session} = Freshness.capture(" ", ctx.deps, readers)
    assert {:error, :invalid_readers} = Freshness.capture(ctx.session, ctx.deps, %{})
  end

  test "missing, malformed and mismatched persisted permissions fail closed", ctx do
    assert {:error, :permission_unavailable} = Freshness.capture(Ecto.UUID.generate(), ctx.deps)

    for raw <- [
          nil,
          %{},
          %{ctx.raw | mode: :unknown},
          %{ctx.raw | tool_overrides: %{"read" => :unknown}}
        ] do
      :ok = Store.put_value(ctx.session, "permission", raw)
      assert {:error, :invalid_permission_snapshot} = Freshness.capture(ctx.session, ctx.deps)
    end

    :ok = Store.put_value(ctx.session, "permission", %{ctx.raw | session_id: "another"})
    assert {:error, :session_mismatch} = Freshness.capture(ctx.session, ctx.deps)
  end

  test "reader errors, exceptions, throws and exits are sanitized", ctx do
    base = readers(ctx.raw)

    for failing <- [
          fn _ -> {:error, "fixture-secret"} end,
          fn _ -> raise "fixture-secret" end,
          fn _ -> throw("fixture-secret") end,
          fn _ -> exit("fixture-secret") end,
          fn _ -> :malformed end
        ],
        {kind, deps} <- [
          permission: ctx.deps,
          provider: %{ctx.deps | provider_ids: ["p"]},
          credential: %{ctx.deps | credential_ids: ["c"]}
        ] do
      assert {:error, reason} =
               Freshness.capture(ctx.session, deps, Map.put(base, kind, failing))

      refute inspect(reason) =~ "fixture-secret"
    end

    bad_provider =
      Map.put(base, :provider, fn _ -> {:ok, {"wrong", nil, true, nil, nil, nil}} end)

    assert {:error, _} =
             Freshness.capture(ctx.session, %{ctx.deps | provider_ids: ["p"]}, bad_provider)

    bad_version = Map.put(base, :credential, fn _ -> {:ok, "plaintext-secret"} end)

    assert {:error, _} =
             Freshness.capture(ctx.session, %{ctx.deps | credential_ids: ["c"]}, bad_version)
  end

  test "actual permissions, credential rotation and provider disable invalidate evidence", ctx do
    {provider, credential} = provider!()
    deps = %{provider_ids: [provider.id], credential_ids: [credential.id]}
    assert {:ok, original} = Freshness.capture(ctx.session, deps)

    :ok = Store.put_value(ctx.session, "permission", %{ctx.raw | allow_read: :deny})
    assert {:ok, changed_permission} = Freshness.capture(ctx.session, deps)
    assert {:error, :freshness_changed} = Freshness.check(original, changed_permission)
    :ok = Store.put_value(ctx.session, "permission", ctx.raw)

    assert {:ok, _} = Credentials.update(credential.id, %{key: "rotated-fixture-secret"})
    assert {:ok, rotated} = Freshness.capture(ctx.session, deps)
    refute rotated.providers == original.providers
    refute rotated.credentials == original.credentials
    assert {:error, :freshness_changed} = Freshness.check(original, rotated)

    assert {:ok, _} = Providers.update(provider.id, %{enabled: false})
    assert {:error, {:provider_unavailable, id}} = Freshness.capture(ctx.session, deps)
    assert id == provider.id
  end

  test "credential version success alone cannot establish availability", ctx do
    {provider, credential} = provider!()

    assert {:ok, _} =
             ConfigStore.merge_existing(:credential, credential.id, %{"key_encrypted" => "broken"})

    assert {:ok, _} = Credentials.version(credential.id)

    assert {:error, {:credential_unavailable, id}} =
             Freshness.capture(ctx.session, %{ctx.deps | credential_ids: [credential.id]})

    assert id == credential.id

    assert {:error, {:provider_unavailable, _}} =
             Freshness.capture(ctx.session, %{ctx.deps | provider_ids: [provider.id]})

    assert {:error, {:provider_unavailable, _}} =
             Freshness.capture(ctx.session, %{ctx.deps | provider_ids: [Ecto.UUID.generate()]})

    assert {:error, {:credential_unavailable, _}} =
             Freshness.capture(ctx.session, %{ctx.deps | credential_ids: [Ecto.UUID.generate()]})
  end

  test "default provider reader rejects malformed persisted fields rather than normalized defaults",
       ctx do
    id = Ecto.UUID.generate()
    on_exit(fn -> ConfigStore.delete(:provider, id) end)

    raw = %{
      "id" => id,
      "name" => "malformed-freshness",
      "type" => "openai",
      "enabled" => true,
      "config" => %{}
    }

    for change <- [
          %{"type" => "unsupported"},
          %{"enabled" => "broken"},
          %{"base_url" => "invalid-url"}
        ] do
      assert {:ok, _} = ConfigStore.put(:provider, Map.merge(raw, change))

      assert {:error, {:provider_unavailable, ^id}} =
               Freshness.capture(ctx.session, %{ctx.deps | provider_ids: [id]})
    end
  end

  test "provider availability rechecks current managed-source blocking even with unchanged generation",
       ctx do
    {provider, _} = provider!()
    source_id = Ecto.UUID.generate()
    on_exit(fn -> ConfigStore.delete(:backplane, source_id) end)

    assert {:ok, _} =
             ConfigStore.put(:backplane, %{
               "id" => source_id,
               "enabled" => true,
               "metadata" => %{}
             })

    assert {:ok, provider} =
             Providers.update(provider.id, %{config: %{"backplane_source_id" => source_id}})

    generation = Providers.authentication_generation(provider)
    deps = %{ctx.deps | provider_ids: [provider.id]}
    assert {:ok, _} = Freshness.capture(ctx.session, deps)

    assert {:ok, _} =
             ConfigStore.merge_existing(:backplane, source_id, %{
               "metadata" => %{"runtime_blocked_surfaces" => ["models"]}
             })

    assert {:ok, current} = Providers.get(provider.id)
    assert Providers.authentication_generation(current) === generation
    assert {:error, {:provider_unavailable, _}} = Freshness.capture(ctx.session, deps)
  end

  test "check refuses malformed evidence even when both arguments are identical", ctx do
    assert {:ok, evidence} = Freshness.capture(ctx.session, ctx.deps)

    for invalid <- [
          nil,
          %{},
          Map.put(evidence, :secret, "hidden"),
          Map.put(evidence, :fingerprint, "stale"),
          put_in(evidence, [:providers, "p"], "plaintext")
        ] do
      assert {:error, :invalid_evidence} = Freshness.check(invalid, invalid)
    end
  end

  test "native pre-policy freshness check denies stale permission before intent or effect", ctx do
    capture = fn -> Freshness.capture(ctx.session, ctx.deps) end
    assert {:ok, expected} = capture.()
    :ok = Store.put_value(ctx.session, "permission", %{ctx.raw | allow_read: :deny})
    {_, options} = conversation(ctx, expected, capture, :allow)
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
    refute_receive :freshness_effect, 0
    assert tool_intents(options) == []
  end

  test "native Approval.refresh rechecks rotated credential after human consent", ctx do
    {provider, credential} = provider!()
    deps = %{provider_ids: [provider.id], credential_ids: [credential.id]}
    capture = fn -> Freshness.capture(ctx.session, deps) end
    assert {:ok, expected} = capture.()
    {pid, options} = conversation(ctx, expected, capture, :ask)

    assert_receive {:agent_runtime, _,
                    %{type: :interaction_requested, interaction_id: id, request: request}},
                   1_000

    assert request.scope.freshness_fingerprint == expected.fingerprint
    assert {:ok, _} = Credentials.update(credential.id, %{key: "rotated-during-consent"})

    assert :ok =
             Approval.resolve(pid, id, :approved, %{
               scope: request.scope,
               operation: request.operation
             })

    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
    refute_receive :freshness_effect, 0
    assert tool_intents(options) == []
  end

  test "native fresh allow and consent paths retain the effect boundary", ctx do
    capture = fn -> Freshness.capture(ctx.session, ctx.deps) end
    assert {:ok, expected} = capture.()

    for decision <- [:allow, :ask] do
      {pid, options} = conversation(ctx, expected, capture, decision)

      if decision == :ask do
        assert_receive {:agent_runtime, _,
                        %{type: :interaction_requested, interaction_id: id, request: request}},
                       1_000

        assert :ok =
                 Approval.resolve(pid, id, :approved, %{
                   scope: request.scope,
                   operation: request.operation
                 })
      end

      assert_receive :freshness_effect, 1_000
      assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
      assert length(tool_intents(options)) == 1
    end
  end

  defp permission(session),
    do: %{
      session_id: session,
      tool_contract_version: 1,
      mode: :interactive,
      allow_read: :allow,
      allow_write: :deny,
      allow_execute: :ask,
      allow_destructive: :deny,
      tool_overrides: %{}
    }

  defp readers(raw),
    do: %{
      permission: fn _ -> {:ok, raw} end,
      provider: fn id -> {:ok, {id, nil, true, nil, nil, nil}} end,
      credential: fn _ -> {:ok, :crypto.hash(:sha256, "encrypted-version")} end
    }

  defp provider! do
    {:ok, credential} = Credentials.create(%{name: "Freshness", key: "fixture-secret"})

    {:ok, provider} =
      Providers.create(%{
        name: "freshness-" <> Ecto.UUID.generate(),
        type: "openai",
        credential_id: credential.id
      })

    on_exit(fn ->
      ConfigStore.delete(:provider, provider.id)
      ConfigStore.delete(:credential, credential.id)
    end)

    {provider, credential}
  end

  defp conversation(ctx, expected, capture, decision) do
    run_id = Ecto.UUID.generate()

    scope = %{
      caller: "host",
      run_id: run_id,
      incarnation: 1,
      catalog_revision: 1,
      session_id: ctx.session,
      requester_id: "operator",
      permission_fingerprint: expected.permission_fingerprint,
      freshness_fingerprint: expected.fingerprint
    }

    descriptor = %{
      tool_name: "host::freshness",
      tool_revision: 1,
      description: "Inert freshness proof",
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      backend: Backend,
      backend_context: %{owner: self()},
      safety: %{
        read_only: true,
        retry_safe: false,
        parallel_safe: false,
        requires_approval: false
      }
    }

    authority = %{
      caller: scope.caller,
      run_id: run_id,
      grants: [descriptor.tool_name],
      tool_revision: 1
    }

    {:ok, bundle} = ToolCatalog.admit_batch([descriptor], mode: :strict, authority: authority)

    script = fn request ->
      if Enum.any?(request.messages, &(&1.role == :tool)),
        do: [Proof.completed("done")],
        else: [Proof.call(descriptor.tool_name, %{}), Proof.completed("calling")]
    end

    base = %{
      tool_scope: scope,
      expected: expected,
      capture: capture,
      script: script,
      input_kind: :function,
      tool_policy: %{
        scope: scope,
        tools: %{
          descriptor.tool_name => %{
            tool_revision: 1,
            classify: fn _ -> {:ok, %{action: "read", resource: "document"}} end
          }
        },
        decisions: %{{descriptor.tool_name, "read", "document"} => decision}
      },
      tool_readiness: %{
        scope: scope,
        tools: %{descriptor.tool_name => %{tool_revision: 1, status: :ready}}
      }
    }

    approval = %{
      mode: :interactive,
      scope: scope,
      expires_at: System.system_time(:millisecond) + 30_000
    }

    context =
      Map.put(
        base,
        :tool_approval,
        Map.put(approval, :refresh, fn ->
          with {:ok, current} <- capture.(), :ok <- Freshness.check(expected, current) do
            {:ok,
             Map.put(
               base,
               :tool_approval,
               Map.put(approval, :refresh, fn -> {:error, :unused} end)
             )
             |> Map.put(:interact, fn _ -> {:error, :unused} end)}
          end
        end)
      )

    options =
      Proof.options(run_id, script,
        registry: bundle.registry,
        authority: bundle.authority,
        tools: bundle.tools,
        hooks: Hooks,
        provider_context: context,
        schema_admission: :strict
      )

    pid = start_supervised!(%{id: make_ref(), start: {Conversation, :start_link, [options]}})
    assert {:ok, _} = Conversation.prompt(pid, "try tool")
    {pid, options}
  end

  defp tool_intents(options) do
    {:ok, persisted} = EphemeralStore.load(options[:context], options[:run_id])
    persisted.run.execution_intents |> Map.values() |> Enum.filter(&(&1.type == :tool))
  end
end
