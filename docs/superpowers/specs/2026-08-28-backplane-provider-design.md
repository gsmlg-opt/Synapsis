# Backplane Provider Design

Status: approved on 2026-08-28

## Problem

Synapsis can already call OpenAI-compatible endpoints without an API key, but
its provider UI does not expose that capability safely.

The existing `backplane-openai` provider demonstrates the failure. It points to
`http://10.100.10.28:4220/v1` and has a stored placeholder credential. Synapsis
therefore sends an `Authorization: Bearer ...` header. The development
Backplane accepts requests with no credential, but rejects an invalid supplied
credential, so model discovery returns HTTP 401. Directly requesting
`/v1/models` without the header succeeds and returns the expected model list.

Backplane has two supported deployment modes:

- Local development normally runs at `http://localhost:4220/v1` and may be
  configured without a token.
- Production runs at `https://backplane.gsmlg.net/v1` and requires an access
  token.

One Synapsis provider configuration must support both modes.

## Goals

- Add Backplane as a recognizable provider preset.
- Keep Backplane on the existing OpenAI-compatible transport.
- Allow a Backplane provider to be created without a token.
- Allow a token to be supplied for protected production deployments.
- Allow an existing stored token to be cleared explicitly.
- Never send an authorization header for a nil or empty token.
- Discover and cache Backplane models after provider creation.
- Repair and verify the currently failing development provider after the code
  is available in the running application.

## Non-goals

- Do not add a new wire protocol, provider adapter, or dependency.
- Do not use the Backplane MCP client for LLM traffic.
- Do not infer whether a Backplane deployment requires authentication from its
  hostname or runtime environment.
- Do not migrate or rewrite existing provider records automatically.
- Do not change authentication requirements for official Anthropic, OpenAI,
  Google, or other provider presets.
- Do not change Backplane itself.

## Provider Representation

Backplane will be a first-class named preset with `type: "openai"`. Provider
types in Synapsis describe the wire protocol; preset names describe vendors or
deployments. This follows the existing pattern used by providers that reuse a
shared transport.

The Backplane preset will provide this metadata:

- Name and label: `backplane` / `Backplane`
- Transport type: `openai`
- Default base URL: `https://backplane.gsmlg.net/v1`
- Base URL: editable during creation
- Access token: optional
- Model discovery: enabled after creation

The form will explain that local development normally uses
`http://localhost:4220/v1` with no token. The production URL remains the default
because it is Backplane's stable hosted endpoint.

## Credential Semantics

The form label will be `Access Token (optional)` for Backplane.

- A non-empty token is persisted and sent as `Authorization: Bearer <token>`.
- A missing token is persisted as no credential and sends no authorization
  header.
- An empty string is normalized to no credential at runtime and must not
  produce `Authorization: Bearer `.
- On the edit page, leaving the password field blank continues to mean "keep
  the current token" so that saving an unrelated setting cannot erase a
  credential.
- When a token is stored, an explicit `Clear stored token` action removes it,
  updates the runtime provider registry, and removes the `Key is set`
  indicator.

The Backplane server remains authoritative for authentication policy. A
protected deployment will reject a missing or invalid token; an open
development deployment will accept a missing token and reject an invalid token.

## Data and Request Flow

### Creation

1. The user selects the Backplane preset.
2. Synapsis pre-fills the production base URL and allows it to be replaced with
   a local or custom Backplane URL.
3. The user may leave the token blank or enter a production token.
4. Synapsis persists the provider through the existing TOML-backed
   `Synapsis.Providers` API and registers the resulting runtime configuration.
5. Synapsis requests `<base_url>/models`, omitting authorization when the token
   is absent.
6. Successful model metadata is cached in the provider config.

### Existing Provider Repair

1. The user opens the existing provider.
2. The user invokes `Clear stored token`.
3. Synapsis persists a nil credential and refreshes the runtime registry.
4. Refresh Models sends no authorization header and caches the returned
   Backplane models.

### Chat and Completion

Backplane continues through the OpenAI request mapper and transport. Streaming
and synchronous completion requests use the same optional bearer-token rule as
model discovery.

## Error Handling

- A failed model refresh keeps the provider record and reports the existing
  refresh failure without caching a partial result.
- Clearing an absent token is harmless and leaves the provider keyless.
- A protected Backplane deployment with no token returns its normal
  authentication error; Synapsis does not guess or synthesize credentials.
- A malformed or unreachable base URL follows existing provider validation and
  transport error behavior.

## Test Strategy

Focused tests will cover the public seams rather than duplicating framework
behavior:

- Provider preset tests confirm Backplane uses the `openai` transport, the
  production default URL, editable URL metadata, optional token metadata, and
  automatic model discovery.
- Provider service integration uses Bypass to create a keyless Backplane
  provider, assert `GET /v1/models`, assert that no authorization header is
  present, and verify returned/cached models.
- LiveView creation tests assert the Backplane option is rendered, its token
  input is not marked `required`, blank-token creation succeeds, and model
  loading is attempted.
- LiveView edit tests clear an existing token, verify the persisted and runtime
  values are nil, and verify the key indicator disappears.
- OpenAI adapter tests verify both streaming and synchronous completion omit
  authorization for `""`; existing tests continue to cover nil credentials and
  non-empty bearer tokens.
- Existing focused provider, transport, and ProviderLive tests run as the
  regression suite.

## Live Verification

After the focused automated checks pass and the implementation is integrated:

1. Restart the managed Synapsis process so the running service uses the new
   code and assets.
2. Open the current `backplane-openai` provider.
3. Clear its stored token explicitly.
4. Refresh models and confirm the Backplane model list appears.
5. Confirm Backplane receives no authorization header in development.
6. Probe the Synapsis HTTP endpoint after restart to prove application
   readiness.
