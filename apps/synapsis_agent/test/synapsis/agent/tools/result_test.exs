defmodule Synapsis.Agent.Tools.ResultTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.{Message, Part, Session.Store}
  alias Synapsis.Part.ToolResult

  test "exact native view_image results become ordered text and canonical image without duplicates" do
    for mime <- ~w(image/png image/jpeg image/gif image/webp), detail <- ~w(high original) do
      native = native_image(<<137, 80, 255, 0>>, mime, detail)

      for result <- [native, Map.new(native, fn {key, value} -> {to_string(key), value} end)] do
        assert {:ok, part} = ResultProjection.to_part("image", result, tool_name: "view_image")
        assert part.tool_use_id == "image"
        refute part.is_error
        public = part.projection["result"]
        assert public["path"] == "tiny.png"
        assert public["detail"] == detail
        assert public["mime_type"] == mime
        assert public["bytes"] == 4
        refute Map.has_key?(public, "data")
        refute Map.has_key?(public, "image_url")
        assert [text, image] = public["content"]
        assert text == %{"type" => "text", "text" => part.content}
        assert part.content =~ "tiny.png"
        assert part.content =~ mime
        assert part.content =~ detail
        assert part.content =~ "4"

        assert image == %{
                 "type" => "image",
                 "data" => %{
                   "source" => "base64",
                   "media_type" => mime,
                   "data" => Base.encode64(native.data)
                 }
               }

        assert {:ok, dump} = Part.dump(part)
        assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Part.load()
        assert {:ok, part.projection} == ResultProjection.from_part(part)
      end
    end
  end

  test "native image adaptation requires exact identity and complete unambiguous metadata" do
    native = native_image(<<255, 0>>)

    for opts <- [[], [tool_name: "image"], [tool_name: "View_Image"]] do
      assert {:error, %Error{class: :malformed_result}} =
               ResultProjection.to_part("image", native, opts)
    end

    malformed =
      Enum.map(Map.keys(native), &Map.delete(native, &1)) ++
        [
          Map.put(native, :bytes, 3),
          Map.put(native, :bytes, "2"),
          Map.put(native, :bytes, -1),
          Map.put(native, :data, ""),
          Map.put(native, :data, [255, 0]),
          Map.put(native, :path, ""),
          Map.put(native, :path, "   "),
          Map.put(native, :path, <<255>>),
          Map.put(native, :path, "tiny\n.png"),
          Map.put(native, :detail, "low"),
          Map.put(native, :detail, :high),
          Map.put(native, :mime_type, "image/svg+xml"),
          Map.put(native, :image_url, "data:image/jpeg;base64,/wA="),
          Map.put(native, :image_url, "data:image/png;base64,/wE="),
          Map.put(native, :image_url, "https://example.invalid/tiny.png"),
          Map.put(native, :image_url, "data:image/png;base64,/wA=\n"),
          Map.put(native, :is_error, "false"),
          Map.put(native, :is_error, true),
          Map.put(native, :content, "unvalidated success"),
          Map.put(native, :diagnostic, self()),
          Map.put(native, :backend_context, %{}),
          Map.put(native, :metadata, %{note: "extra field"})
        ] ++
        Enum.map(native, fn {key, value} -> Map.put(native, to_string(key), value) end)

    for result <- malformed do
      assert {:error, %Error{class: :malformed_result} = error} =
               ResultProjection.to_part("image", result, tool_name: "view_image")

      refute inspect(error) =~ "unvalidated success"
      refute inspect(error) =~ "extra field"
    end
  end

  test "native image base64 respects the unchanged string budget at and above its edge" do
    limits = Backplane.AiProtocol.Validation.default_limits()
    raw_limit = div(limits.max_string_bytes, 4) * 3
    assert raw_limit == 196_608
    native = native_image(:binary.copy(<<255>>, raw_limit))
    assert {:ok, part} = ResultProjection.to_part("edge", native, tool_name: "view_image")
    assert [_, image] = part.projection["result"]["content"]
    assert byte_size(image["data"]["data"]) == limits.max_string_bytes
    assert {:ok, part.projection} == ResultProjection.from_part(part)

    for result <- [
          native_image(:binary.copy(<<255>>, raw_limit + 1)),
          %{native | image_url: native.image_url <> "x"},
          %{native | path: String.duplicate("p", limits.max_string_bytes + 1)},
          %{native | path: String.duplicate("p", limits.max_string_bytes)}
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               ResultProjection.to_part("edge", result, tool_name: "view_image")
    end
  end

  test "native image over-budget preflight precedes base64 and JSON allocation" do
    Code.ensure_loaded!(Base)
    assert :erlang.trace_pattern({Base, :encode64, 1}, true, []) == 1
    on_exit(fn -> :erlang.trace_pattern({Base, :encode64, 1}, false, []) end)
    raw_limit = 196_608

    for native <- [
          native_image(:binary.copy(<<255>>, raw_limit + 1)),
          %{native_image(<<255>>) | image_url: String.duplicate("x", 262_200)},
          %{native_image(<<255>>) | path: String.duplicate("p", 262_144)}
        ] do
      {result, encoded?} =
        observe_encoding(native, [tool_name: "view_image"], {Base, :encode64, 1})

      assert {:error, %Error{class: :malformed_result}} = result
      refute encoded?
    end

    {{:ok, _part}, encoded?} =
      observe_encoding(native_image(<<255>>), [tool_name: "view_image"], {Base, :encode64, 1})

    assert encoded?
  end

  test "portable native image replay checks finite metadata and canonical content" do
    assert {:ok, part} =
             ResultProjection.to_part("image", native_image(<<255, 0>>), tool_name: "view_image")

    public = part.projection["result"]
    assert {:ok, ^part} = ResultProjection.to_part("image", public, tool_name: "view_image")

    for forged <- [
          Map.put(public, "bytes", 1),
          Map.put(public, "mime_type", "image/jpeg"),
          Map.put(public, "detail", "low"),
          Map.put(public, "path", "other.png"),
          Map.put(public, "extra", "diagnostic"),
          Map.put(public, "data", <<255>>),
          Map.put(public, "image_url", "data:image/png;base64,/wA="),
          Map.update!(public, "content", &Enum.reverse/1),
          put_in(public, ["content", Access.at(0), "text"], "forged summary"),
          put_in(public, ["content", Access.at(1), "data", "data"], "/wA=\n"),
          put_in(public, ["content", Access.at(1), "data", "source"], "url"),
          put_in(public, ["content", Access.at(1), "data", "extra"], true)
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               ResultProjection.to_part("image", forged, tool_name: "view_image")
    end
  end

  test "portable image replay rejects invalid base64 alphabet padding and unused bits" do
    cases = [
      # Three bytes use every encoded bit and require no padding.
      {<<255, 0, 1>>, "/wAB", ["/wA?", "/wA=", "/wAB="]},
      # One byte requires two padding characters and zero unused trailing bits.
      {<<255>>, "/w==", ["?w==", "/w", "/w=", "/w=A", "/x=="]},
      # Two bytes require one padding character and zero unused trailing bits.
      {<<255, 0>>, "/wA=", ["/w?=", "/wA", "/wA==", "/w=A", "/wB="]}
    ]

    for {data, encoded, malformed} <- cases do
      assert {:ok, part} =
               ResultProjection.to_part("image", native_image(data), tool_name: "view_image")

      public = part.projection["result"]
      assert get_in(public, ["content", Access.at(1), "data", "data"]) == encoded
      assert {:ok, ^part} = ResultProjection.to_part("image", public, tool_name: "view_image")

      for invalid <- malformed do
        forged = put_in(public, ["content", Access.at(1), "data", "data"], invalid)
        assert forged["bytes"] == byte_size(data)

        assert {:error, %Error{class: :malformed_result}} =
                 ResultProjection.to_part("image", forged, tool_name: "view_image")
      end
    end
  end

  test "native view_image errors retain explicit failure status and safe class" do
    for class <- [:resource_conflict, :validation, :unsupported_capability] do
      error = Error.new(class, "private native diagnostic", cause: self())

      assert {:ok, part} =
               ResultProjection.to_part("failed-image", {:error, error}, tool_name: "view_image")

      assert part.is_error
      assert part.content == "Tool execution failed"
      assert part.projection["result"]["error"]["class"] == Atom.to_string(class)
      refute Jason.encode!(part.projection) =~ "private native diagnostic"
      refute Map.has_key?(part.projection["result"], "content")
    end
  end

  test "native command results retain public fields and display process lifecycle explicitly" do
    for name <- ["exec_command", "write_stdin"] do
      result = %{
        output: "command output\n",
        status: :running,
        termination_status: :not_requested,
        cleanup_status: :not_started,
        wall_time_seconds: 0.125,
        session_id: 42,
        output_limit_exceeded?: false,
        output_truncated: true,
        omitted_output_bytes: 12,
        output_budget_unit: :estimated_token_bytes
      }

      assert {:ok, part} = ResultProjection.to_part("command", result, tool_name: name)
      assert String.starts_with?(part.content, result.output)
      assert part.content =~ "Status: running"
      assert part.content =~ "Session ID: 42"
      assert part.content =~ "Wall time: 0.125 seconds"
      assert part.content =~ "Termination: not_requested"
      assert part.content =~ "Cleanup: not_started"
      assert part.content =~ "Output truncated: true"
      assert part.content =~ "Omitted output bytes: 12"
      assert part.content =~ "Output budget unit: estimated_token_bytes"
      assert part.content =~ "Output limit exceeded: false"
      public = part.projection["result"]
      assert public["output"] == result.output
      assert public["session_id"] == 42
      assert public["omitted_output_bytes"] == 12
      assert public["output_budget_unit"] == "estimated_token_bytes"
      assert {:ok, dump} = Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Part.load()
    end
  end

  test "native command terminal and settling enums have finite checked presentation" do
    for status <- ~w(completed failed cancelled deadline_exceeded output_limit_exceeded
                     execution_failure cancelling settling cleanup_failed)a do
      result = %{
        output: "",
        status: status,
        exit_code: 7,
        wall_time_seconds: 0,
        termination_status: :requested,
        cleanup_status: :pending,
        session_id: 3
      }

      assert {:ok, part} = ResultProjection.to_part("command", result, tool_name: "exec_command")
      assert part.content =~ "Status: #{status}"
      assert part.content =~ "Exit code: 7"
      assert part.content =~ "Termination: requested"
      assert part.content =~ "Cleanup: pending"
      assert part.content =~ "Session ID: 3"
    end
  end

  test "uncertain native command cleanup keeps status and redacts diagnostic context" do
    error =
      Error.new(:resource_conflict, "private cleanup diagnostic",
        details: %{process_group_id: 123, probe_error: "private path", context: self()},
        cause: {self(), make_ref()}
      )

    result = %{
      output: "partial",
      status: :cleanup_failed,
      cleanup_status: :uncertain,
      termination_status: :requested,
      cleanup_error: error,
      session_id: 11,
      wall_time_seconds: 1.0
    }

    assert {:ok, part} = ResultProjection.to_part("command", result, tool_name: "write_stdin")
    assert part.content =~ "Status: cleanup_failed"
    assert part.content =~ "Cleanup: uncertain"
    assert part.content =~ "Session ID: 11"
    assert part.content =~ "Cleanup error: Command cleanup could not be confirmed"

    assert part.projection["result"]["cleanup_error"] == %{
             "class" => "resource_conflict",
             "message" => "Command cleanup could not be confirmed"
           }

    refute Jason.encode!(part.projection) =~ "private"
    refute Jason.encode!(part.projection) =~ "process_group_id"
    refute Jason.encode!(part.projection) =~ "cause"
  end

  test "malformed native command shapes and unknown enums fail without text fallback" do
    base = %{output: "", status: :completed, wall_time_seconds: 0.0}

    for bad <- [
          %{output: <<255>>},
          %{output: []},
          %{status: "invented"},
          %{status: :invented},
          %{status: "success"},
          %{wall_time_seconds: -1},
          %{wall_time_seconds: "1"},
          %{exit_code: "0"},
          %{exit_code: -1},
          %{session_id: 0},
          %{session_id: "42"},
          %{termination_status: "confirmed"},
          %{cleanup_status: "done"},
          %{output_truncated: "true"},
          %{omitted_output_bytes: -1},
          %{output_budget_unit: "tokens"},
          %{output_limit_exceeded?: 1},
          %{cleanup_error: "private diagnostic"},
          %{cleanup_error: %{message: "private"}},
          %{cleanup_error: %Error{class: :invented_class}}
        ],
        name <- ["exec_command", "write_stdin"] do
      assert {:error, %Error{class: :malformed_result}} =
               ResultProjection.to_part("command", Map.merge(base, bad), tool_name: name)
    end
  end

  test "exact native clock names present checked values and preserve public fields" do
    assert {:ok, now} =
             ResultProjection.to_part("now", %{current_time: "2026-10-24 12:34:56 UTC"},
               tool_name: "clock::curr_time"
             )

    assert now.content == "Current time: 2026-10-24 12:34:56 UTC"
    assert now.projection["result"]["current_time"] == "2026-10-24 12:34:56 UTC"

    assert {:ok, slept} =
             ResultProjection.to_part("sleep", %{wall_time_seconds: 0.125},
               tool_name: "clock::sleep"
             )

    assert slept.content == "Wall time: 0.125 seconds"
    assert slept.projection["result"]["wall_time_seconds"] == 0.125

    for {name, result} <- [
          {"clock", %{current_time: "2026-10-24 12:34:56 UTC"}},
          {"wait", %{wall_time_seconds: 1}},
          {"clock::curr_time", %{current_time: 42}},
          {"clock::curr_time", %{current_time: ""}},
          {"clock::sleep", %{wall_time_seconds: -1}},
          {"clock::sleep", %{wall_time_seconds: "1"}}
        ] do
      assert {:error, %Error{class: :malformed_result}} =
               ResultProjection.to_part("clock", result, tool_name: name)
    end
  end

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

  test "original collaboration identity presents bounded public shapes without dropping native fields" do
    cases = [
      {"spawn_agent", %{task_name: "/root/child", nickname: nil}, "Spawned agent /root/child"},
      {"followup_task", %{accepted: true}, "Follow-up task accepted"},
      {"send_message", %{accepted: true, message_id: "mail-1", acceptance: :process_local},
       "Message accepted: mail-1"},
      {"wait_agent", %{message: "Wait timed out.", timed_out: true}, "Wait timed out."},
      {"list_agents", %{agents: []}, "No agents"},
      {"list_agents",
       %{
         agents: [
           %{
             agent_name: "/root/child",
             agent_status: %{completed: [%{type: :text, text: "Finished"}]}
           }
         ]
       }, "/root/child: completed: Finished"},
      {"interrupt_agent", %{previous_status: %{completed: "Finished"}, status: :interrupted},
       "Agent interrupted: completed: Finished -> interrupted"}
    ]

    for {name, result, text} <- cases do
      assert {:ok, part} = ResultProjection.to_part("call", result, tool_name: name)
      assert part.content == text
      assert part.projection["result"]["content"] == text

      assert Map.keys(part.projection["result"]) |> Enum.sort() ==
               (Enum.map(Map.keys(result), &Atom.to_string/1) ++ ["content", "is_error"])
               |> Enum.sort()

      assert {:ok, part.projection} == ResultProjection.from_part(part)
    end

    assert {:error, %Error{}} =
             ResultProjection.to_part("call", %{task_name: "/root/child"}, tool_name: "unrelated")
  end

  test "list_agents normalizes only the two native activation failure atoms" do
    for reason <- [:startup_failure, :admission_failure] do
      result = %{agents: [%{agent_name: "/root/failed", agent_status: %{errored: reason}}]}
      assert {:ok, part} = ResultProjection.to_part("list", result, tool_name: "list_agents")
      assert part.content == "/root/failed: errored: " <> Atom.to_string(reason)

      assert part.projection["result"]["agents"] ==
               [
                 %{
                   "agent_name" => "/root/failed",
                   "agent_status" => %{"errored" => Atom.to_string(reason)}
                 }
               ]

      assert {:ok, part.projection} == ResultProjection.from_part(part)
    end

    for result <- [
          %{agents: [%{agent_name: "/root/failed", agent_status: %{errored: :invented_failure}}]},
          %{metadata: %{opaque: :startup_failure}},
          %{metadata: %{reason: :admission_failure}}
        ] do
      assert {:error, %Error{}} =
               ResultProjection.to_part("list", result, tool_name: "list_agents")
    end
  end

  test "completed collaboration statuses retain reasoning and provider state without displaying them" do
    state = %{"kind" => "signed", "payload" => %{"signature" => "opaque-signed-state"}}

    assert {:ok, _, events} =
             Synapsis.Agent.Runtime.ProviderEvents.push(
               Synapsis.Agent.Runtime.ProviderEvents.new(),
               {:reasoning_delta, "private reasoning"}
             )

    assert {:ok, [], events} =
             Synapsis.Agent.Runtime.ProviderEvents.push(events, {:provider_state, state})

    assert {:ok, _, events} =
             Synapsis.Agent.Runtime.ProviderEvents.push(events, {:text_delta, "Public answer"})

    assert {:ok, %{message: %{content: blocks}}} =
             Synapsis.Agent.Runtime.ProviderEvents.finish(events)

    blocks = blocks ++ [%{type: :provider_state, state: state}]

    for {name, result, expected} <- [
          {"list_agents",
           %{agents: [%{agent_name: "/root/child", agent_status: %{completed: blocks}}]},
           "/root/child: completed: Public answer"},
          {"interrupt_agent", %{previous_status: %{completed: blocks}, status: :interrupted},
           "Agent interrupted: completed: Public answer -> interrupted"}
        ] do
      assert {:ok, part} = ResultProjection.to_part("status", result, tool_name: name)
      assert part.content == expected
      refute part.content =~ "private reasoning"
      refute part.content =~ "opaque-signed-state"

      completed =
        if name == "list_agents",
          do:
            get_in(part.projection, [
              "result",
              "agents",
              Access.at(0),
              "agent_status",
              "completed"
            ]),
          else: get_in(part.projection, ["result", "previous_status", "completed"])

      assert completed == [
               %{
                 "type" => "reasoning",
                 "text" => "private reasoning",
                 "provider_states" => [state]
               },
               %{"type" => "text", "text" => "Public answer"},
               %{"type" => "provider_state", "state" => state}
             ]

      assert {:ok, dumped} = Part.dump(part)
      assert {:ok, loaded} = dumped |> Jason.encode!() |> Jason.decode!() |> Part.load()
      assert loaded == part
      assert {:ok, part.projection} == ResultProjection.from_part(loaded)
    end
  end

  test "completed reasoning-only status has a finite completion label" do
    blocks = [%{type: :reasoning, text: "private reasoning", provider_states: []}]
    result = %{agents: [%{agent_name: "/root/child", agent_status: %{completed: blocks}}]}
    assert {:ok, part} = ResultProjection.to_part("status", result, tool_name: "list_agents")
    assert part.content == "/root/child: completed"

    assert get_in(part.projection, ["result", "agents", Access.at(0), "agent_status", "completed"]) ==
             [%{"type" => "reasoning", "text" => "private reasoning", "provider_states" => []}]
  end

  test "completed statuses reject malformed reasoning state and unsupported media" do
    for block <- [
          %{type: :reasoning, text: 4},
          %{type: :reasoning, text: "thinking", provider_states: "invalid"},
          %{type: :reasoning, text: "thinking", provider_states: ["invalid"]},
          %{type: :reasoning, text: "thinking", signature: 4},
          %{type: :provider_state, state: "invalid"},
          %{"type" => "audio", "data" => "YQ=="}
        ] do
      result = %{
        agents: [
          %{
            agent_name: "/root/child",
            agent_status: %{completed: [block, %{type: :text, text: "answer"}]}
          }
        ]
      }

      assert {:error, %Error{}} =
               ResultProjection.to_part("status", result, tool_name: "list_agents")
    end
  end

  test "production history projection survives Concord and restores native provider replay" do
    alias Synapsis.Agent.Runtime.ProviderMessages
    Store.ensure_started()
    session_id = Ecto.UUID.generate()
    on_exit(fn -> Store.delete_session(session_id) end)

    result = %{
      content: [%{type: :text, text: "Workspace memory written"}],
      structured: %{path: "/global/memory.md", revision: 2}
    }

    assert {:ok, [%{parts: [part]}]} =
             ProviderMessages.to_host([%{role: :tool, tool_call_id: "memory", result: result}])

    message = %Message{
      id: Ecto.UUID.generate(),
      session_id: session_id,
      role: "user",
      parts: [part],
      inserted_at: DateTime.utc_now()
    }

    assert :ok = Store.commit_turn(session_id, 0, Message.encode(message), %{})
    assert [stored] = Message.list_by_session(session_id)
    assert {:ok, [%{result: replay}] = runtime} = ProviderMessages.from_host([stored])
    assert replay["structured"] == %{"path" => "/global/memory.md", "revision" => 2}
    assert replay.content == [%{"type" => "text", "text" => "Workspace memory written"}]
    assert {:ok, [%{parts: [^part]}] = host} = ProviderMessages.to_host(runtime)

    assert {:ok, wire} =
             Synapsis.Provider.Adapter.format_request(host, [], %{
               model: "fixture",
               provider_type: :openai
             })

    assert [
             %{
               "role" => "tool",
               "tool_call_id" => "memory",
               "content" => "Workspace memory written"
             }
           ] = wire["messages"]
  end

  defp native_image(data, mime \\ "image/png", detail \\ "high") do
    %{
      path: "tiny.png",
      detail: detail,
      mime_type: mime,
      data: data,
      bytes: byte_size(data),
      image_url: "data:#{mime};base64,#{Base.encode64(data)}"
    }
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

  defp observe_encoding(
         result,
         opts \\ [],
         encoded_function \\ {Backplane.AiProtocol.Serialization, :to_json, 1}
       ) do
    owner = self()

    worker =
      spawn_link(fn ->
        receive do
          :run ->
            send(
              owner,
              {:projection_result, self(), ResultProjection.to_part("call", result, opts)}
            )

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
        {:trace, ^worker, :call, ^encoded_function} -> true
      after
        0 -> false
      end

    :erlang.trace(worker, false, [:call])
    send(worker, :stop)
    {projected, encoded?}
  end
end
