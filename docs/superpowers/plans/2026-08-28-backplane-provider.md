# Backplane Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Backplane provider flow that works without a token in development, accepts a bearer token in production, and repairs existing providers by explicitly clearing stored credentials.

**Architecture:** Backplane remains a named preset over Synapsis's existing `openai` transport. Preset metadata controls the creation form and model discovery; provider persistence remains TOML-backed, and the unified provider adapter remains the only LLM request boundary. Empty credentials are normalized in the provider service and omitted defensively by the OpenAI adapter.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, Ecto embedded schemas, Req, Bypass, ExUnit, DuskMoon UI, TOML-backed `Synapsis.Config.Store`

---

## File Map

- `apps/synapsis_provider/lib/synapsis/providers.ex` — Backplane preset metadata and empty-credential persistence normalization.
- `apps/synapsis_provider/lib/synapsis/provider/adapter.ex` — optional bearer-header construction for OpenAI streaming and completion.
- `apps/synapsis_web/lib/synapsis_web/live/provider_live/index.ex` — Backplane creation form, editable URL, optional token, and post-create model discovery.
- `apps/synapsis_web/lib/synapsis_web/live/provider_live/show.ex` — explicit stored-token clearing action.
- `apps/synapsis_provider/test/synapsis/providers_test.exs` — preset, persistence, runtime-registry, and keyless model-discovery coverage.
- `apps/synapsis_provider/test/synapsis/provider/adapter_test.exs` — empty-string streaming/completion header regressions.
- `apps/synapsis_server/test/synapsis_server/controllers/provider_controller_test.exs` — REST serialization of an empty credential as not configured.
- `apps/synapsis_web/test/synapsis_web/live/provider_live/index_test.exs` — Backplane selection and keyless creation coverage.
- `apps/synapsis_web/test/synapsis_web/live/provider_live/show_test.exs` — explicit clear-token and subsequent model-refresh coverage.
- `docs/architecture/06_PROVIDERS.md` — Backplane deployment and authentication contract.

No new provider type is added to `Synapsis.ProviderConfig`, and no registry or MCP changes are required because the stored transport type remains `openai`.

### Task 1: Add Backplane to the Opt-in Provider Catalog

**Files:**
- Modify: `apps/synapsis_provider/lib/synapsis/providers.ex:245-274`
- Test: `apps/synapsis_provider/test/synapsis/providers_test.exs:521-540`

- [ ] **Step 1: Write failing preset-contract tests**

Add these tests inside `describe "preset_providers/0"`:

```elixir
test "includes Backplane as an opt-in OpenAI provider preset" do
  assert %{
           name: "backplane",
           label: "Backplane",
           type: "openai",
           base_url: "https://backplane.gsmlg.net/v1",
           base_url_editable: true,
           api_key_required: false,
           discover_models: true
         } = Enum.find(Providers.preset_providers(), &(&1.name == "backplane"))
end

test "does not seed Backplane before the user adds it" do
  assert :ok = Providers.seed_defaults()
  assert {:error, :not_found} = Providers.get_by_name("backplane")
end
```

Add this integration test inside `describe "models/1"`:

```elixir
test "loads keyless Backplane models without authorization" do
  bypass = Bypass.open()

  Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
    headers = Map.new(conn.req_headers)
    refute Map.has_key?(headers, "authorization")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "backplane-model"}]}))
  end)

  preset = Enum.find(Providers.preset_providers(), &(&1.name == "backplane"))
  assert %{name: "backplane"} = preset

  attrs =
    preset
    |> Map.take([:name, :type])
    |> Map.put(:base_url, "http://localhost:#{bypass.port}")

  assert {:ok, provider} = Providers.create(attrs)
  assert {:ok, [%{id: "backplane-model"}]} = Providers.models(provider.id)
end
```

- [ ] **Step 2: Run the preset tests and verify the first test fails**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_provider/test/synapsis/providers_test.exs
```

Expected: FAIL because no preset named `backplane` exists. The seeding test remains green and protects the opt-in behavior; the integration test fails before it can construct a provider from Backplane metadata.

- [ ] **Step 3: Add Backplane preset metadata without changing seeded defaults**

Add this module attribute immediately before the existing `@default_providers` attribute:

```elixir
@backplane_preset %{
  name: "backplane",
  label: "Backplane",
  type: "openai",
  base_url: "https://backplane.gsmlg.net/v1",
  base_url_editable: true,
  api_key_required: false,
  discover_models: true
}
```

Add this attribute immediately after the unchanged `@default_providers` list:

```elixir
@provider_presets [@backplane_preset | @default_providers]
```

Replace the preset accessor with:

```elixir
@doc "Return the list of known provider presets and their UI metadata."
def preset_providers, do: @provider_presets
```

Keep `seed_defaults/0` iterating over `@default_providers`; this prevents Backplane from appearing as a configured provider until the user selects it.

- [ ] **Step 4: Run the provider tests and verify they pass**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_provider/test/synapsis/providers_test.exs
```

Expected: all `Synapsis.ProvidersTest` tests pass.

- [ ] **Step 5: Commit the catalog change**

```bash
git add apps/synapsis_provider/lib/synapsis/providers.ex apps/synapsis_provider/test/synapsis/providers_test.exs
git commit -m "feat(provider): add Backplane preset metadata"
```

### Task 2: Omit Empty Bearer Credentials from OpenAI Requests

**Files:**
- Modify: `apps/synapsis_provider/lib/synapsis/provider/adapter.ex:276-299,629-659`
- Test: `apps/synapsis_provider/test/synapsis/provider/adapter_test.exs:156-182,522-545`

- [ ] **Step 1: Write a failing streaming regression test**

Add this test inside `describe "stream/2 OpenAI"`:

```elixir
test "empty api_key omits Authorization header while streaming", %{
  bypass: bypass,
  port: port
} do
  Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
    headers = Map.new(conn.req_headers)
    refute Map.has_key?(headers, "authorization")

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, """
    data: {"id":"1","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}

    data: [DONE]

    """)
  end)

  config = %{api_key: "", base_url: "http://localhost:#{port}", type: "openai"}
  request = Adapter.format_request([], [], %{model: "gpt-4o", provider_type: "openai"})

  assert {:ok, ref} = Adapter.stream(request, config)
  assert :done in collect_chunks(ref)
end
```

- [ ] **Step 2: Write a failing synchronous-completion regression test**

Add this test inside the existing `complete/2` describe block, next to the no-key OpenAI test:

```elixir
test "OpenAI complete with empty api_key omits Authorization header", %{
  bypass: bypass,
  port: port
} do
  Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
    headers = Map.new(conn.req_headers)
    refute Map.has_key?(headers, "authorization")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      200,
      Jason.encode!(%{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "Hi"}}]
      })
    )
  end)

  config = %{api_key: "", base_url: "http://localhost:#{port}", type: "openai"}
  request = Adapter.format_request([], [], %{model: "gpt-4o", provider_type: "openai"})

  assert {:ok, "Hi"} = Adapter.complete(request, config)
end
```

- [ ] **Step 3: Run the adapter tests and verify both tests fail on the header assertions**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_provider/test/synapsis/provider/adapter_test.exs
```

Expected: both new tests FAIL because Elixir treats `""` as truthy and the adapter sends `Authorization: Bearer `.

- [ ] **Step 4: Centralize optional OpenAI authorization headers**

Replace the non-Azure header construction in `do_openai_stream/3` with:

```elixir
headers = [{"content-type", "application/json"}] ++ openai_auth_headers(config)
```

Replace the header construction in `do_openai_complete/2` with:

```elixir
headers = [{"content-type", "application/json"}] ++ openai_auth_headers(config)
```

Add this helper immediately before `openai_chat_completions_url/1`:

```elixir
defp openai_auth_headers(config) do
  case config[:api_key] || config["api_key"] do
    api_key when is_binary(api_key) and api_key != "" ->
      [{"authorization", "Bearer #{api_key}"}]

    _other ->
      []
  end
end
```

Do not change Azure's `api-key` handling; Backplane uses the ordinary OpenAI-compatible branch.

- [ ] **Step 5: Run the adapter tests and verify they pass**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_provider/test/synapsis/provider/adapter_test.exs
```

Expected: all adapter tests pass, including the existing non-empty bearer and nil-key cases.

- [ ] **Step 6: Commit the transport fix**

```bash
git add apps/synapsis_provider/lib/synapsis/provider/adapter.ex apps/synapsis_provider/test/synapsis/provider/adapter_test.exs
git commit -m "fix(provider): omit empty bearer credentials"
```

### Task 3: Normalize Empty Credentials at the Provider Boundary

**Files:**
- Modify: `apps/synapsis_provider/lib/synapsis/providers.ex:329-351`
- Test: `apps/synapsis_provider/test/synapsis/providers_test.exs:20-41`
- Test: `apps/synapsis_server/test/synapsis_server/controllers/provider_controller_test.exs:67-98`

- [ ] **Step 1: Write a failing provider persistence and registry test**

Add this test inside `describe "create/1"`:

```elixir
test "normalizes an empty api key to no credential" do
  assert {:ok, provider} =
           Providers.create(%{
             name: "keyless-openai",
             type: "openai",
             base_url: "http://localhost:4220/v1",
             api_key_encrypted: ""
           })

  assert is_nil(provider.api_key_encrypted)
  assert {:ok, %{api_key: nil}} = ProviderRegistry.get("keyless-openai")
  assert {:ok, persisted} = Providers.get(provider.id)
  assert is_nil(persisted.api_key_encrypted)
end
```

- [ ] **Step 2: Write a failing REST serialization test**

Add this test inside `describe "POST /api/providers"`:

```elixir
test "reports an empty api key as not configured", %{conn: conn} do
  conn =
    post(conn, "/api/providers", %{
      "name" => "keyless-openai",
      "type" => "openai",
      "base_url" => "http://localhost:4220/v1",
      "api_key" => ""
    })

  %{"data" => provider} = json_response(conn, 201)
  assert provider["has_api_key"] == false

  assert {:ok, persisted} = Providers.get(provider["id"])
  assert is_nil(persisted.api_key_encrypted)
end
```

- [ ] **Step 3: Run both test files and verify the new assertions fail**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_provider/test/synapsis/providers_test.exs apps/synapsis_server/test/synapsis_server/controllers/provider_controller_test.exs
```

Expected: FAIL because the empty binary currently survives the Ecto changeset and is stored as a configured credential.

- [ ] **Step 4: Normalize the applied provider record before persistence**

Replace `persist/1` for a valid changeset with:

```elixir
defp persist(%Ecto.Changeset{valid?: true} = changeset) do
  record =
    changeset
    |> Ecto.Changeset.apply_changes()
    |> normalize_api_key()
    |> ensure_id()
    |> ensure_timestamps()

  case Store.put(@store_type, to_store_map(record)) do
    :ok ->
      sync_to_registry(record)
      {:ok, record}

    {:ok, _} ->
      sync_to_registry(record)
      {:ok, record}

    error ->
      error
  end
end
```

Add these clauses immediately before `persist/1`:

```elixir
defp normalize_api_key(%ProviderConfig{api_key_encrypted: ""} = provider),
  do: %{provider | api_key_encrypted: nil}

defp normalize_api_key(%ProviderConfig{} = provider), do: provider
```

- [ ] **Step 5: Run both test files and verify they pass**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_provider/test/synapsis/providers_test.exs apps/synapsis_server/test/synapsis_server/controllers/provider_controller_test.exs
```

Expected: both suites pass; empty credentials are omitted from TOML storage and exposed as `has_api_key: false`.

- [ ] **Step 6: Commit the provider-boundary fix**

```bash
git add apps/synapsis_provider/lib/synapsis/providers.ex apps/synapsis_provider/test/synapsis/providers_test.exs apps/synapsis_server/test/synapsis_server/controllers/provider_controller_test.exs
git commit -m "fix(provider): normalize empty credentials"
```

### Task 4: Build the Backplane Creation Flow

**Files:**
- Modify: `apps/synapsis_web/lib/synapsis_web/live/provider_live/index.ex:31-68,110-117,146-209,223-240`
- Test: `apps/synapsis_web/test/synapsis_web/live/provider_live/index_test.exs:38-76,176-226`

- [ ] **Step 1: Write a failing Backplane form test**

Add this test after the existing preset-selection tests:

```elixir
test "selecting Backplane shows an editable URL and optional access token", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

  html =
    view
    |> element(~s(button[phx-click="select_preset"][phx-value-name="backplane"]))
    |> render_click()

  assert html =~ "Add Backplane"
  assert html =~ "http://localhost:4220/v1"
  assert has_element?(view, ~s(input[name="base_url"][value="https://backplane.gsmlg.net/v1"]))
  assert has_element?(view, ~s(input[name="api_key"]))
  refute has_element?(view, ~s(input[name="api_key"][required]))
  assert html =~ "Access Token (optional)"
end
```

- [ ] **Step 2: Write a failing keyless creation and discovery test**

Add this test after the form test:

```elixir
test "creates keyless Backplane provider and discovers models without authorization", %{
  conn: conn
} do
  bypass = Bypass.open()

  Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
    headers = Map.new(conn.req_headers)
    refute Map.has_key?(headers, "authorization")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "backplane-model"}]}))
  end)

  {:ok, view, _html} = live(conn, ~p"/settings/providers/new")

  view
  |> element(~s(button[phx-click="select_preset"][phx-value-name="backplane"]))
  |> render_click()

  view
  |> form("form[phx-submit]", %{
    "name" => "backplane-dev",
    "base_url" => "http://localhost:#{bypass.port}/v1",
    "api_key" => ""
  })
  |> render_submit()

  flash = assert_redirected(view, ~p"/settings/providers")
  assert flash["info"] == "Provider created and models loaded"

  assert {:ok, provider} = Synapsis.Providers.get_by_name("backplane-dev")
  assert provider.type == "openai"
  assert provider.base_url == "http://localhost:#{bypass.port}/v1"
  assert is_nil(provider.api_key_encrypted)
  assert [%{"id" => "backplane-model"}] = provider.config["available_models"]
end
```

- [ ] **Step 3: Run the ProviderLive index tests and verify the Backplane tests fail**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/provider_live/index_test.exs
```

Expected: FAIL because Backplane is not rendered with the required metadata-driven form behavior.

- [ ] **Step 4: Make the selected Backplane URL editable and persist the submitted URL**

Replace the `base_url` entry in `attrs` with:

```elixir
base_url:
  if(preset.custom or Map.get(preset, :base_url_editable, false),
    do: params["base_url"],
    else: preset.base_url
  ),
```

Replace the base URL branch in the HEEx form with:

```heex
<%= if @selected_preset.custom or Map.get(@selected_preset, :base_url_editable, false) do %>
  <.dm_input
    type="text"
    name="base_url"
    value={@selected_preset.base_url}
    placeholder="https://api.example.com/v1"
    label="Base URL"
    required
  />
<% else %>
  <.readonly_field label="Base URL" value={@selected_preset.base_url} />
<% end %>
```

- [ ] **Step 5: Render Backplane labels, guidance, and optional-token semantics**

Replace the non-custom form title with:

```heex
Add {Map.get(@selected_preset, :label, @selected_preset.name)}
```

Insert this guidance immediately after the base URL field:

```heex
<div
  :if={@selected_preset.name == "backplane"}
  class="bg-info/10 border border-info/30 rounded-lg px-3 py-2 text-sm text-info"
>
  Production requires an access token. For local development, use
  http://localhost:4220/v1 and leave the token empty.
</div>
```

Replace the non-OAuth key input with:

```heex
<.dm_input
  type="password"
  name="api_key"
  value=""
  placeholder={
    if @selected_preset.name == "backplane",
      do: "Optional for local development",
      else: "Enter API key"
  }
  label={
    if @selected_preset.name == "backplane",
      do: "Access Token (optional)",
      else: "API Key"
  }
  required={Map.get(@selected_preset, :api_key_required, true)}
/>
```

Replace the preset-card name with:

```heex
<div class="font-medium">{Map.get(preset, :label, preset.name)}</div>
```

- [ ] **Step 6: Enable model discovery for metadata-marked presets**

Replace both `maybe_refresh_models_on_create/2` clauses with:

```elixir
defp maybe_refresh_models_on_create(provider, preset) do
  if preset.custom or Map.get(preset, :discover_models, false) do
    case Synapsis.Providers.refresh_models(provider.id) do
      {:ok, updated} -> {updated, "Provider created and models loaded"}
      {:error, _reason} -> {provider, "Provider created; model loading failed"}
    end
  else
    {provider, "Provider created"}
  end
end
```

- [ ] **Step 7: Run the ProviderLive index tests and verify they pass**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/provider_live/index_test.exs
```

Expected: all index tests pass, including the Bypass assertion that keyless Backplane discovery sends no authorization header.

- [ ] **Step 8: Commit the Backplane creation flow**

```bash
git add apps/synapsis_web/lib/synapsis_web/live/provider_live/index.ex apps/synapsis_web/test/synapsis_web/live/provider_live/index_test.exs
git commit -m "feat(web): add Backplane provider flow"
```

### Task 5: Add Explicit Stored-token Clearing

**Files:**
- Modify: `apps/synapsis_web/lib/synapsis_web/live/provider_live/show.ex:49-122,490-501`
- Test: `apps/synapsis_web/test/synapsis_web/live/provider_live/show_test.exs:78-112,168-199`

- [ ] **Step 1: Write a failing clear-and-refresh regression test**

Add this test after the existing API-key update tests:

```elixir
test "clears a stored token and refreshes models without authorization", %{conn: conn} do
  bypass = Bypass.open()

  Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
    headers = Map.new(conn.req_headers)
    refute Map.has_key?(headers, "authorization")

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "backplane-model"}]}))
  end)

  {:ok, provider} =
    Synapsis.Providers.create(%{
      name: "backplane-clear-#{:rand.uniform(100_000)}",
      type: "openai",
      base_url: "http://localhost:#{bypass.port}/v1",
      api_key_encrypted: "placeholder-token",
      config: %{"available_models" => [%{"id" => "old-model", "name" => "Old Model"}]}
    })

  {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
  assert html =~ "Key is set"
  assert html =~ "Clear stored token"

  html = render_hook(view, "clear_api_key", %{})
  assert html =~ "Access token cleared"
  refute html =~ "Key is set"

  assert {:ok, updated} = Synapsis.Providers.get(provider.id)
  assert is_nil(updated.api_key_encrypted)
  assert {:ok, %{api_key: nil}} = Synapsis.Provider.Registry.get(provider.name)

  html =
    view
    |> element(~s(el-dm-button[phx-click="refresh_models"]))
    |> render_click()

  assert html =~ "Models refreshed"
  assert html =~ "backplane-model"
end
```

Add this idempotency test after the clear-and-refresh test:

```elixir
test "clearing an absent token remains keyless", %{conn: conn} do
  {:ok, provider} =
    Synapsis.Providers.create(%{
      name: "already-keyless-#{:rand.uniform(100_000)}",
      type: "openai",
      base_url: "http://localhost:4220/v1",
      config: %{"available_models" => [%{"id" => "cached-model", "name" => "Cached Model"}]}
    })

  {:ok, view, html} = live(conn, ~p"/settings/providers/#{provider.id}")
  refute html =~ "Key is set"

  html = render_hook(view, "clear_api_key", %{})
  assert html =~ "Access token cleared"

  assert {:ok, updated} = Synapsis.Providers.get(provider.id)
  assert is_nil(updated.api_key_encrypted)
  assert {:ok, %{api_key: nil}} = Synapsis.Provider.Registry.get(provider.name)
end
```

- [ ] **Step 2: Run the ProviderLive show tests and verify the new test fails**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/provider_live/show_test.exs
```

Expected: FAIL because the `clear_api_key` event and button do not exist.

- [ ] **Step 3: Implement the clear event using the existing provider service**

Add this event clause immediately after the existing `handle_event/3` clause for `"update_provider"`:

```elixir
def handle_event("clear_api_key", _params, socket) do
  case Synapsis.Providers.update(socket.assigns.provider.id, %{api_key_encrypted: nil}) do
    {:ok, provider} ->
      {:noreply,
       socket
       |> assign(provider: provider)
       |> put_flash(:info, "Access token cleared")}

    {:error, _reason} ->
      {:noreply, put_flash(socket, :error, "Failed to clear access token")}
  end
end
```

- [ ] **Step 4: Render an explicit clear button only when a credential is present**

Replace the key indicator block with:

```heex
<div
  :if={@provider.api_key_encrypted not in [nil, ""]}
  class="flex items-center justify-between gap-3 text-xs text-success mt-1"
>
  <span>Key is set</span>
  <.dm_btn
    type="button"
    variant="ghost"
    size="xs"
    phx-click="clear_api_key"
    confirm="Clear the stored access token?"
  >
    Clear stored token
  </.dm_btn>
</div>
```

Keep blank edit submissions preserving the existing key; the new action is the only destructive credential path.

- [ ] **Step 5: Run the ProviderLive show tests and verify they pass**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_web/test/synapsis_web/live/provider_live/show_test.exs
```

Expected: all show tests pass, including the existing blank-means-keep behavior and the new clear-and-refresh flow.

- [ ] **Step 6: Commit the clear-token flow**

```bash
git add apps/synapsis_web/lib/synapsis_web/live/provider_live/show.ex apps/synapsis_web/test/synapsis_web/live/provider_live/show_test.exs
git commit -m "feat(web): clear stored provider tokens"
```

### Task 6: Document and Verify the Complete Provider Contract

**Files:**
- Modify: `docs/architecture/06_PROVIDERS.md:56-72,145-165`

- [ ] **Step 1: Document Backplane's transport and authentication modes**

Add this subsection after the transport-resolution table:

```markdown
### Backplane Preset

Backplane is a named provider preset that uses the existing `openai` transport.
The hosted endpoint defaults to `https://backplane.gsmlg.net/v1` and requires an
access token. Local development commonly uses `http://localhost:4220/v1` and may
run without authentication. Synapsis sends `Authorization: Bearer <token>` only
when a non-empty token is configured.

The Backplane preset is opt-in rather than startup-seeded. Its base URL is
editable during creation, and successful creation discovers and caches models
from `<base_url>/models`.
```

- [ ] **Step 2: Format only the changed Elixir files**

Run:

```bash
devenv shell --no-tui -- mix format apps/synapsis_provider/lib/synapsis/providers.ex apps/synapsis_provider/lib/synapsis/provider/adapter.ex apps/synapsis_provider/test/synapsis/providers_test.exs apps/synapsis_provider/test/synapsis/provider/adapter_test.exs apps/synapsis_server/test/synapsis_server/controllers/provider_controller_test.exs apps/synapsis_web/lib/synapsis_web/live/provider_live/index.ex apps/synapsis_web/lib/synapsis_web/live/provider_live/show.ex apps/synapsis_web/test/synapsis_web/live/provider_live/index_test.exs apps/synapsis_web/test/synapsis_web/live/provider_live/show_test.exs
```

Expected: exit 0.

- [ ] **Step 3: Run the scoped regression suite**

Run:

```bash
devenv shell --no-tui -- mix test apps/synapsis_data/test/synapsis/provider_config_test.exs apps/synapsis_provider/test/synapsis/providers_test.exs apps/synapsis_provider/test/synapsis/provider/adapter_test.exs apps/synapsis_provider/test/synapsis/provider/transport/openai_test.exs apps/synapsis_server/test/synapsis_server/controllers/provider_controller_test.exs apps/synapsis_web/test/synapsis_web/live/provider_live/index_test.exs apps/synapsis_web/test/synapsis_web/live/provider_live/show_test.exs
```

Expected: 0 failures. If a test outside these paths fails, report it and stop without changing unrelated code.

- [ ] **Step 4: Verify compilation, formatting, and diff hygiene**

Run:

```bash
devenv shell --no-tui -- mix compile --warnings-as-errors
devenv shell --no-tui -- mix format --check-formatted
git diff --check
git status --short
```

Expected: both Mix commands and `git diff --check` exit 0; status lists only the scoped documentation change before its commit.

- [ ] **Step 5: Commit the architecture documentation**

```bash
git add docs/architecture/06_PROVIDERS.md
git commit -m "docs(provider): document Backplane modes"
```

- [ ] **Step 6: Verify the final branch state**

Run:

```bash
git status --short --branch
git log --oneline --decorate -8
```

Expected: clean `codex/backplane-provider` worktree with the design and plan commits followed by six logical implementation/documentation commits.

### Task 7: Post-integration Live Proof and Agent Note

**Files:**
- No repository files changed.

- [ ] **Step 1: Integrate the verified branch into the checkout that owns port 4657**

Use the repository's branch-finishing workflow. Preserve the unrelated `AGENTS.md` modification and `CLAUDE.md` deletion in the main checkout; do not stage or revert them.

- [ ] **Step 2: Restart the managed Synapsis process**

Run from the integrated main checkout:

```bash
devenv processes restart synapsis
devenv processes list --no-tui
```

Expected: `synapsis` reaches `ready` with a new BEAM process.

- [ ] **Step 3: Prove HTTP readiness**

Run:

```bash
curl -sS -o /dev/null -w "%{http_code}\n" --max-time 10 http://127.0.0.1:4657/
```

Expected: `200`.

- [ ] **Step 4: Repair the current Backplane provider through the UI**

Open:

```text
http://10.100.10.28:4657/settings/providers/e309f0bf-6790-4e39-b4b9-27e2354e664f
```

Use `Clear stored token`, then `Refresh Models`.

Expected: the `Key is set` indicator disappears, the refresh succeeds, and the Backplane model list is rendered.

- [ ] **Step 5: Confirm the original HTTP 401 no longer occurs**

Run:

```bash
devenv processes logs synapsis -n 80 --stdout
```

Expected: the latest `refresh_models` event has no `provider_models_refresh_failed reason="HTTP 401"` warning.

- [ ] **Step 6: Save the required agent note**

Call `mcp__agent_note__save_note` with:

```text
title: Synapsis Backplane provider supports optional access tokens
labels: [["project", "synapsis"]]
content:
## Summary

Added an opt-in Backplane provider preset over the existing OpenAI-compatible
transport. The production default is https://backplane.gsmlg.net/v1, while
local development can use http://localhost:4220/v1 without a token.

## Root cause

The provider form required a credential, so the development provider stored a
placeholder bearer token. Backplane open mode accepts a missing credential but
rejects an invalid supplied credential, causing model discovery to return HTTP
401.

## Resolution

Backplane creation now supports an editable URL and optional access token,
empty credentials are normalized and omitted from requests, model discovery
runs after creation, and existing credentials can be cleared explicitly.

## Verification

Focused provider, server, and LiveView tests passed. The managed Synapsis
process was restarted, HTTP readiness returned 200, and the repaired development
provider loaded Backplane models without the prior HTTP 401.
```

Expected: the note is saved with label `project: synapsis`; record the returned note ID in the final handoff.
