defmodule Synapsis.Agent.Tools.NativePatchProjectionTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AiProtocol.Validation
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Agent.Tools.ResultProjection
  alias Synapsis.{Message, Part, Session.Store}

  test "all native patch actions retain ordered file evidence and readable text" do
    files = [
      %{path: "new.ex", action: :added},
      %{path: "edited.ex", action: :updated},
      %{path: "old.ex", action: :deleted},
      %{from: "source.ex", path: "destination.ex", action: :moved}
    ]

    for native <- [applied(files), stringify(applied(files))] do
      assert {:ok, part} = project(native)
      refute part.is_error
      assert part.projection["result"]["files"] == stringify(files)
      assert part.projection["result"]["status"] == "applied"

      assert part.content ==
               "Patch applied\nAdded: new.ex\nUpdated: edited.ex\nDeleted: old.ex\nMoved: source.ex -> destination.ex"

      assert {:ok, ^part} = project(part.projection["result"])
      assert {:ok, part.projection} == ResultProjection.from_part(part)
      assert {:ok, part.content} == ProviderMessages.tool_result_text(native, "apply_patch")
    end
  end

  test "patch failures expose completed and uncertain paths without private diagnostics" do
    for class <- [:resource_conflict, :unknown_outcome] do
      result = failed(class)
      assert {:ok, part} = project(result)
      assert part.is_error

      assert part.projection["result"]["error"] == %{
               "class" => Atom.to_string(class),
               "message" => "Patch failed (#{class})",
               "details" => %{
                 "files" => [%{"path" => "completed.ex", "action" => "added"}],
                 "uncertain_files" => ["uncertain.ex"]
               }
             }

      assert part.content ==
               "Patch failed (#{class})\nCompleted - Added: completed.ex\nUnknown outcome: uncertain.ex"

      refute Jason.encode!(part.projection) =~ "private"
      refute part.content =~ "Patch applied"
      assert {:ok, ^part} = project(part.projection["result"])
    end
  end

  test "failures without completion evidence never invent file effects" do
    assert {:ok, part} = project(%{is_error: true, error: Error.new(:validation, "private")})
    assert part.content == "Patch failed (validation)"
    assert part.projection["result"]["error"]["details"] == %{}
    refute part.content =~ "unchanged"
    refute part.content =~ "rollback"
  end

  test "ordered repeated paths and moves retain each completed operation" do
    files = [
      %{path: "same", action: :added},
      %{path: "same", action: :updated},
      %{from: "source", path: "target", action: :moved},
      %{path: "source", action: :deleted},
      %{from: "target", path: "target", action: :moved}
    ]

    assert {:ok, part} = project(applied(files))
    assert part.projection["result"]["files"] == stringify(files)

    assert part.content ==
             "Patch applied\nAdded: same\nUpdated: same\nMoved: source -> target\nDeleted: source\nMoved: target -> target"

    result = failed(:unknown_outcome, %{files: files, uncertain_files: ["same", "same"]})
    assert {:ok, failed} = project(result)
    assert failed.projection["result"]["error"]["details"]["files"] == stringify(files)
    assert failed.projection["result"]["error"]["details"]["uncertain_files"] == ["same", "same"]
    assert failed.content =~ "Unknown outcome: same\nUnknown outcome: same"
    assert {:ok, ^failed} = project(failed.projection["result"])
  end

  test "UTF8 paths retain original bytes while control characters cannot forge summary lines" do
    paths = ["line\nPatch applied", "tab\tname", "nul\0name", "delete\x7fname", "", " \t"]
    files = Enum.map(paths, &%{path: &1, action: :added})

    assert {:ok, part} = project(applied(files))
    assert part.projection["result"]["files"] == stringify(files)
    assert length(String.split(part.content, "\n")) == length(files) + 1
    assert part.content =~ ~s(Added: "line\\nPatch applied")
    assert part.content =~ ~s(Added: "tab\\tname")
    assert part.content =~ ~s(Added: "nul\\u0000name")
    assert {:ok, ^part} = project(part.projection["result"])

    assert {:ok, failed} = project(failed(:unknown_outcome, %{uncertain_files: paths}))
    assert failed.projection["result"]["error"]["details"]["uncertain_files"] == paths
    assert length(String.split(failed.content, "\n")) == length(paths) + 1
    assert failed.content =~ ~s(Unknown outcome: "line\\nPatch applied")
  end

  test "Unicode controls and separators are escaped only in display, preserving ordinary Unicode" do
    codepoints =
      Enum.to_list(0x80..0x9F) ++
        [0xA0, 0x1680] ++ Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000]

    for codepoint <- codepoints do
      character = <<codepoint::utf8>>
      path = "before" <> character <> "after"

      escape =
        "\\u" <>
          (codepoint |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))

      files = [%{path: path, action: :added}, %{from: path, path: "中文-é-λ.ex", action: :moved}]

      assert {:ok, part} = project(applied(files))
      assert part.projection["result"]["files"] == stringify(files)

      assert part.content ==
               "Patch applied\nAdded: \"before#{escape}after\"\nMoved: \"before#{escape}after\" -> 中文-é-λ.ex"

      refute part.content =~ character
      assert {:ok, ^part} = project(part.projection["result"])

      assert {:ok, failed} = project(failed(:unknown_outcome, %{uncertain_files: [path]}))
      assert failed.projection["result"]["error"]["details"]["uncertain_files"] == [path]

      assert failed.content ==
               "Patch failed (unknown_outcome)\nUnknown outcome: \"before#{escape}after\""

      refute failed.content =~ character
      assert {:ok, ^failed} = project(failed.projection["result"])
    end
  end

  test "Unicode escaping uses the exact display budget before allocating the summary" do
    limit = Validation.default_limits().max_string_bytes
    available = limit - byte_size("Patch applied\nAdded: \"\"")

    path =
      String.duplicate("\u2028", div(available, 6)) <> String.duplicate("p", rem(available, 6))

    assert byte_size(path) < limit
    assert {:ok, part} = project(applied([%{path: path, action: :added}]))
    assert part.projection["result"]["files"] == [%{"path" => path, "action" => "added"}]
    assert byte_size(part.content) == limit
    assert part.content =~ "\\u2028"
    refute part.content =~ "\u2028"

    assert {:error, %Error{class: :malformed_result}} =
             project(applied([%{path: path <> "\u2028", action: :added}]))
  end

  test "provider live, host and durable replay preserve safe partial failure evidence" do
    for result <- [applied([%{path: "ok.ex", action: :updated}]), failed(:unknown_outcome)] do
      assert {:ok, part} = ProviderMessages.tool_result_part("patch", result, "apply_patch")
      assert {:ok, part.content} == ProviderMessages.tool_result_text(result, "apply_patch")
      assert {:ok, host} = ProviderMessages.to_host(history(result))
      assert List.last(host).parts == [part]
      assert {:ok, dump} = Part.dump(part)
      assert {:ok, ^part} = dump |> Jason.encode!() |> Jason.decode!() |> Part.load()

      Store.ensure_started()
      session_id = Ecto.UUID.generate()
      on_exit(fn -> Store.delete_session(session_id) end)

      for {message, index} <- Enum.with_index(host) do
        stored = %Message{
          id: Ecto.UUID.generate(),
          session_id: session_id,
          role: Atom.to_string(message.role),
          parts: message.parts,
          inserted_at: DateTime.utc_now()
        }

        assert :ok = Store.commit_turn(session_id, index, Message.encode(stored), %{})
      end

      reloaded = Message.list_by_session(session_id)
      assert List.last(reloaded).parts == [part]
      assert {:ok, runtime} = ProviderMessages.from_host(reloaded)
      assert {:ok, ^host} = ProviderMessages.to_host(runtime)
      assert {:ok, ^runtime} = ProviderMessages.from_host(host)
      refute inspect(runtime) =~ "private"
    end
  end

  test "patch adaptation requires exact original identity and never expands generic atom support" do
    result = applied([%{path: "ok.ex", action: :added}])

    for name <- [nil, "patch", "Apply_Patch", "functions.apply_patch"] do
      assert {:error, %Error{}} = ResultProjection.to_part("patch", result, tool_name: name)
    end

    assert {:error, %Error{}} =
             ResultProjection.to_part("generic", %{content: "ok", action: :added})

    assert {:ok, generic} = ProviderMessages.tool_result_part("other", failed(:unknown_outcome))
    assert generic.content == "Tool execution failed"
    assert generic.projection["result"]["error"]["details"] == %{}
    refute Jason.encode!(generic.projection) =~ "completed.ex"
  end

  test "malformed file evidence and ambiguous keys fail closed" do
    bad_files = [
      [%{path: "x", action: :unknown}],
      [%{path: "x", action: "ADDED"}],
      [%{path: <<255>>, action: :added}],
      [%{path: 2, action: :added}],
      [%{path: "x", action: :moved}],
      [%{from: "x", path: "y", action: :added}],
      [%{path: "x", action: :added, private: "diagnostic"}],
      [%{:path => "x", "path" => "y", :action => :added}],
      [self()],
      [%{path: "x", action: :added} | :invalid]
    ]

    for files <- bad_files do
      assert {:error, %Error{class: :malformed_result}} = project(applied(files))
    end

    for native <- [
          %{status: :applied, files: "private"},
          %{status: :failed, files: []},
          %{status: :applied, files: [], content: "private"},
          %{:status => :applied, "status" => "applied", :files => []}
        ] do
      assert {:error, %Error{class: :malformed_result}} = project(native)
    end
  end

  test "malformed error evidence fails safely across provider paths" do
    for details <- [
          nil,
          [],
          %{files: "private"},
          %{files: [%{path: "x", action: :invalid}]},
          %{uncertain_files: [<<255>>]},
          %{uncertain_files: [self()]},
          %{:files => [], "files" => []}
        ] do
      error = %Error{class: :unknown_outcome, message: "private", details: details}
      result = %{is_error: true, error: error}
      assert {:error, %Error{}} = project(result)

      assert {:error, %Error{}} =
               ProviderMessages.tool_result_part("patch", result, "apply_patch")

      assert {:error, %Error{}} = ProviderMessages.tool_result_text(result, "apply_patch")
      assert {:error, %Error{}} = ProviderMessages.to_host(history(result))
    end

    assert {:error, %Error{}} = project(%{is_error: true, error: %{class: :invalid}})
  end

  test "native budgets apply to projected text as well as evidence before JSON allocation" do
    limits = Validation.default_limits()
    near = String.duplicate("p", limits.max_string_bytes - 64)
    assert {:ok, part} = project(applied([%{path: near, action: :added}]))
    assert byte_size(part.content) < limits.max_string_bytes

    # The path alone fits, but the required public summary exceeds the string budget.
    oversized = String.duplicate("p", limits.max_string_bytes)

    assert {:error, %Error{class: :malformed_result}} =
             project(applied([%{path: oversized, action: :added}]))

    assert {:error, %Error{}} =
             project(
               applied(List.duplicate(%{path: "p", action: :added}, limits.max_list_length + 1))
             )

    assert {:error, %Error{}} =
             project(failed(:unknown_outcome, %{uncertain_files: [oversized]}))
  end

  test "legacy nil-projection text remains a valid replay" do
    part = %Part.ToolResult{tool_use_id: "patch", content: "old patch output", is_error: false}
    assert {:ok, runtime} = ProviderMessages.from_host([%{role: :tool, parts: [part]}])
    assert {:ok, [%{parts: [^part]}]} = ProviderMessages.to_host(runtime)

    assert {:ok, %{"result" => %{"content" => "old patch output"}}} =
             ResultProjection.from_part(part)
  end

  defp project(result), do: ResultProjection.to_part("patch", result, tool_name: "apply_patch")
  defp applied(files), do: %{status: :applied, files: files}

  defp failed(
         class,
         details \\ %{
           files: [%{path: "completed.ex", action: :added}],
           uncertain_files: ["uncertain.ex"],
           backend_context: %{secret: "private diagnostic", process: self()}
         }
       ) do
    %{is_error: true, error: Error.new(class, "private message", details: details, cause: self())}
  end

  defp history(result) do
    [
      %{
        role: :assistant,
        content: [],
        tool_calls: [%{id: "patch", name: "apply_patch", arguments: %{}}]
      },
      %{role: :tool, tool_call_id: "patch", result: result}
    ]
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
