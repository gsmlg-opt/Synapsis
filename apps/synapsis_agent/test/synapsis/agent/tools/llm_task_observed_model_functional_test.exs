defmodule Synapsis.Agent.Tools.LLMTaskObservedModelFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.Runtime.{RunInventory, Store}
  alias Synapsis.Agent.Tools.LLMTask.{Completion, Request, Result}
  alias Synapsis.Runtime.Store, as: Journal

  @moduletag timeout: 60_000
  @requested "requested-completion-alias"
  @first_model "provider-observed-first"
  @final_model "provider-observed-final"
  @raw "{\"answer\":7}"
  @expected %{"answer" => 7}
  @usage %{input_tokens: 20, cached_tokens: 6, output_tokens: 8, reasoning_tokens: 3}
  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  defmodule ParentProvider do
    def stream(request, %{observer: observer}) do
      send(observer, {:observed_model_parent_request, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Hooks do
    def tool_effect_timeout(_invocation, _context), do: {:ok, 20_000}
  end

  defmodule Backend do
    def execute(operation) do
      context = operation.backend_context
      send(context.observer, {:observed_model_operation, operation})

      with {:ok, completion} <-
             Completion.run(context.request, Map.put(context, :operation, operation)),
           {:ok, presented} <- Result.present(completion.value, completion.observed_metadata) do
        {:ok, Map.put(presented, :completion, completion)}
      end
    end
  end

  test "observed model crosses canonical HTTP, committed child history and parent tool result" do
    assert :ok = Synapsis.Session.Store.ensure_started()
    session_id = Ecto.UUID.generate()
    run_id = Ecto.UUID.generate()
    assert {:ok, store} = Store.new(1)
    on_exit(fn -> cleanup_journal(session_id, store.namespace) end)
    observer = self()
    fixture = Gaoxy.Test.open()

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/chat/completions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(observer, {:observed_model_child_http_request, Jason.decode!(body), self()})

      receive do
        :respond ->
          chunks = [
            %{
              "model" => @first_model,
              "choices" => [
                %{"index" => 0, "delta" => %{"content" => @raw}, "finish_reason" => "stop"}
              ]
            },
            %{
              "model" => @final_model,
              "choices" => [],
              "usage" => %{
                "prompt_tokens" => 20,
                "prompt_tokens_details" => %{"cached_tokens" => 6},
                "completion_tokens" => 8,
                "completion_tokens_details" => %{"reasoning_tokens" => 3},
                "total_tokens" => 28
              }
            }
          ]

          body =
            Enum.map_join(chunks, "", &("data: " <> Jason.encode!(&1) <> "\n\n")) <>
              "data: [DONE]\n\n"

          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.resp(200, body)
      end
    end)

    session = start_supervised!({Session, owner_pid: self(), cleanup_timeout: 5_000})

    authority = %{
      caller: "llm-observed-model-fixture",
      run_id: run_id,
      grants: ["fixture_completion"],
      tool_revisions: %{"fixture_completion" => 1}
    }

    assert {:ok, binding} = Session.bind(session, authority)

    resolved = %{
      timeout_ms: 15_000,
      output_limit: 65_536,
      provider_context: %{
        provider_config: %{
          type: "openai",
          base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
          api_key: "fixture"
        },
        request_options: %{model: @requested, max_tokens: 128}
      }
    }

    assert {:ok, request} =
             Request.prepare(
               %{
                 "prompt" => "Summarize the supplied input as JSON.",
                 "input" => %{"value" => 7},
                 "schema" => @schema
               },
               resolved
             )

    context = %{
      observer: self(),
      session_binding: binding,
      session_id: session_id,
      store: store,
      caller: authority.caller,
      request: request
    }

    descriptor = %{
      tool_name: "fixture_completion",
      tool_revision: 1,
      backend: Backend,
      backend_context: context,
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      safety: %{read_only: false, retry_safe: false, parallel_safe: false}
    }

    assert {:ok, registry} = ToolRegistry.register(%ToolRegistry{}, descriptor)

    parent =
      start_supervised!(
        {Conversation,
         run_id: run_id,
         incarnation: 1,
         store: Store,
         context: store,
         provider: ParentProvider,
         provider_context: %{observer: self()},
         subscriber: self(),
         registry: registry,
         authority: authority,
         schema_admission: :strict,
         hooks: Hooks,
         session_binding: binding,
         work: 3,
         run_timeout: 30_000,
         effect_timeout: 20_000,
         commit_timeout: 5_000,
         cleanup_timeout: 5_000}
      )

    assert {:ok, _} = Conversation.prompt(parent, "Run the isolated JSON completion")
    assert_receive {:observed_model_parent_request, %{run_id: ^run_id}, provider}, 5_000

    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{id: "observed-model-call", name: "fixture_completion", arguments: %{}}
         },
         parent_response("")
       ]}
    )

    assert_receive {:observed_model_operation, operation}, 5_000
    assert_receive {:observed_model_child_http_request, wire, fixture_pid}, 5_000
    assert wire["model"] == @requested
    assert wire["tools"] in [nil, []]
    assert {:ok, [locator]} = Journal.list_facts(session_id, :run_locator)
    assert locator.kind == :llm_task
    assert locator.parent_run_id == run_id
    assert locator.parent_invocation_id == operation.invocation_id

    assert {:ok, [%{id: resource_id, kind: :resource, status: :active}]} =
             ResourceRegistry.owner_status(binding.resource_registry, binding.owner_id)

    handle = %{
      resource_id: resource_id,
      owner_id: binding.owner_id,
      incarnation: binding.incarnation,
      kind: :llm_task
    }

    assert {:ok, child} =
             ResourceRegistry.fetch(binding.resource_registry, handle, binding.owner_id)

    child_ref = Process.monitor(child)
    send(fixture_pid, :respond)

    assert_receive {:observed_model_parent_request, next_request, next_provider}, 10_000
    assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}, 5_000
    assert {:ok, []} = ResourceRegistry.owner_status(binding.resource_registry, binding.owner_id)

    [result] =
      for %{role: :tool, tool_call_id: "observed-model-call", result: result} <-
            next_request.messages,
          do: result

    assert result.is_error == false
    assert result.completion.value == @expected
    assert result.completion.text == @raw
    assert result.completion.locator == locator
    assert result.completion.usage == @usage
    assert result.completion.observed_metadata == %{model: @final_model}
    assert result.details == %{json: @expected, model: @final_model}
    assert Jason.decode!(result.content) == @expected

    assert {:ok, aggregate} = Journal.load(locator.namespace, locator.run_id)
    assert aggregate.run.state == :completed
    assert aggregate.run.incarnation == locator.incarnation
    assert aggregate.revision == aggregate.run.expected_revision

    assert List.last(aggregate.run.context.conversation.messages) == %{
             role: :assistant,
             content: [%{type: :text, text: @raw}],
             model: @final_model
           }

    assert aggregate.run.last_provider_result.message.model == @final_model
    assert {:ok, parent_aggregate} = Journal.load(store.namespace, run_id)
    durable_result = parent_aggregate.run.tool_results[operation.invocation_id]
    assert durable_result.completion.observed_metadata == %{model: @final_model}
    assert durable_result.details == %{json: @expected, model: @final_model}

    assert {:ok,
            %{
              coverage: :retained_only,
              entries: [%{locator: ^locator, aggregate: ^aggregate, availability: :present}]
            }} = RunInventory.load(session_id)

    send(next_provider, {:events, [parent_response("parent done")]})
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000

    assert %{phase: :terminal, resource_cleanup: :confirmed, run: %{state: :completed}} =
             Conversation.status(parent)

    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} = Session.status(session)
    assert {:ok, ^aggregate} = Journal.load(locator.namespace, locator.run_id)
    Gaoxy.Test.verify!(fixture)
  end

  defp parent_response(content),
    do: %{type: :response_completed, message: %{role: :assistant, content: content}}

  defp cleanup_journal(session_id, namespace) do
    prefixes = [
      "coord/runtime/facts/" <> segment(session_id) <> "/",
      "coord/runtime/runs/" <> segment(namespace) <> "/"
    ]

    for prefix <- prefixes do
      {:ok, pairs} = Concord.Turso.prefix_scan(prefix, timeout: 5_000)
      for {key, _} <- pairs, do: Concord.Turso.delete(key, timeout: 5_000)
    end
  end

  defp segment(value), do: value |> to_string() |> Base.url_encode64(padding: false)
end
