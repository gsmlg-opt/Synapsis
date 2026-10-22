# Credentials Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development to implement this plan task-by-task. Preserve unrelated work and leave changes uncommitted.

**Goal:** Add encrypted reusable API credentials with Provider references, safe migration, runtime rotation and modal settings.

**Architecture:** `synapsis_data` owns Credentials, encryption and reference protection. Provider APIs own migration/compatibility and fresh authentication projection; existing MCP/Skill paths keep Provider references. Data change callbacks invalidate runtime snapshots without adding upward dependencies.

**Tech Stack:** Elixir umbrella, embedded Ecto schemas, TOML Config.Store, AES-256-GCM, OTP/PubSub, Phoenix LiveView, DuskMoon ReactForm/modal, Bypass.

Work in the existing main worktree because the approved design builds on its uncommitted Provider/model/MCP fixes. All Mix commands are serialized by the coordinator; HTTP fixtures use isolated configuration and ports.

## Shared interface

`Synapsis.Credentials` exposes safe metadata through `list/0`, `get/1`, `create/1`, `update/2`, `delete/1`. Inputs use `name` and `key`. Metadata includes `id`, `name`, `masked_key`, `inserted_at`, `updated_at`. `resolve/1` returns `{:ok, secret}` or `{:error, :credential_unavailable}`. `version/1` fingerprints stored encrypted content as well as record version, so external edits cannot evade invalidation. `references/1` returns referencing Provider identities. Referenced deletion returns `{:error, {:in_use, references}}`; ordinary not-found returns `{:error, :not_found}`. Mutations return `{:ok, record}` on success and Ecto changesets for validation.

Only Store callbacks pass changed credential IDs to upper layers. `ProviderConfig` adds `credential_id`. Public Provider structs retain a resolved `api_key_encrypted` compatibility projection in memory; new persisted records contain the reference instead of another Key copy.

### Task 1: Credential data APIs and reference invariants

Files: new `apps/synapsis_data/lib/synapsis/{credential_config.ex,credentials.ex}`, modify `provider_config.ex`, `config/store.ex`, tests under `apps/synapsis_data/test/synapsis/credentials_test.exs` and `config/store_server_test.exs`.

- [x] Add failing tests for encrypted storage/safe metadata, shared references, blank edit preservation, missing-reference rejection and in-use deletion.
- [x] Run `devenv shell --no-tui -- env MIX_TEST_PARTITION=_credentials mix test apps/synapsis_data/test/synapsis/credentials_test.exs`; confirm the new behavior fails before implementation.
- [x] Implement schema/CRUD using existing Store write lock and `Encrypted.Binary`; Store raw serialization uses `key_encrypted = "enc:v1:" <> Base.encode64(ciphertext)`.
- [x] Add `:credential`/`credentials.toml`, Provider reference validation and deletion protection to Store, and an optional successful-change callback after Server calls return. Reload notifications include old/new IDs.
- [x] Add idempotent `ensure_legacy_provider_key/3`, keyed by a persisted legacy Provider identity marker, to reuse a prior imported Credential without overwriting subsequent rotations.
- [x] Verify scoped data tests, including external encrypted-content reload when timestamps are unchanged.

### Task 2: Provider migration, compatibility and runtime resolution

Files: `apps/synapsis_provider/lib/synapsis/{providers.ex,provider/adapter.ex}`, core startup, `apps/synapsis_server/lib/synapsis_server/controllers/provider_controller.ex`, focused provider/server tests.

- [x] Write regressions for legacy migration/idempotency, same-secret Provider separation, interrupted migration, protected backup, OAuth exclusion and explicit unauthenticated Providers.
- [x] Convert legacy inline Keys to Credential records before changing Provider references; remove persisted inline Keys only after a successful replacement. Preserve all catalog/session/source identities.
- [x] Project current Credential data in Provider reads/runtime configs; resolve explicit missing references as unavailable. Install change callback at startup and refresh Registry/catalog after persisted changes and reload.
- [x] Preserve legacy raw-key API input for unshared credentials, reject shared-key compatibility mutation, and make clear-key detach the reference without deleting the Credential.
- [x] At Adapter stream/complete boundaries re-read authentication by Provider UUID while preserving session/model/request parameters. Verify one already-open session/config uses a rotated Key on the next request and refuses missing references.
- [x] Update Provider REST serialization/normalization and validation errors without exposing secret fields.

### Task 3: Credentials settings and Provider selectors

Files: new `apps/synapsis_web/lib/synapsis_web/live/credential_live/index.ex`, route/sidebar, Provider index/show and focused LiveView tests.

- [x] Add failing tests for list/modal CRUD, safe Key masking/no preload, in-use deletion and blank-edit behavior.
- [x] Implement `/settings/credentials` with existing settings layout, DuskMoon modal and native submit controls. Reuse MCPFormModal for close/reset behavior.
- [x] Replace non-OAuth Provider key inputs with Credential selectors and a management link, retaining explicit no-credential selection. Preserve drafts when options change.
- [x] Keep OAuth login controls and standalone custom MCP paths unchanged.
- [x] Verify focused web tests and browser behavior on isolated configuration.

### Task 4: MCP and remote Skill rotation

Files: `apps/synapsis_mcp/lib/synapsis/backplane/{provider_source.ex,connection.ex}`, `mcp/{server.ex,transport.ex}`, `mcp.ex`, application startup as needed, focused MCP tests.

- [x] Resolve linked source keys through Provider/Credentials rather than stored copies; retain legacy standalone handling.
- [x] Include Credential content/version in generation checks. Immediately invalidate obsolete clients/tool registrations and schedule reconnection outside configuration write locks.
- [x] Fence delayed discovery after rotation or missing references; verify old transport credentials cannot dispatch tools.
- [x] Verify remote Skill supplier reads new credentials without changing locator/revision/digest or cached access eligibility rules.

### Task 5: Integration verification and documentation

- [x] Run the changed data/provider/agent/MCP/server/web scoped suites; record exact counts and distinguish unrelated failures.
- [x] Run `mix format --check-formatted` on changed Elixir paths and `git diff --check`; build DuskMoon assets if asset inputs change.
- [x] Start an isolated Bypass-backed browser service. Verify modal create/edit/delete, Provider selection, shared-Key rotation, empty/no-credential state, draft preservation and one submit per click after modal reopen.
- [x] Perform independent spec compliance and code-quality reviews, resolve in-scope findings, and rerun only affected checks.
- [x] Update `docs/architecture/06_PROVIDERS.md`, this checklist and the existing Agent Note (`project:synapsis`). Stop owned fixtures; preserve user processes, configuration and unrelated edits.

No real-provider calls, commit, push, release or managed-service restart is included in this implementation request.


## Verified result — 2026-10-21

Implemented in the current uncommitted `main` worktree based on `350064a37d0923a76815e994f8f876df116b62c4`, preserving the existing Provider/model/MCP fixes.

- Final integration run, seed `432748`: data 48, provider 164, MCP 78, agent 1, server 37 and web 80; all 408 passed. After the browser-discovered deletion-warning regression, the final affected web run, seed `974246`, passed all 81. Final coverage therefore contains 409 distinct scoped tests.
- New regressions were observed failing before fixes, including migration/rotation/invalidation, nested key log filtering, and stale blocked-deletion references. Independent spec and quality reviews passed after repairs.
- Owned Elixir paths passed `mix format --check-formatted`; `git diff --check` passed. `mix assets.build` completed successfully. The isolated browser served `app-85bc750c.css` and `app-d482bc1d.js` and remained LiveView-connected.
- Isolated services used port 4668 and Bypass 4669 with test-only storage. Browser checks passed empty state, add/edit, name-only edit and blank key preservation, stable UUID on rotation, no saved key preload, cancel/Escape/header/backdrop draft reset, one submit per click after reopening, two Providers sharing the same credential, initial then rotated Bearer authentication for each Provider, draft preservation in an already-open Provider form, referenced deletion protection, live partial/final detach warning updates, and confirmed deletion after all references are removed. DOM and ordinary Provider API responses did not expose the saved secret; debug event logs filtered nested keys. No horizontal overflow was observed at desktop or the browser's minimum 500px viewport.
- Final browser had no console errors. Native confirmation emitted a non-blocking duplicate-close warning, reported as Bug [duskmoon-dev/phoenix-duskmoon-ui#208](https://github.com/duskmoon-dev/phoenix-duskmoon-ui/issues/208), severity `nice-to-have`, labeled `internal request`; the callsite has a TODO and no local workaround.
- Existing passing fixtures log malformed-source, shell-command and MCP-ready-timeout diagnostics; these were not assertion failures and no unrelated repairs were made.
- Owned fixture processes and browser pages were stopped. Port 4657's managed PID remained `1196071`; real config, defaults and session history were not changed. No commit, push, release or managed-service restart was performed. Real Backplane authentication remains a separate upstream issue, `gsmlg-opt/backplane#73`.
