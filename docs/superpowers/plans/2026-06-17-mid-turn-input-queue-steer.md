# Mid-Turn Input Queue And Steer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to submit input while a session is running. Normal Send while running queues a prompt for the next turn. A separate Steer action records advisory text for the current step and injects it before the next LLM request without interrupting active tools or streams.

**Architecture:** Add a Concord-backed, session-scoped pending input store in `synapsis_data`; keep `Synapsis.Session.Worker` as the only runtime policy authority; inject steer text transiently through graph context and `BuildPrompt`; expose a small core/server/channel/LiveView surface without changing provider payload contracts.

**Tech Stack:** Elixir umbrella, OTP `:gen_statem`, Concord session values, Phoenix controllers/channels, Phoenix LiveView, DuskMoon `dm_chat_input`, ExUnit, Graphify, GitNexus.

---

## Preconditions And Scope

- Worktree: `/home/gao/Workspace/gsmlg-opt/Synapsis/.trees/codex/mid-turn-input-queue-steer`
- Branch: `codex/mid-turn-input-queue-steer`
- Baseline scoped tests passed before planning:
  - `devenv shell mix test apps/synapsis_agent/test/synapsis/session/worker_test.exs apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs apps/synapsis_server/test/synapsis_server/router_test.exs`
- GitNexus file-level impact checks were LOW for the worker, sessions facade, prompt builder, controller, channel, and LiveView session files.
- Existing unrelated dirty files in the main worktree are intentionally not touched. This work happens in the isolated worktree.
- If implementation touches any additional symbol or file beyond this plan, run GitNexus impact for that target before editing it.

## Behavioral Contract

- Send while `idle` or `error`: existing behavior, start the next turn immediately.
- Send while `streaming`, `tool_executing`, `awaiting_approval`, `busy`, or query-loop running: store a FIFO pending prompt and return success.
- Queued prompts become real durable user messages only when they are about to run. This preserves transcript order.
- When a turn finishes, the worker starts the next queued prompt automatically.
- Steer while running: store advisory text for the current turn, return success, and inject all queued steer text into the next `BuildPrompt` request made by that running turn.
- Steer outside graph-running states: reject with `:no_active_turn`; the UI hides steer while idle and normal Send remains the way to start or queue durable prompts.
- Cancel: cancel current stream/tools as today, cancel queued steers for the interrupted turn, and preserve queued normal prompts.
- Retry/regenerate: keep existing behavior; do not consume queued prompts until the regenerated turn reaches its normal boundary.
- Session delete: existing `Session.Store.delete_session/1` removes pending inputs through the session prefix.

---

## Task 1: Add Pending Input Store Tests

- [ ] Create `apps/synapsis_data/test/synapsis/session/pending_input_store_test.exs`.
- [ ] Cover FIFO prompt storage, text-only steer storage, status transitions, session isolation, queue limit, and inflight recovery.
- [ ] Run the test file and confirm it fails because the module does not exist yet.

Test skeleton:

```elixir
defmodule Synapsis.Session.PendingInputStoreTest do
  use Synapsis.DataCase, async: false

  alias Synapsis.Session.PendingInputStore

  setup do
    session_id = Ecto.UUID.generate()

    on_exit(fn ->
      Synapsis.Session.Store.delete_session(session_id)
    end)

    {:ok, session_id: session_id}
  end

  test "stores queued prompts in FIFO order", %{session_id: session_id} do
    assert {:ok, first} = PendingInputStore.append_prompt(session_id, "first", [])
    assert {:ok, second} = PendingInputStore.append_prompt(session_id, "second", [])

    assert first.kind == "prompt"
    assert second.kind == "prompt"
    assert Enum.map(PendingInputStore.queued_prompts(session_id), & &1.content) == ["first", "second"]
  end

  test "stores steers separately from prompts", %{session_id: session_id} do
    assert {:ok, prompt} = PendingInputStore.append_prompt(session_id, "next turn", [])
    assert {:ok, steer} = PendingInputStore.append_steer(session_id, "use the current file")

    assert prompt.kind == "prompt"
    assert steer.kind == "steer"
    assert Enum.map(PendingInputStore.queued_prompts(session_id), & &1.content) == ["next turn"]
    assert Enum.map(PendingInputStore.queued_steers(session_id), & &1.content) == ["use the current file"]
  end

  test "takes and consumes the next prompt", %{session_id: session_id} do
    assert {:ok, input} = PendingInputStore.append_prompt(session_id, "queued", [])
    assert {:ok, ^input} = PendingInputStore.take_next_prompt(session_id)
    assert PendingInputStore.queued_prompts(session_id) == []

    assert :ok = PendingInputStore.mark_consumed(session_id, input.id)
    assert [%{status: "consumed"}] = PendingInputStore.list(session_id)
  end

  test "recovers inflight prompts after worker restart", %{session_id: session_id} do
    assert {:ok, input} = PendingInputStore.append_prompt(session_id, "queued", [])
    assert {:ok, ^input} = PendingInputStore.take_next_prompt(session_id)
    assert :ok = PendingInputStore.recover_inflight(session_id)

    assert [%{id: id, status: "queued"}] = PendingInputStore.queued_prompts(session_id)
    assert id == input.id
  end

  test "cancels queued steers without cancelling prompts", %{session_id: session_id} do
    assert {:ok, _prompt} = PendingInputStore.append_prompt(session_id, "next turn", [])
    assert {:ok, steer} = PendingInputStore.append_steer(session_id, "now")

    assert :ok = PendingInputStore.cancel_steers(session_id)

    assert [%{content: "next turn"}] = PendingInputStore.queued_prompts(session_id)
    assert [%{id: id, status: "cancelled"}] = PendingInputStore.list(session_id) |> Enum.filter(&(&1.kind == "steer"))
    assert id == steer.id
  end

  test "enforces a pending input limit", %{session_id: session_id} do
    for index <- 1..25 do
      assert {:ok, _} = PendingInputStore.append_prompt(session_id, "prompt #{index}", [])
    end

    assert {:error, :queue_full} = PendingInputStore.append_prompt(session_id, "too many", [])
  end
end
```

Verify:

```sh
devenv shell mix test apps/synapsis_data/test/synapsis/session/pending_input_store_test.exs
```

## Task 2: Implement Concord-Backed Pending Input Store

- [ ] Add `apps/synapsis_data/lib/synapsis/session/pending_input_store.ex`.
- [ ] Store data under `sessions/<id>/pending_inputs` through `Synapsis.Session.Store.put_value/3` and `get_value/3`.
- [ ] Use strings for stored `kind` and `status` values to avoid atom creation from persisted data.
- [ ] Use FIFO insertion order by `inserted_at`.

Implementation:

```elixir
defmodule Synapsis.Session.PendingInputStore do
  @moduledoc """
  Concord-backed pending inputs for mid-turn Send and Steer.

  The session worker is the only runtime writer for a session, so this module
  keeps the data model simple and process-free.
  """

  alias Synapsis.Session.Store

  @suffix "pending_inputs"
  @max_pending 25

  @type input :: %{
          required(:id) => String.t(),
          required(:session_id) => String.t(),
          required(:kind) => String.t(),
          required(:status) => String.t(),
          required(:content) => String.t(),
          required(:image_parts) => list(),
          required(:inserted_at) => String.t(),
          optional(:updated_at) => String.t()
        }

  @spec list(String.t()) :: [input()]
  def list(session_id) when is_binary(session_id) do
    session_id
    |> Store.get_value(@suffix, [])
    |> Enum.map(&normalize/1)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  @spec queued_prompts(String.t()) :: [input()]
  def queued_prompts(session_id), do: queued(session_id, "prompt")

  @spec queued_steers(String.t()) :: [input()]
  def queued_steers(session_id), do: queued(session_id, "steer")

  @spec append_prompt(String.t(), String.t(), list()) :: {:ok, input()} | {:error, :queue_full}
  def append_prompt(session_id, content, image_parts) when is_binary(content) and is_list(image_parts) do
    append(session_id, "prompt", content, image_parts)
  end

  @spec append_steer(String.t(), String.t()) :: {:ok, input()} | {:error, :queue_full}
  def append_steer(session_id, content) when is_binary(content) do
    append(session_id, "steer", content, [])
  end

  @spec take_next_prompt(String.t()) :: {:ok, input()} | :empty | {:error, term()}
  def take_next_prompt(session_id) do
    inputs = list(session_id)

    case Enum.find(inputs, &(&1.kind == "prompt" and &1.status == "queued")) do
      nil ->
        :empty

      input ->
        updated = replace(inputs, %{input | status: "inflight", updated_at: timestamp()})

        with :ok <- Store.put_value(session_id, @suffix, updated) do
          {:ok, input}
        end
    end
  end

  @spec take_queued_steers(String.t()) :: [input()]
  def take_queued_steers(session_id) do
    inputs = list(session_id)
    steers = Enum.filter(inputs, &(&1.kind == "steer" and &1.status == "queued"))
    ids = MapSet.new(Enum.map(steers, & &1.id))

    updated =
      Enum.map(inputs, fn input ->
        if MapSet.member?(ids, input.id) do
          %{input | status: "inflight", updated_at: timestamp()}
        else
          input
        end
      end)

    if steers != [] do
      :ok = Store.put_value(session_id, @suffix, updated)
    end

    steers
  end

  @spec mark_consumed(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_consumed(session_id, input_id), do: mark(session_id, input_id, "consumed")

  @spec cancel_steers(String.t()) :: :ok | {:error, term()}
  def cancel_steers(session_id) do
    inputs = list(session_id)

    updated =
      Enum.map(inputs, fn input ->
        if input.kind == "steer" and input.status in ["queued", "inflight"] do
          %{input | status: "cancelled", updated_at: timestamp()}
        else
          input
        end
      end)

    Store.put_value(session_id, @suffix, updated)
  end

  @spec recover_inflight(String.t()) :: :ok | {:error, term()}
  def recover_inflight(session_id) do
    inputs = list(session_id)

    updated =
      Enum.map(inputs, fn
        %{status: "inflight"} = input -> %{input | status: "queued", updated_at: timestamp()}
        input -> input
      end)

    Store.put_value(session_id, @suffix, updated)
  end

  defp append(session_id, kind, content, image_parts) do
    inputs = list(session_id)
    pending_count = Enum.count(inputs, &(&1.status in ["queued", "inflight"]))

    if pending_count >= @max_pending do
      {:error, :queue_full}
    else
      input = %{
        id: Ecto.UUID.generate(),
        session_id: session_id,
        kind: kind,
        status: "queued",
        content: content,
        image_parts: image_parts,
        inserted_at: timestamp()
      }

      with :ok <- Store.put_value(session_id, @suffix, inputs ++ [input]) do
        {:ok, input}
      end
    end
  end

  defp queued(session_id, kind) do
    Enum.filter(list(session_id), &(&1.kind == kind and &1.status == "queued"))
  end

  defp mark(session_id, input_id, status) do
    inputs = list(session_id)

    inputs
    |> Enum.map(fn input ->
      if input.id == input_id do
        %{input | status: status, updated_at: timestamp()}
      else
        input
      end
    end)
    |> then(&Store.put_value(session_id, @suffix, &1))
  end

  defp replace(inputs, updated_input) do
    Enum.map(inputs, fn
      %{id: id} when id == updated_input.id -> updated_input
      input -> input
    end)
  end

  defp normalize(input) when is_map(input) do
    input
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.update(:image_parts, [], &List.wrap/1)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
```

Verify:

```sh
devenv shell mix test apps/synapsis_data/test/synapsis/session/pending_input_store_test.exs
```

## Task 3: Add Worker Queue And Steer Policy Tests

- [ ] Update `apps/synapsis_agent/test/synapsis/session/worker_test.exs`.
- [ ] Replace the current busy-prompt rejection test with a queue assertion.
- [ ] Add steer assertions for running and idle states.
- [ ] Add cancel assertion that queued prompt remains but steer is cancelled.

Key test cases:

```elixir
test "send_message queues outside :idle in graph mode" do
  session = persist_session(%{status: "streaming"})
  {:ok, graph} = CodingLoop.build()

  data = %Worker{
    session_id: session.id,
    session: session,
    graph: graph,
    engine_node: :llm_stream,
    engine_state: CodingLoop.initial_state(%{session_id: session.id}),
    engine_ctx: %{},
    epoch: System.monotonic_time(),
    execution_mode: :graph,
    stream_ref: make_ref()
  }

  from = {self(), make_ref()}

  assert {:next_state, :generating, _new_data, actions} =
           Worker.handle_event({:call, from}, {:send_message, "queued", []}, :generating, data)

  assert {:reply, ^from, :ok} = Enum.find(actions, &match?({:reply, ^from, :ok}, &1))
  assert [%{content: "queued", status: "queued"}] = Synapsis.Session.PendingInputStore.queued_prompts(session.id)
end

test "steer_message stores advisory text while graph is running" do
  session = persist_session(%{status: "streaming"})
  {:ok, graph} = CodingLoop.build()

  data = %Worker{
    session_id: session.id,
    session: session,
    graph: graph,
    engine_node: :tool_execute,
    engine_state: CodingLoop.initial_state(%{session_id: session.id}),
    engine_ctx: %{},
    epoch: System.monotonic_time(),
    execution_mode: :graph,
    pending_tool_count: 1
  }

  from = {self(), make_ref()}

  assert {:next_state, :executing_tools, _new_data, actions} =
           Worker.handle_event({:call, from}, {:steer_message, "prefer small patch"}, :executing_tools, data)

  assert {:reply, ^from, :ok} = Enum.find(actions, &match?({:reply, ^from, :ok}, &1))
  assert [%{content: "prefer small patch", status: "queued"}] = Synapsis.Session.PendingInputStore.queued_steers(session.id)
end
```

Verify expected red:

```sh
devenv shell mix test apps/synapsis_agent/test/synapsis/session/worker_test.exs
```

## Task 4: Implement Worker Queue And Steer Policy

- [ ] Edit `apps/synapsis_agent/lib/synapsis/session/worker.ex`.
- [ ] Add `Synapsis.Session.PendingInputStore` alias.
- [ ] Add public `steer_message/2`.
- [ ] Recover inflight pending inputs during boot.
- [ ] Queue normal sends in non-idle states.
- [ ] Start the next queued prompt when the graph is parked at `:receive`.
- [ ] Cancel queued steers on cancel while preserving queued prompts.

Required public API addition:

```elixir
def steer_message(session_id, content),
  do: :gen_statem.call(via(session_id), {:steer_message, content}, 30_000)
```

Required boot addition after successful `Boot.load_and_boot/1`:

```elixir
:ok = Synapsis.Session.PendingInputStore.recover_inflight(session.id)
```

Required send policy shape:

```elixir
def handle_event({:call, from}, {:send_message, content, image_parts}, state, data) do
  case {data.execution_mode, state} do
    {:query_loop, :query_loop} ->
      reply_queue_result(data, from, Synapsis.Session.PendingInputStore.append_prompt(data.session_id, content, image_parts))

    {:query_loop, _} ->
      case persist_user_message(data, content, image_parts) do
        :ok -> advance(start_query_loop(content, data), [{:reply, from, :ok}])
        {:error, reason} -> keep(data, [{:reply, from, {:error, reason}}])
      end

    {:graph, :idle} ->
      start_graph_turn(data, content, image_parts, [{:reply, from, :ok}])

    {:graph, _busy} ->
      reply_queue_result(data, from, Synapsis.Session.PendingInputStore.append_prompt(data.session_id, content, image_parts))
  end
end
```

Required steer policy shape:

```elixir
def handle_event({:call, from}, {:steer_message, content}, state, data) do
  case {data.execution_mode, state} do
    {:graph, :idle} ->
      keep(data, [{:reply, from, {:error, :no_active_turn}}])

    {:graph, _busy} ->
      reply_queue_result(data, from, Synapsis.Session.PendingInputStore.append_steer(data.session_id, content))

    {:query_loop, _} ->
      keep(data, [{:reply, from, {:error, :no_active_turn}}])
  end
end
```

Required helper shape:

```elixir
defp start_graph_turn(data, content, image_parts, actions) do
  case persist_user_message(data, content, image_parts) do
    :ok ->
      new_engine_ctx =
        data.engine_ctx
        |> Map.put(:user_input, content)
        |> Map.put(:image_parts, image_parts)

      data =
        data
        |> Map.put(:engine_ctx, new_engine_ctx)
        |> Map.put(:executed_tool_ids, MapSet.new())
        |> step_engine()
        |> maybe_start_next_prompt()

      advance(data, actions)

    {:error, reason} ->
      keep(data, replace_reply(actions, {:error, reason}))
  end
end

defp reply_queue_result(data, from, {:ok, input}) do
  Persistence.broadcast(data.session_id, "input_queued", %{
    id: input.id,
    kind: input.kind,
    content: input.content
  })

  keep(data, [{:reply, from, :ok}])
end

defp reply_queue_result(data, from, {:error, reason}) do
  keep(data, [{:reply, from, {:error, reason}}])
end
```

Required drain helper:

```elixir
defp maybe_start_next_prompt(%__MODULE__{} = data) do
  if engine_ready?(data) do
    case Synapsis.Session.PendingInputStore.take_next_prompt(data.session_id) do
      {:ok, input} ->
        case persist_user_message(data, input.content, input.image_parts) do
          :ok ->
            :ok = Synapsis.Session.PendingInputStore.mark_consumed(data.session_id, input.id)

            Persistence.broadcast(data.session_id, "input_started", %{
              id: input.id,
              kind: input.kind,
              content: input.content
            })

            data
            |> Map.put(:engine_ctx, %{user_input: input.content, image_parts: input.image_parts})
            |> Map.put(:executed_tool_ids, MapSet.new())
            |> step_engine()

          {:error, reason} ->
            Logger.warning("queued_prompt_start_failed", session_id: data.session_id, reason: inspect(reason))
            data
        end

      :empty ->
        data

      {:error, reason} ->
        Logger.warning("queued_prompt_take_failed", session_id: data.session_id, reason: inspect(reason))
        data
    end
  else
    data
  end
end
```

Implementation note: call `maybe_start_next_prompt/1` from the `{:done, _}` branch of `step_engine/1` and from any branch that parks the graph at `:receive`. Do not call it when `stream_ref`, `pending_tool_count`, or approval state is active.

Verify:

```sh
devenv shell mix test apps/synapsis_agent/test/synapsis/session/worker_test.exs
```

## Task 5: Add Steer Injection Tests

- [ ] Add `apps/synapsis_agent/test/synapsis/agent/nodes/build_prompt_test.exs`.
- [ ] Persist a session and one user message.
- [ ] Append steer text through `PendingInputStore`.
- [ ] Run `Synapsis.Agent.Nodes.BuildPrompt.run/2`.
- [ ] Assert the built request system prompt contains the steer block.
- [ ] Assert steer inputs are marked consumed.

Test shape:

```elixir
defmodule Synapsis.Agent.Nodes.BuildPromptTest do
  use Synapsis.Agent.DataCase, async: false

  alias Synapsis.Agent.Nodes.BuildPrompt
  alias Synapsis.Session.PendingInputStore
  alias Synapsis.{Message, Part, Session}

  test "injects queued steer text into the next LLM request" do
    session =
      %Session{}
      |> Session.changeset(%{provider: "anthropic", model: "test-model", agent: "main"})
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:id, Ecto.UUID.generate())

    :ok = Session.Store.put_meta(session.id, Session.to_meta(session))
    {:ok, _message} = Message.append(session.id, %Message{role: "user", parts: [%Part.Text{content: "fix it"}]})
    {:ok, steer} = PendingInputStore.append_steer(session.id, "focus on the current failing test")

    state = %{
      session_id: session.id,
      agent_config: %{provider: "anthropic", name: "main", model: "test-model"}
    }

    assert {:next, :default, new_state} = BuildPrompt.run(state, %{})
    assert new_state.request.system =~ "Mid-turn user guidance"
    assert new_state.request.system =~ "focus on the current failing test"
    assert [%{id: id, status: "consumed"}] = PendingInputStore.list(session.id) |> Enum.filter(&(&1.kind == "steer"))
    assert id == steer.id
  end
end
```

Verify expected red:

```sh
devenv shell mix test apps/synapsis_agent/test/synapsis/agent/nodes/build_prompt_test.exs
```

## Task 6: Implement Steer Injection In BuildPrompt

- [ ] Edit `apps/synapsis_agent/lib/synapsis/agent/nodes/build_prompt.ex`.
- [ ] Read queued steers immediately before the request is built.
- [ ] Append steer guidance to the system prompt only, not to durable messages.
- [ ] Mark steers consumed after request construction succeeds.

Required helper:

```elixir
defp append_steer_context(prompt, session_id) do
  steers = Synapsis.Session.PendingInputStore.queued_steers(session_id)

  case steers do
    [] ->
      {prompt, []}

    [_ | _] ->
      steer_text =
        steers
        |> Enum.map(&String.trim(&1.content))
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      block = """

      Mid-turn user guidance:
      #{steer_text}
      """

      {prompt <> block, steers}
  end
end

defp mark_steers_consumed(session_id, steers) do
  Enum.each(steers, fn steer ->
    :ok = Synapsis.Session.PendingInputStore.mark_consumed(session_id, steer.id)
  end)
end
```

Required integration in `run/2`:

```elixir
{full_prompt, consumed_steers} = append_steer_context(full_prompt, session_id)
enriched_config = Map.put(agent_config, :system_prompt, full_prompt)

request =
  Synapsis.MessageBuilder.build_request(
    messages,
    enriched_config,
    provider
  )

mark_steers_consumed(session_id, consumed_steers)
```

Verify:

```sh
devenv shell mix test apps/synapsis_agent/test/synapsis/agent/nodes/build_prompt_test.exs apps/synapsis_agent/test/synapsis/session/worker_test.exs
```

## Task 7: Add Core, HTTP, And Channel API Tests

- [ ] Update `apps/synapsis_core/test` if a sessions facade test exists; otherwise cover through server and worker tests.
- [ ] Update `apps/synapsis_server/test/synapsis_server/router_test.exs` with `POST /api/sessions/:id/steer`.
- [ ] Update `apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs` with steer validation.
- [ ] Add channel tests if there is an existing channel test file; otherwise add a small one under `apps/synapsis_server/test/synapsis_server/channels/session_channel_test.exs`.

Router assertion:

```elixir
test "routes POST /api/sessions/:id/steer" do
  assert %{plug: SynapsisServer.SessionController, plug_opts: :steer} =
           Phoenix.Router.route_info(SynapsisServer.Router, "POST", "/api/sessions/session-1/steer", "")
end
```

Controller validation cases:

```elixir
test "steer requires content", %{conn: conn} do
  conn = post(conn, ~p"/api/sessions/session-1/steer", %{})
  assert json_response(conn, 400)["error"] == "content is required"
end

test "steer rejects non-string content", %{conn: conn} do
  conn = post(conn, ~p"/api/sessions/session-1/steer", %{content: 123})
  assert json_response(conn, 400)["error"] == "content must be a string"
end
```

Verify expected red:

```sh
devenv shell mix test apps/synapsis_server/test/synapsis_server/router_test.exs apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs
```

## Task 8: Implement Core, HTTP, And Channel API

- [ ] Edit `apps/synapsis_core/lib/synapsis/sessions.ex`.
- [ ] Edit `apps/synapsis_server/lib/synapsis_server/router.ex`.
- [ ] Edit `apps/synapsis_server/lib/synapsis_server/controllers/session_controller.ex`.
- [ ] Edit `apps/synapsis_server/lib/synapsis_server/channels/session_channel.ex`.

Core facade:

```elixir
def steer_message(session_id, content) when is_binary(content) do
  ensure_session_running(session_id)
  Synapsis.Session.Worker.steer_message(session_id, content)
catch
  :exit, reason -> {:error, exit_reason(reason)}
end
```

Router route:

```elixir
post "/sessions/:id/steer", SessionController, :steer
```

Controller action:

```elixir
def steer(conn, %{"id" => id, "content" => content}) do
  cond do
    not is_binary(content) ->
      conn |> put_status(400) |> json(%{error: "content must be a string"})

    byte_size(content) > @max_content_bytes ->
      conn |> put_status(413) |> json(%{error: "content too large"})

    true ->
      case Sessions.steer_message(id, content) do
        :ok -> json(conn, %{status: "ok"})
        {:error, reason} -> conn |> put_status(422) |> json(%{error: format_error(reason)})
      end
  end
end

def steer(conn, %{"id" => _}) do
  conn |> put_status(400) |> json(%{error: "content is required"})
end
```

Channel handler:

```elixir
def handle_in("session:steer", %{"content" => content}, socket) do
  cond do
    not is_binary(content) ->
      {:reply, {:error, %{error: "content must be a string"}}, socket}

    byte_size(content) > @max_content_bytes ->
      {:reply, {:error, %{error: "content too large"}}, socket}

    true ->
      case Synapsis.Sessions.steer_message(socket.assigns.session_id, content) do
        :ok -> {:reply, {:ok, %{status: "ok"}}, socket}
        {:error, reason} -> {:reply, {:error, %{error: format_error(reason)}}, socket}
      end
  end
end
```

Verify:

```sh
devenv shell mix test apps/synapsis_server/test/synapsis_server/router_test.exs apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs
```

## Task 9: Add LiveView Tests

- [ ] Update `apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs`.
- [ ] Assert the chat input is enabled while streaming/tool-executing.
- [ ] Assert a quick action or steer action exists while running.
- [ ] Assert normal send while running keeps a transient queued bubble.
- [ ] Assert steer while running does not append a durable user bubble.

Test intent:

```elixir
test "chat input remains enabled while session is running", %{conn: conn} do
  session = create_running_session()

  {:ok, view, html} = live(conn, ~p"/agent/agents/main/sessions/#{session.id}")

  assert html =~ "duskmoon-send-send=\"send_message\""
  refute html =~ "disabled=\"disabled\""
  assert render(view) =~ "duskmoon-send-quick-action=\"steer_message\""
end
```

If the exact disabled markup differs, assert through `element/2` and rendered content rather than string matching.

Verify expected red:

```sh
devenv shell mix test apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs
```

## Task 10: Implement LiveView UI

- [ ] Edit `apps/synapsis_web/lib/synapsis_web/live/agent_live/sessions.ex`.
- [ ] Add `queued_inputs: []` to assigns on mount/session changes.
- [ ] Add `handle_event/3` clauses for `"steer_message"`.
- [ ] Keep the main input enabled for running statuses.
- [ ] Add `duskmoon-send-quick-action="steer_message"` to `dm_chat_input`.
- [ ] Render queued prompt bubbles separately from durable `@messages`.
- [ ] Clear queued prompt bubbles on `"input_started"` PubSub events and on full session reloads.
- [ ] Do not render steer text as a chat bubble; it is advisory control input.

Chat input change:

```elixir
<.dm_chat_input
  id="message-input"
  name="content"
  value=""
  placeholder={if(@session_status in ~w(idle error), do: "Send a message (Ctrl/Cmd+Enter)", else: "Queue a message or steer the running step")}
  disabled={false}
  send_label={if(@session_status in ~w(idle error), do: "Send", else: "Queue")}
  clear_on_send
  duskmoon-send-send="send_message"
  duskmoon-send-quick-action="steer_message"
  class="synapsis-chat-input w-full"
/>
```

Steer handler:

```elixir
def handle_event("steer_message", %{"value" => content}, socket) do
  steer_message(content, socket)
end

def handle_event("steer_message", %{"content" => content}, socket) do
  steer_message(content, socket)
end
```

Queue UI event handlers:

```elixir
def handle_info({"input_queued", %{id: id, kind: "prompt", content: content}}, socket) do
  queued = %{id: id, kind: "prompt", content: content}
  {:noreply, update(socket, :queued_inputs, &append_unique_input(&1, queued))}
end

def handle_info({"input_queued", %{kind: "steer"}}, socket) do
  {:noreply, socket}
end

def handle_info({"input_started", %{id: id}}, socket) do
  {:noreply, update(socket, :queued_inputs, &Enum.reject(&1, fn input -> input.id == id end))}
end
```

Verify:

```sh
devenv shell mix test apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs
```

## Task 11: Update Architecture Docs

- [ ] Update `docs/decisions/ADR-006-in-process-sessions-and-concord-storage.md`.
- [ ] Update `docs/decisions/ADR-008-gen-statem-session-shell.md`.
- [ ] Document pending input persistence, queue semantics, steer semantics, and cancellation behavior.

Use this command to verify the ADR links still resolve from architecture docs:

```sh
rg -n "ADR-006|ADR-008|session persistence|session worker" docs/architecture docs/guardrails docs/decisions
```

Verify:

```sh
devenv shell mix format --check-formatted
```

## Task 12: Final Verification

- [ ] Run focused tests:

```sh
devenv shell mix test apps/synapsis_data/test/synapsis/session/pending_input_store_test.exs apps/synapsis_agent/test/synapsis/agent/nodes/build_prompt_test.exs apps/synapsis_agent/test/synapsis/session/worker_test.exs apps/synapsis_server/test/synapsis_server/router_test.exs apps/synapsis_server/test/synapsis_server/controllers/session_controller_test.exs apps/synapsis_web/test/synapsis_web/live/agent_live/sessions_test.exs
```

- [ ] Run formatting:

```sh
devenv shell mix format --check-formatted
```

- [ ] Run Graphify update after code/doc changes:

```sh
graphify update .
```

- [ ] Run GitNexus change detection before any commit:

```sh
npx gitnexus detect-changes
```

- [ ] Review `git status --short` and ensure only expected implementation files are changed, excluding unrelated pre-existing `AGENTS.md` and `CLAUDE.md` modifications.

---

## Self-Review

- Spec coverage: send queue, explicit steer, advisory non-interrupting injection, cancel behavior, restart recovery, API/channel/UI are all covered.
- Boundary check: persistence lives in `synapsis_data`; runtime policy lives in `synapsis_agent`; public facades live in core/server/web; provider adapters are not touched.
- Transcript order: queued prompts are not persisted as messages until the worker starts them.
- Task concreteness: this plan contains concrete file paths, test targets, and code shapes for every implementation area.
- Risk: the only accepted durability weakness is at-least-once queued prompt startup around a worker crash between message persistence and queue consumption. Inflight recovery prevents silent loss; duplicate delivery in that narrow crash window is safer than dropping user input.
