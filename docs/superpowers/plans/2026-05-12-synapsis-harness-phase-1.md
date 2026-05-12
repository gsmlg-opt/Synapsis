# Synapsis Harness Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the harness data-model and pure context fold foundation without changing the current session runtime, REST API, channel API, or LiveView behavior.

**Architecture:** Pure harness ADTs and fold logic live in `synapsis_core` under `Synapsis.Harness`. Database schemas, migrations, and Repo-facing functions live in `synapsis_data`. The current embedded `messages.parts` projection remains intact until later phases add dual-write/projection behavior.

**Tech Stack:** Elixir 1.18, Ecto/PostgreSQL, ExUnit, existing umbrella apps `synapsis_core` and `synapsis_data`.

---

## Scope

In:

- Pure harness event structs and builders.
- Pure `Synapsis.Harness.Context.apply_event/2`.
- Additive `harness_events` event-log schema and migration.
- Additive row-level `parts` table with schema named `Synapsis.MessagePart`.
- Focused tests for event builders, fold behavior, and data changesets.

Out:

- No `Session.Worker` replacement.
- No `gen_statem` shell.
- No provider adapter changes.
- No public API or LiveView payload changes.
- No migration of existing embedded message parts.

## File Map

- Create: `apps/synapsis_core/lib/synapsis/harness/event.ex`
  Defines the event structs and constructors used by the fold.
- Create: `apps/synapsis_core/lib/synapsis/harness/context.ex`
  Defines fold state and `apply_event/2`.
- Create: `apps/synapsis_core/test/synapsis/harness/event_test.exs`
  Tests event constructors and event metadata.
- Create: `apps/synapsis_core/test/synapsis/harness/context_test.exs`
  Tests fold behavior for session creation, message/part append, tool updates,
  permissions, abort, and compaction.
- Create: `apps/synapsis_data/lib/synapsis/harness_event.ex`
  Ecto schema for durable harness events.
- Create: `apps/synapsis_data/lib/synapsis/harness_events.ex`
  Repo-facing append/list helpers with optimistic per-session versioning.
- Create: `apps/synapsis_data/lib/synapsis/message_part.ex`
  Ecto schema for row-level parts stored in table `parts`.
- Create: `apps/synapsis_data/priv/repo/migrations/20260512000001_create_harness_events.exs`
  Additive event-log migration.
- Create: `apps/synapsis_data/priv/repo/migrations/20260512000002_create_parts.exs`
  Additive row-level part migration.
- Create: `apps/synapsis_data/test/synapsis/harness_events_test.exs`
  Tests event append/list behavior.
- Create: `apps/synapsis_data/test/synapsis/message_part_test.exs`
  Tests changesets and indexes for row-level parts.

---

### Task 1: Harness Event ADTs

**Files:**
- Create: `apps/synapsis_core/test/synapsis/harness/event_test.exs`
- Create: `apps/synapsis_core/lib/synapsis/harness/event.ex`

- [x] **Step 1: Write failing event tests**

```elixir
defmodule Synapsis.Harness.EventTest do
  use ExUnit.Case, async: true

  alias Synapsis.Harness.Event

  test "session_created carries aggregate metadata" do
    event =
      Event.session_created("session-1",
        project_id: "project-1",
        parent_id: nil,
        metadata: %{"model" => "claude"}
      )

    assert %Event.SessionCreated{
             aggregate_id: "session-1",
             version: nil,
             project_id: "project-1",
             parent_id: nil,
             metadata: %{"model" => "claude"}
           } = event
  end

  test "message_appended stores the role-tagged message payload" do
    event =
      Event.message_appended("session-1", %{
        id: "message-1",
        role: :user,
        ordinal: 0
      })

    assert %Event.MessageAppended{
             aggregate_id: "session-1",
             message: %{id: "message-1", role: :user, ordinal: 0}
           } = event
  end

  test "part_appended stores durable part identity and type" do
    event =
      Event.part_appended("session-1", "message-1", %{
        id: "part-1",
        type: :text,
        ordinal: 0,
        data: %{content: "hello"}
      })

    assert %Event.PartAppended{
             aggregate_id: "session-1",
             message_id: "message-1",
             part: %{id: "part-1", type: :text, ordinal: 0, data: %{content: "hello"}}
           } = event
  end
end
```

- [x] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
mix test apps/synapsis_core/test/synapsis/harness/event_test.exs
```

Expected: failure because `Synapsis.Harness.Event` does not exist.

- [x] **Step 3: Add the minimal event module**

```elixir
defmodule Synapsis.Harness.Event do
  @moduledoc "Pure event ADTs for the harness session aggregate."

  defmodule Base do
    @moduledoc false
    defstruct [:event_id, :aggregate_id, :version, :inserted_at]
  end

  defmodule SessionCreated do
    @moduledoc "Session aggregate was created."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :project_id, :parent_id, metadata: %{}]
  end

  defmodule MessageAppended do
    @moduledoc "A message was appended to the session."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :message]
  end

  defmodule PartAppended do
    @moduledoc "A part was appended to a message."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :message_id, :part]
  end

  defmodule PartUpdated do
    @moduledoc "A part was updated by patch."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :message_id, :part_id, patch: %{}]
  end

  defmodule ToolInvoked do
    @moduledoc "A tool invocation became durable."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :message_id, :part_id, :tool_name, args: %{}]
  end

  defmodule ToolReturned do
    @moduledoc "A tool invocation returned a result or error."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :message_id, :part_id, :result, :error]
  end

  defmodule PermissionRequested do
    @moduledoc "Tool execution is waiting on a user permission decision."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :request_id, :part_id, :effect_class]
  end

  defmodule PermissionGranted do
    @moduledoc "User granted a permission request."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :request_id]
  end

  defmodule PermissionDenied do
    @moduledoc "User denied a permission request."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :request_id, :reason]
  end

  defmodule Aborted do
    @moduledoc "Session turn was aborted."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, :reason]
  end

  defmodule Compacted do
    @moduledoc "Messages were compacted into a summary part."
    defstruct [:event_id, :aggregate_id, :version, :inserted_at, replaced_message_ids: [], summary_part: nil]
  end

  def session_created(session_id, opts) do
    %SessionCreated{
      aggregate_id: session_id,
      project_id: Keyword.fetch!(opts, :project_id),
      parent_id: Keyword.get(opts, :parent_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  def message_appended(session_id, message), do: %MessageAppended{aggregate_id: session_id, message: message}
  def part_appended(session_id, message_id, part), do: %PartAppended{aggregate_id: session_id, message_id: message_id, part: part}
  def part_updated(session_id, message_id, part_id, patch), do: %PartUpdated{aggregate_id: session_id, message_id: message_id, part_id: part_id, patch: patch}
  def tool_invoked(session_id, message_id, part_id, tool_name, args), do: %ToolInvoked{aggregate_id: session_id, message_id: message_id, part_id: part_id, tool_name: tool_name, args: args}
  def tool_returned(session_id, message_id, part_id, result_or_error), do: build_tool_returned(session_id, message_id, part_id, result_or_error)
  def permission_requested(session_id, request_id, part_id, effect_class), do: %PermissionRequested{aggregate_id: session_id, request_id: request_id, part_id: part_id, effect_class: effect_class}
  def permission_granted(session_id, request_id), do: %PermissionGranted{aggregate_id: session_id, request_id: request_id}
  def permission_denied(session_id, request_id, reason), do: %PermissionDenied{aggregate_id: session_id, request_id: request_id, reason: reason}
  def aborted(session_id, reason), do: %Aborted{aggregate_id: session_id, reason: reason}
  def compacted(session_id, replaced_message_ids, summary_part), do: %Compacted{aggregate_id: session_id, replaced_message_ids: replaced_message_ids, summary_part: summary_part}

  defp build_tool_returned(session_id, message_id, part_id, {:ok, result}) do
    %ToolReturned{aggregate_id: session_id, message_id: message_id, part_id: part_id, result: result}
  end

  defp build_tool_returned(session_id, message_id, part_id, {:error, error}) do
    %ToolReturned{aggregate_id: session_id, message_id: message_id, part_id: part_id, error: error}
  end
end
```

- [x] **Step 4: Run event tests and format**

Run:

```bash
mix test apps/synapsis_core/test/synapsis/harness/event_test.exs
mix format apps/synapsis_core/lib/synapsis/harness/event.ex apps/synapsis_core/test/synapsis/harness/event_test.exs
```

Expected: tests pass and formatting changes only those files.

---

### Task 2: Pure Context Fold

**Files:**
- Create: `apps/synapsis_core/test/synapsis/harness/context_test.exs`
- Create: `apps/synapsis_core/lib/synapsis/harness/context.ex`

- [x] **Step 1: Write failing fold tests**

```elixir
defmodule Synapsis.Harness.ContextTest do
  use ExUnit.Case, async: true

  alias Synapsis.Harness.{Context, Event}

  test "folds session, messages, and parts in order" do
    events = [
      Event.session_created("session-1", project_id: "project-1"),
      Event.message_appended("session-1", %{id: "message-1", role: :user, ordinal: 0}),
      Event.part_appended("session-1", "message-1", %{id: "part-1", type: :text, ordinal: 0, data: %{content: "hello"}})
    ]

    context = Enum.reduce(events, Context.new(), &Context.apply_event/2)

    assert context.session_id == "session-1"
    assert context.project_id == "project-1"
    assert [%{id: "message-1", parts: [%{id: "part-1"}]}] = context.messages
  end

  test "updates a part by id" do
    context =
      Context.new()
      |> Context.apply_event(Event.session_created("session-1", project_id: "project-1"))
      |> Context.apply_event(Event.message_appended("session-1", %{id: "message-1", role: :assistant, ordinal: 0}))
      |> Context.apply_event(Event.part_appended("session-1", "message-1", %{id: "part-1", type: :tool, ordinal: 0, data: %{state: :pending}}))
      |> Context.apply_event(Event.part_updated("session-1", "message-1", "part-1", %{data: %{state: :running}}))

    assert [%{parts: [%{data: %{state: :running}}]}] = context.messages
  end

  test "permission and abort events update in-flight state" do
    context =
      Context.new()
      |> Context.apply_event(Event.session_created("session-1", project_id: "project-1"))
      |> Context.apply_event(Event.permission_requested("session-1", "request-1", "part-1", :write))
      |> Context.apply_event(Event.permission_denied("session-1", "request-1", :user_denied))
      |> Context.apply_event(Event.aborted("session-1", :user_requested))

    assert context.pending_permission == nil
    assert context.status == :aborted
  end
end
```

- [x] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
mix test apps/synapsis_core/test/synapsis/harness/context_test.exs
```

Expected: failure because `Synapsis.Harness.Context` does not exist.

- [x] **Step 3: Add the minimal fold implementation**

```elixir
defmodule Synapsis.Harness.Context do
  @moduledoc "Pure fold state for a harness session aggregate."

  alias Synapsis.Harness.Event

  defstruct [
    :session_id,
    :project_id,
    :parent_id,
    status: :new,
    metadata: %{},
    messages: [],
    pending_permission: nil,
    permissions: %{}
  ]

  def new(attrs \\ []) do
    struct!(__MODULE__, attrs)
  end

  def apply_event(%Event.SessionCreated{} = event, %__MODULE__{} = context), do: apply_event(context, event)

  def apply_event(%__MODULE__{} = context, %Event.SessionCreated{} = event) do
    %{context | session_id: event.aggregate_id, project_id: event.project_id, parent_id: event.parent_id, metadata: event.metadata, status: :idle}
  end

  def apply_event(%__MODULE__{} = context, %Event.MessageAppended{message: message}) do
    %{context | messages: context.messages ++ [Map.put_new(message, :parts, [])]}
  end

  def apply_event(%__MODULE__{} = context, %Event.PartAppended{message_id: message_id, part: part}) do
    update_message(context, message_id, fn message ->
      Map.update(message, :parts, [part], &(&1 ++ [part]))
    end)
  end

  def apply_event(%__MODULE__{} = context, %Event.PartUpdated{message_id: message_id, part_id: part_id, patch: patch}) do
    update_message(context, message_id, fn message ->
      parts =
        Enum.map(message.parts || [], fn
          %{id: ^part_id} = part -> deep_merge(part, patch)
          part -> part
        end)

      %{message | parts: parts}
    end)
  end

  def apply_event(%__MODULE__{} = context, %Event.PermissionRequested{} = event) do
    %{context | status: :awaiting_permission, pending_permission: %{request_id: event.request_id, part_id: event.part_id, effect_class: event.effect_class}}
  end

  def apply_event(%__MODULE__{} = context, %Event.PermissionGranted{request_id: request_id}) do
    %{context | pending_permission: nil, permissions: Map.put(context.permissions, request_id, :granted)}
  end

  def apply_event(%__MODULE__{} = context, %Event.PermissionDenied{request_id: request_id}) do
    %{context | pending_permission: nil, permissions: Map.put(context.permissions, request_id, :denied)}
  end

  def apply_event(%__MODULE__{} = context, %Event.Aborted{}) do
    %{context | status: :aborted, pending_permission: nil}
  end

  def apply_event(%__MODULE__{} = context, _event), do: context

  defp update_message(context, message_id, fun) do
    messages =
      Enum.map(context.messages, fn
        %{id: ^message_id} = message -> fun.(message)
        message -> message
      end)

    %{context | messages: messages}
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, lval, rval -> deep_merge(lval, rval) end)
  end

  defp deep_merge(_left, right), do: right
end
```

- [x] **Step 4: Run core harness tests**

Run:

```bash
mix test apps/synapsis_core/test/synapsis/harness
mix format apps/synapsis_core/lib/synapsis/harness apps/synapsis_core/test/synapsis/harness
```

Expected: event and context tests pass.

---

### Task 3: Durable Harness Event Schema

**Files:**
- Create: `apps/synapsis_data/priv/repo/migrations/20260512000001_create_harness_events.exs`
- Create: `apps/synapsis_data/lib/synapsis/harness_event.ex`
- Create: `apps/synapsis_data/lib/synapsis/harness_events.ex`
- Create: `apps/synapsis_data/test/synapsis/harness_events_test.exs`

- [x] **Step 1: Write failing data tests**

```elixir
defmodule Synapsis.HarnessEventsTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.{HarnessEvents, HarnessEvent}

  test "append assigns the next session version" do
    session_id = Ecto.UUID.generate()

    assert {:ok, %HarnessEvent{version: 1}} =
             HarnessEvents.append(session_id, "session_created", %{"project_id" => Ecto.UUID.generate()})

    assert {:ok, %HarnessEvent{version: 2}} =
             HarnessEvents.append(session_id, "message_appended", %{"message_id" => Ecto.UUID.generate()})
  end

  test "list_for_session returns events in version order" do
    session_id = Ecto.UUID.generate()

    {:ok, _} = HarnessEvents.append(session_id, "session_created", %{})
    {:ok, _} = HarnessEvents.append(session_id, "message_appended", %{})

    assert [%{version: 1}, %{version: 2}] = HarnessEvents.list_for_session(session_id)
  end
end
```

- [x] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
mix test apps/synapsis_data/test/synapsis/harness_events_test.exs
```

Expected: failure because the schema and context do not exist.

- [x] **Step 3: Add the migration**

```elixir
defmodule Synapsis.Repo.Migrations.CreateHarnessEvents do
  use Ecto.Migration

  def change do
    create table(:harness_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :aggregate_id, :binary_id, null: false
      add :version, :integer, null: false
      add :event_type, :text, null: false
      add :schema_version, :integer, null: false, default: 1
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:harness_events, [:aggregate_id, :version])
    create index(:harness_events, [:aggregate_id, :inserted_at])
    create index(:harness_events, [:event_type])
  end
end
```

- [x] **Step 4: Add schema and append/list API**

```elixir
defmodule Synapsis.HarnessEvent do
  @moduledoc "Durable event-log row for the harness session aggregate."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "harness_events" do
    field :aggregate_id, :binary_id
    field :version, :integer
    field :event_type, :string
    field :schema_version, :integer, default: 1
    field :payload, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:aggregate_id, :version, :event_type, :schema_version, :payload])
    |> validate_required([:aggregate_id, :version, :event_type, :schema_version, :payload])
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:schema_version, greater_than: 0)
    |> unique_constraint([:aggregate_id, :version], name: :harness_events_aggregate_id_version_index)
  end
end
```

```elixir
defmodule Synapsis.HarnessEvents do
  @moduledoc "Repo boundary for harness session events."

  import Ecto.Query
  alias Synapsis.{HarnessEvent, Repo}

  def append(aggregate_id, event_type, payload, opts \\ []) do
    schema_version = Keyword.get(opts, :schema_version, 1)

    Repo.transaction(fn ->
      version = next_version(aggregate_id)

      %HarnessEvent{}
      |> HarnessEvent.changeset(%{
        aggregate_id: aggregate_id,
        version: version,
        event_type: event_type,
        schema_version: schema_version,
        payload: payload
      })
      |> Repo.insert()
      |> case do
        {:ok, event} -> event
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def list_for_session(aggregate_id) do
    HarnessEvent
    |> where([e], e.aggregate_id == ^aggregate_id)
    |> order_by([e], asc: e.version)
    |> Repo.all()
  end

  defp next_version(aggregate_id) do
    query =
      from e in HarnessEvent,
        where: e.aggregate_id == ^aggregate_id,
        select: max(e.version)

    (Repo.one(query) || 0) + 1
  end
end
```

- [x] **Step 5: Run data event tests**

Run:

```bash
mix test apps/synapsis_data/test/synapsis/harness_events_test.exs
mix format apps/synapsis_data/priv/repo/migrations/20260512000001_create_harness_events.exs apps/synapsis_data/lib/synapsis/harness_event.ex apps/synapsis_data/lib/synapsis/harness_events.ex apps/synapsis_data/test/synapsis/harness_events_test.exs
```

Expected: data event tests pass after the test database migrates.

---

### Task 4: Row-Level Part Schema

**Files:**
- Create: `apps/synapsis_data/priv/repo/migrations/20260512000002_create_parts.exs`
- Create: `apps/synapsis_data/lib/synapsis/message_part.ex`
- Create: `apps/synapsis_data/test/synapsis/message_part_test.exs`

- [x] **Step 1: Write failing part schema tests**

```elixir
defmodule Synapsis.MessagePartTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.MessagePart

  test "changeset accepts a valid text part row" do
    changeset =
      MessagePart.changeset(%MessagePart{}, %{
        session_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        ordinal: 0,
        type: "text",
        data: %{"content" => "hello"}
      })

    assert changeset.valid?
  end

  test "changeset rejects unknown part type" do
    changeset =
      MessagePart.changeset(%MessagePart{}, %{
        session_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        ordinal: 0,
        type: "unknown",
        data: %{}
      })

    refute changeset.valid?
    assert {"is invalid", _} = changeset.errors[:type]
  end
end
```

- [x] **Step 2: Run focused test and confirm it fails**

Run:

```bash
mix test apps/synapsis_data/test/synapsis/message_part_test.exs
```

Expected: failure because `Synapsis.MessagePart` does not exist.

- [x] **Step 3: Add migration and schema**

```elixir
defmodule Synapsis.Repo.Migrations.CreateParts do
  use Ecto.Migration

  def change do
    create table(:parts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
      add :message_id, references(:messages, type: :binary_id, on_delete: :delete_all), null: false
      add :ordinal, :integer, null: false
      add :type, :text, null: false
      add :data, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:parts, [:message_id, :ordinal])
    create index(:parts, [:session_id, :inserted_at])
    create index(:parts, [:type])
  end
end
```

```elixir
defmodule Synapsis.MessagePart do
  @moduledoc "Row-level durable part projection for harness messages."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(text reasoning file tool agent step_start step_finish snapshot image)

  schema "parts" do
    belongs_to :session, Synapsis.Session
    belongs_to :message, Synapsis.Message

    field :ordinal, :integer
    field :type, :string
    field :data, :map, default: %{}
    field :deleted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(part, attrs) do
    part
    |> cast(attrs, [:session_id, :message_id, :ordinal, :type, :data, :deleted_at])
    |> validate_required([:session_id, :message_id, :ordinal, :type, :data])
    |> validate_number(:ordinal, greater_than_or_equal_to: 0)
    |> validate_inclusion(:type, @types)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:message_id)
    |> unique_constraint([:message_id, :ordinal], name: :parts_message_id_ordinal_index)
  end
end
```

- [x] **Step 4: Run part schema tests**

Run:

```bash
mix test apps/synapsis_data/test/synapsis/message_part_test.exs
mix format apps/synapsis_data/priv/repo/migrations/20260512000002_create_parts.exs apps/synapsis_data/lib/synapsis/message_part.ex apps/synapsis_data/test/synapsis/message_part_test.exs
```

Expected: tests pass.

---

### Task 5: Phase Exit Verification

**Files:**
- Modify: `docs/designs/synapsis-harness/phase-0-audit.md`

- [x] **Step 1: Add Phase 1 completion note to the audit doc**

Add a short section:

```markdown
## Phase 1 Exit Notes

Phase 1 adds pure harness events, a pure context fold, an additive
`harness_events` log, and an additive row-level `parts` projection. Existing
session runtime, API payloads, and embedded message parts remain unchanged.
```

- [x] **Step 2: Run scoped tests**

Run:

```bash
mix test apps/synapsis_core/test/synapsis/harness apps/synapsis_data/test/synapsis/harness_events_test.exs apps/synapsis_data/test/synapsis/message_part_test.exs
mix format --check-formatted apps/synapsis_core/lib/synapsis/harness apps/synapsis_core/test/synapsis/harness apps/synapsis_data/lib/synapsis/harness_event.ex apps/synapsis_data/lib/synapsis/harness_events.ex apps/synapsis_data/lib/synapsis/message_part.ex apps/synapsis_data/test/synapsis/harness_events_test.exs apps/synapsis_data/test/synapsis/message_part_test.exs
```

Expected: all scoped tests pass and formatting is clean.

- [x] **Step 3: Confirm no runtime surface changed**

Run:

```bash
git diff -- apps/synapsis_server apps/synapsis_web apps/synapsis_cli apps/synapsis_agent/lib/synapsis/session apps/synapsis_core/lib/synapsis/sessions.ex
```

Expected: no diff.
