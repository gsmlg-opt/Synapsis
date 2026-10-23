defmodule Synapsis.Agent.Tools.ResultTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.{Message, Part, Session.Store}
  alias Synapsis.Part.ToolResult

  test "empty and binary results preserve legacy text without inventing content" do
    for content <- ["", "plain text"] do
      assert {:ok, part} = ResultProjection.to_part("call", {:ok, %{content: content}})
      assert part.content == content
      assert part.is_error == false

      assert part.projection == %{
               "version" => 1,
               "result" => %{"content" => content, "is_error" => false}
             }

      assert {:ok, part.projection} == ResultProjection.from_part(part)
    end

    assert {:ok, empty} = ResultProjection.to_part("call", {:ok, %{content: []}})
    assert empty.content == ""
    assert empty.projection["result"]["content"] == []
  end

  test "ordered media and opaque public fields survive JSON and Part persistence" do
    blocks = [
      %{type: :text, text: "before"},
      %{type: :image, data: %{source: "base64", media_type: "image/png", data: "aW1hZ2U="}},
      %{"type" => "audio", "data" => "YXVkaW8=", "mimeType" => "audio/wav"},
      %{"type" => "resource_link", "name" => "report", "uri" => "workspace://report"},
      %{"type" => "resource", "resource" => %{"uri" => "workspace://note", "text" => "note"}},
      %{type: :text, text: "after"}
    ]

    native = %{
      content: blocks,
      structured: %{"rows" => [%{"value" => 3}]},
      details: %{count: 1},
      artifacts: [%{uri: "workspace://report"}],
      progress: %{status: :running},
      pagination: %{cursor: "page-2", truncated: true},
      metadata: %{"opaque" => [nil, false, 4], "token_count" => 12}
    }

    assert {:ok, part} = ResultProjection.to_part("mixed", {:ok, native})
    assert part.content == "before\nafter"
    assert part.projection["result"]["structured"] == %{"rows" => [%{"value" => 3}]}
    assert part.projection["result"]["progress"] == %{"status" => "running"}
    assert part.projection["result"]["metadata"]["token_count"] == 12

    assert Enum.map(part.projection["result"]["content"], & &1["type"]) ==
             ~w(text image audio resource_link resource text)

    assert {:ok, stored} = Part.dump(part)
    assert {:ok, loaded} = stored |> Jason.encode!() |> Jason.decode!() |> Part.load()
    assert loaded == part
    assert {:ok, part.projection} == ResultProjection.from_part(loaded)
  end

  test "portable native map content is retained without JSON text fallback" do
    assert {:ok, part} =
             ResultProjection.to_part("structured", {:ok, %{content: %{answer: 42}}})

    assert part.content == ""
    assert part.projection["result"]["content"] == %{"answer" => 42}

    assert {:ok, part} = ResultProjection.to_part("no-content", {:ok, %{task_id: "task-1"}})
    assert part.content == ""
    assert part.projection["result"] == %{"task_id" => "task-1", "is_error" => false}
  end

  test "nontext and unknown portable media remain explicit in projection" do
    for block <- [
          %{"type" => "audio", "data" => "YXVkaW8="},
          %{"type" => "future_media", "reference" => "workspace://opaque"}
        ] do
      assert {:ok, part} = ResultProjection.to_part("media", {:ok, %{content: [block]}})
      assert part.content == ""
      assert part.projection["result"]["content"] == [block]
    end
  end

  test "native errors preserve class and portable details with safe display and no cause" do
    cases = [
      {:forbidden, "diagnostic-secret", "Tool denied by capability policy"},
      {:resource_conflict, "Tool registration changed", "Tool registration changed"},
      {:not_found, "tool is not registered", "Tool denied: tool is not in this run catalog"},
      {:unknown_outcome, "diagnostic-secret", "Tool execution failed"}
    ]

    for {class, message, expected} <- cases do
      error = Error.new(class, message, details: %{retryable: false}, cause: self())
      assert {:ok, part} = ResultProjection.to_part("failed", {:error, error})
      assert part.content == expected
      assert part.is_error

      assert part.projection["result"]["error"] == %{
               "class" => Atom.to_string(class),
               "message" => expected,
               "details" => %{"retryable" => false}
             }

      refute Jason.encode!(part.projection) =~ "diagnostic-secret"
      refute Map.has_key?(part.projection["result"]["error"], "cause")

      assert {:ok, normalized} =
               ResultProjection.to_part("failed", %{is_error: true, error: error})

      assert normalized == part
    end
  end

  test "explicit native error content remains visible while status is preserved" do
    assert {:ok, part} =
             ResultProjection.to_part(
               "failed",
               {:ok, %{is_error: true, content: "public failure"}}
             )

    assert part.is_error
    assert part.content == "public failure"
    assert part.projection["result"]["is_error"]
  end

  test "invalid errors and secret-bearing error details fail without diagnostics" do
    for error <- [
          %Error{class: "fixture-secret"},
          %Error{class: :invented_class},
          %Error{details: "fixture-secret"},
          Error.new(:execution_failure, "private", details: %{api_key: "fixture-secret"}),
          Error.new(:execution_failure, "private", details: %{received: self()})
        ] do
      assert {:error, safe_error} = ResultProjection.to_part("call", {:error, error})
      assert safe_error.class == :malformed_result
      refute inspect(safe_error) =~ "fixture-secret"
      refute inspect(safe_error) =~ "private"
    end
  end

  test "bound rejections need the exact native operation and displayed call ID" do
    operation = operation()
    rejected = ToolEffects.reject(operation, Error.new(:forbidden, "private diagnostics"))

    assert {:ok, part} =
             ResultProjection.to_part("call", rejected, operation: operation)

    assert part.content == "Tool denied by capability policy"
    refute Jason.encode!(part.projection) =~ "arguments"
    refute Jason.encode!(part.projection) =~ "identity"
    refute Jason.encode!(part.projection) =~ "private diagnostics"

    assert {:error, %Error{}} = ResultProjection.to_part("call", rejected)

    assert {:error, %Error{}} =
             ResultProjection.to_part("other-call", rejected, operation: operation)

    assert {:error, %Error{}} =
             ResultProjection.to_part("call", rejected,
               operation: %{operation | invocation_id: "different"}
             )
  end

  test "legacy string parts read as v1 without mutating history or reviving a call" do
    for is_error <- [false, true] do
      part = %ToolResult{tool_use_id: "legacy", content: "old result", is_error: is_error}

      assert {:ok,
              %{
                "version" => 1,
                "result" => %{"content" => "old result", "is_error" => ^is_error}
              }} = ResultProjection.from_part(part)

      assert part.projection == nil
      assert {:ok, dump} = Part.dump(part)
      refute Map.has_key?(dump, "projection")
    end
  end

  test "persisted wrapper validation rejects versions, ambiguous keys and inconsistent status" do
    for projection <- [
          %{"version" => 2, "result" => %{"is_error" => false}},
          %{"version" => 1, "result" => []},
          %{"version" => 1, "result" => %{"is_error" => true}},
          %{"version" => 1, "result" => %{"is_error" => "false"}},
          %{"version" => 1, "result" => %{}},
          %{"version" => 1, "result" => %{"is_error" => false}, "extra" => true},
          %{"version" => 1, :version => 1, "result" => %{"is_error" => false}},
          %{"version" => 1, "result" => %{"is_error" => false, :is_error => false}}
        ] do
      part = %ToolResult{tool_use_id: "call", content: "", projection: projection}
      assert {:error, %Error{}} = ResultProjection.from_part(part)
    end

    oversized_wrapper = Map.new(1..1_000, &{Integer.to_string(&1), nil})

    assert {:error, %Error{}} =
             ResultProjection.from_part(%ToolResult{content: "", projection: oversized_wrapper})
  end

  test "explicit auth and runtime context keys cannot enter opaque metadata" do
    for key <- [
          "authorization",
          "api_key",
          "access_token",
          "refresh_token",
          "client_secret",
          "password",
          "backend_context",
          "execution_context"
        ] do
      native = %{content: "public", metadata: %{key => "fixture-secret"}}
      assert {:error, error} = ResultProjection.to_part("call", {:ok, native})
      refute inspect(error) =~ "fixture-secret"

      assert {:error, error} =
               ResultProjection.from_part(%ToolResult{
                 content: "public",
                 projection: %{
                   "version" => 1,
                   "result" => %{
                     "is_error" => false,
                     "metadata" => %{key => "fixture-secret"}
                   }
                 }
               })

      refute inspect(error) =~ "fixture-secret"
    end

    assert {:ok, part} =
             ResultProjection.to_part(
               "call",
               {:ok, %{content: "authorization token_count", metadata: %{token_count: 3}}}
             )

    assert part.content == "authorization token_count"
  end

  test "runtime terms, unsupported structs and duplicate normalized keys are rejected safely" do
    for value <- [
          self(),
          make_ref(),
          fn -> :secret end,
          {:secret, "fixture-secret"},
          %URI{path: "fixture-secret"}
        ] do
      assert {:error, error} =
               ResultProjection.to_part("call", {:ok, %{metadata: %{nested: value}}})

      refute inspect(error) =~ "fixture-secret"
    end

    assert {:error, %Error{}} =
             ResultProjection.to_part("call", {:ok, %{"content" => "b", :content => "a"}})

    assert {:error, %Error{}} =
             ResultProjection.to_part(
               "call",
               {:ok, %{content: "ok", metadata: %{"id" => 1, :id => 2}}}
             )
  end

  test "plain runtime containers and case variants are rejected recursively on write and read" do
    for key <- [
          :authority,
          :operation,
          :resource_registry,
          :worker_supervisor,
          "accessToken",
          "refreshToken",
          "clientSecret",
          "backendContext",
          "executionContext",
          "Resource-Registry",
          "workerSupervisor"
        ] do
      native = %{"is_error" => false, "metadata" => [%{key => %{id: "private-container"}}]}
      assert {:error, error} = ResultProjection.to_part("call", {:ok, native})
      refute inspect(error) =~ "private-container"

      assert {:error, error} =
               ResultProjection.from_part(%ToolResult{
                 content: "",
                 projection: %{"version" => 1, "result" => native}
               })

      refute inspect(error) =~ "private-container"
    end
  end

  test "only supported enum fields accept atom values and opaque metadata stays JSON typed" do
    for native <- [
          %{metadata: %{opaque: :running}},
          %{metadata: [:running]},
          %{metadata: %{status: [:running]}},
          %{status: :invented_status},
          %{content: [%{type: :invented_media}]},
          %{content: :text}
        ] do
      assert {:error, %Error{}} = ResultProjection.to_part("call", {:ok, native})

      assert {:error, %Error{}} =
               ResultProjection.from_part(%ToolResult{
                 content: "",
                 projection: %{
                   "version" => 1,
                   "result" => Map.put(native, "is_error", false)
                 }
               })
    end

    assert {:ok, part} =
             ResultProjection.to_part(
               "call",
               {:ok,
                %{
                  status: :running,
                  content: [%{type: :text, text: "public authority accessToken"}],
                  metadata: %{
                    token_count: 1,
                    values: [nil, true, false],
                    type: "future_public_type"
                  }
                }}
             )

    assert part.projection["result"]["status"] == "running"
    assert part.projection["result"]["metadata"]["values"] == [nil, true, false]
  end

  test "invalid options and improper content lists produce safe errors" do
    rejected = ToolEffects.reject(operation(), Error.new(:forbidden, "private"))

    for opts <- [
          [1],
          [{"operation", operation()}],
          [operation: operation(), operation: operation()],
          [operation: operation()] ++ [1],
          [operation: %URI{}],
          [operation() | :invalid]
        ] do
      assert {:error, %Error{}} = ResultProjection.to_part("call", rejected, opts)
    end

    assert {:error, %Error{}} =
             ResultProjection.to_part("call", {:ok, %{content: ["text" | :invalid]}})
  end

  test "native limits reject collections, aggregate budgets and depth before JSON encoding" do
    alias Backplane.AiProtocol.{Serialization, Validation}
    limits = Validation.default_limits()
    Code.ensure_loaded!(Serialization)
    assert :erlang.trace_pattern({Serialization, :to_json, 1}, true, []) == 1
    on_exit(fn -> :erlang.trace_pattern({Serialization, :to_json, 1}, false, []) end)

    oversized = [
      Enum.to_list(1..(limits.max_list_length + 1)),
      Map.new(1..(limits.max_map_entries + 1), &{Integer.to_string(&1), nil}),
      List.duplicate(String.duplicate("x", div(limits.max_bytes, 8)), 9),
      List.duplicate(List.duplicate(nil, 100), 170),
      Enum.reduce(1..limits.max_depth, nil, fn _, inner -> [inner] end)
    ]

    for value <- oversized do
      {result, encoded?} = observe_encoding({:ok, %{metadata: value}})
      assert {:error, %Error{}} = result
      refute encoded?
    end

    {{:ok, _part}, encoded?} = observe_encoding({:ok, %{content: "trace control"}})
    assert encoded?
  end

  test "the exact native container-depth boundary is retained on write and read" do
    alias Backplane.AiProtocol.Validation
    depth = Validation.default_limits().max_depth
    metadata = Enum.reduce(1..(depth - 2), nil, fn _, inner -> [inner] end)

    projection = %{
      "version" => 1,
      "result" => %{"is_error" => false, "metadata" => metadata}
    }

    assert :ok = Validation.term(projection)
    assert {:ok, part} = ResultProjection.to_part("call", {:ok, %{metadata: metadata}})
    assert part.projection == projection
    assert {:ok, ^projection} = ResultProjection.from_part(part)

    too_deep = put_in(projection, ["result", "metadata"], [metadata])
    assert {:error, _} = Validation.term(too_deep)

    assert {:error, %Error{}} =
             ResultProjection.to_part("call", {:ok, %{metadata: [metadata]}})

    assert {:error, %Error{}} = ResultProjection.from_part(%{part | projection: too_deep})
  end

  test "malformed native results and bounded payloads return safe errors" do
    for result <- [
          "text",
          {:ok, "text"},
          {:ok, %{is_error: "true"}},
          {:error, "secret"},
          {:ok, %{content: [%{type: :text, text: 4}]}}
        ] do
      assert {:error, %Error{}} = ResultProjection.to_part("call", result)
    end

    assert {:error, %Error{}} =
             ResultProjection.to_part("call", {:ok, %{content: String.duplicate("x", 262_145)}})

    assert {:error, %Error{}} = ResultProjection.to_part("", {:ok, %{content: "text"}})
  end

  test "projected results survive the public append-per-turn Concord path" do
    Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)

    native = %{
      content: [
        %{type: :text, text: "stored"},
        %{type: :image, data: %{uri: "workspace://image"}}
      ],
      structured: %{value: 7}
    }

    assert {:ok, part} = ResultProjection.to_part("persisted-call", {:ok, native})

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      role: "assistant",
      parts: [part],
      inserted_at: DateTime.utc_now()
    }

    assert :ok = Store.commit_turn(session_id, 0, Message.encode(message), %{})
    assert [%Message{parts: [loaded]}] = Message.list_by_session(session_id)
    assert loaded == part
    assert {:ok, part.projection} == ResultProjection.from_part(loaded)
    assert :ok = Store.commit_turn(session_id, 0, Message.encode(message), %{})
    assert length(Message.list_by_session(session_id)) == 1
  end

  defp operation do
    %{
      run_id: "run",
      incarnation: 1,
      step_id: "step",
      attempt_id: "attempt",
      invocation_id: "invocation",
      tool_name: "native_tool",
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call",
      arguments: %{"text" => "private argument"}
    }
  end

  defp observe_encoding(result) do
    owner = self()

    worker =
      spawn_link(fn ->
        receive do
          :run ->
            send(owner, {:projection_result, self(), ResultProjection.to_part("call", result)})

          :stop ->
            exit(:normal)
        end

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      monitor = Process.monitor(worker)
      send(worker, :stop)

      receive do
        {:DOWN, ^monitor, :process, ^worker, _} -> :ok
      after
        100 ->
          Process.exit(worker, :kill)

          assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      end
    end)

    :erlang.trace(worker, true, [:call, :arity, {:tracer, owner}])
    send(worker, :run)
    assert_receive {:projection_result, ^worker, projected}, 1_000
    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}, 1_000

    encoded? =
      receive do
        {:trace, ^worker, :call, {Backplane.AiProtocol.Serialization, :to_json, 1}} -> true
      after
        0 -> false
      end

    :erlang.trace(worker, false, [:call])
    send(worker, :stop)
    {projected, encoded?}
  end
end
