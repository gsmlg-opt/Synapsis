defmodule Synapsis.Provider.CodeExecutionFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.CodeExecution

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "default preparation sends a remote code interpreter task" do
    assert {:ok, prepared} = CodeExecution.prepare(%{}, %{"task" => "  Analyze 1, 2, 3  "})
    assert prepared.endpoint == "https://api.x.ai/v1/responses"
    assert prepared.timeout_ms == 30_000
    assert prepared.task == "Analyze 1, 2, 3"
    assert prepared.model == "grok-4.7"

    assert prepared.body == %{
             "model" => "grok-4.7",
             "input" => [%{"role" => "user", "content" => "Analyze 1, 2, 3"}],
             "tools" => [%{"type" => "code_interpreter"}],
             "store" => false,
             "reasoning" => %{"effort" => "low"}
           }
  end

  test "model aliases retain code execution low reasoning rather than X search none" do
    for {requested, model, effort} <- [
          {"grok-4.3-latest", "grok-4.3", "low"},
          {"grok-4.7-latest", "grok-4.7", "low"},
          {"grok-4.5-latest", "grok-4.5", nil},
          {"grok-code-fast", "grok-build-0.1", nil},
          {"grok-4.20", "grok-4.20", nil},
          {"grok-4.8-0115", "grok-4.8-0115", "low"},
          {"grok-5", "grok-5", "low"}
        ] do
      assert {:ok, prepared} = CodeExecution.prepare(%{model: requested}, %{"task" => "Sum 1+2"})
      assert prepared.model == model
      assert prepared.body["model"] == model
      assert prepared.body["reasoning"] == if(effort, do: %{"effort" => effort}, else: nil)
    end
  end

  test "explicit host endpoint, deadline and max turns stay outside model arguments" do
    assert {:ok, prepared} =
             CodeExecution.prepare(
               %{
                 base_url: " https://proxy.example/custom/// ",
                 model: " grok-4.3 ",
                 timeout_ms: 12_500,
                 max_turns: 4.9
               },
               %{"task" => "  Build a table\nwith totals  "}
             )

    assert prepared.endpoint == "https://proxy.example/custom/responses"
    assert prepared.timeout_ms == 12_500
    assert prepared.body["max_turns"] == 4

    assert prepared.body["input"] == [
             %{"role" => "user", "content" => "Build a table\nwith totals"}
           ]
  end

  test "successful HTTP retains long adjacent Unicode text and ordered interpreter output types",
       context do
    long = String.duplicate("😀é", 7_000)
    owner = self()

    stub(context, fn conn, body ->
      send(owner, {:code_wire, conn.method, conn.request_path, body})

      %{
        "output" => [
          %{"type" => "reasoning"},
          %{"type" => "code_interpreter_call"},
          message(" " <> long),
          %{"type" => "code_interpreter_call"},
          %{"type" => "output_text", "text" => "\nDone ", "annotations" => []}
        ]
      }
    end)

    assert {:ok, prepared} =
             CodeExecution.prepare(config(context), %{"task" => "  Analyze supplied data  "})

    assert {:ok, result} = CodeExecution.execute(config(context), prepared)
    assert_receive {:code_wire, "POST", "/v1/responses", body}
    assert body == prepared.body
    assert is_integer(result["tookMs"]) and result["tookMs"] >= 0

    assert Map.delete(result, "tookMs") == %{
             "task" => "Analyze supplied data",
             "provider" => "xai",
             "model" => "grok-4.7",
             "content" => " " <> long <> "\nDone ",
             "citations" => [],
             "usedCodeExecution" => true,
             "outputTypes" => ["reasoning", "code_interpreter_call", "message", "output_text"]
           }
  end

  test "top-level output text fallback preserves whitespace and observed empty output types",
       context do
    stub(context, fn _, _ -> %{"output_text" => " \t\n"} end)
    assert {:ok, result} = execute(context)
    assert result["content"] == " \t\n"
    assert result["citations"] == []
    assert result["usedCodeExecution"] == false
    assert result["outputTypes"] == []
  end

  test "top-level citations take precedence and retain ordinary canonical URL order", context do
    stub(context, fn _, _ ->
      %{
        "output" => [message("answer", [citation("https://annotation.example/a")])],
        "citations" => [
          "https://X.example:443/one",
          "https://x.example/one",
          "https://bare.example"
        ],
        "inline_citations" => [
          %{"url" => "https://inline.example/a", "start_index" => 0, "end_index" => 6}
        ]
      }
    end)

    assert {:ok, result} = execute(context)
    assert result["citations"] == ["https://x.example/one", "https://bare.example"]
    assert result["outputTypes"] == ["message"]
    assert result["usedCodeExecution"] == false

    assert Enum.sort(Map.keys(result)) ==
             Enum.sort(
               ~w(task provider model tookMs content citations usedCodeExecution outputTypes)
             )
  end

  test "annotation citations span retained full text without a search content cap", context do
    long = String.duplicate("a", 21_000)

    stub(context, fn _, _ ->
      %{
        "output" => [
          message(long, [citation("https://first.example/a")]),
          message("second", [
            citation("https://second.example/b"),
            citation("https://first.example/a")
          ])
        ]
      }
    end)

    assert {:ok, result} = execute(context)
    assert result["content"] == long <> "second"
    assert result["citations"] == ["https://first.example/a", "https://second.example/b"]
  end

  test "citation count and scan bounds preserve positive ordinary source order", context do
    urls = for i <- 1..23, do: "https://posts.example/#{i}"
    stub(context, fn _, _ -> %{"output_text" => "answer", "citations" => urls} end)
    assert {:ok, result} = execute(context)
    assert result["citations"] == Enum.take(urls, 20)

    fixture = Gaoxy.Test.open()

    try do
      more = %{context | fixture: fixture}

      stub(more, fn _, _ ->
        %{
          "output_text" => "answer",
          "citations" => List.duplicate(hd(urls), 1_000) ++ [Enum.at(urls, 1)]
        }
      end)

      assert {:ok, scanned} = execute(more)
      assert scanned["citations"] == [hd(urls)]
    after
      Gaoxy.Test.close(fixture)
    end
  end

  test "identical completed calls each request the remote service", context do
    owner = self()

    stub(context, fn _, body ->
      send(owner, {:remote_request, body})
      %{"output" => [%{"type" => "code_interpreter_call"}, message("3")]}
    end)

    assert {:ok, first} = execute(context)
    assert {:ok, second} = execute(context)
    assert Map.delete(first, "tookMs") == Map.delete(second, "tookMs")
    assert_receive {:remote_request, body}
    assert_receive {:remote_request, ^body}
  end

  test "all successful fixed-source callbacks retain exact requests and complete result maps" do
    fixture_path =
      Path.expand(
        "../../../../synapsis_agent/test/fixtures/openclaw/488631c/code-execution.json",
        __DIR__
      )

    capture = fixture_path |> File.read!() |> Jason.decode!()
    assert capture["pin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"

    callbacks =
      for group <- capture["groups"],
          {step, index} <- Enum.with_index(group["steps"]),
          do: {group, step, index}

    assert length(callbacks) == 42

    for {group, step, index} <- callbacks do
      code_config =
        get_in(step, ["runtimeConfig", "plugins", "entries", "xai", "config", "codeExecution"]) ||
          get_in(step, ["config", "plugins", "entries", "xai", "config", "codeExecution"]) || %{}

      config = %{
        api_key: "ordinary-source-fixture-key",
        model: code_config["model"] || "grok-4.7",
        timeout_ms: (code_config["timeoutSeconds"] || 30) * 1_000,
        max_turns: code_config["maxTurns"]
      }

      assert {:ok, prepared} = CodeExecution.prepare(config, step["arguments"])
      assert prepared.endpoint == step["request"]["url"], group["id"]
      assert prepared.timeout_ms == step["request"]["timeoutSeconds"] * 1_000, group["id"]
      assert prepared.body == step["request"]["body"], group["id"]
      fixture = Gaoxy.Test.open()

      try do
        path = URI.parse(prepared.endpoint).path
        owner = self()
        id = {group["id"], index}

        Gaoxy.Test.stub(fixture, "POST", path, fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:source_code_wire, id, conn.method, conn.request_path, Jason.decode!(body)}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
        end)

        assert {:ok, actual} =
                 CodeExecution.execute(config, %{
                   prepared
                   | endpoint: Gaoxy.Test.url(fixture, path)
                 })

        assert_receive {:source_code_wire, ^id, "POST", ^path, wire}
        assert wire == step["request"]["body"], inspect(id)
        assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0

        assert Map.put(actual, "tookMs", step["resultPortable"]["tookMs"]) ==
                 step["resultPortable"],
               inspect(id)
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp config(context),
    do: %{
      api_key: "ordinary-code-fixture-key",
      base_url: Gaoxy.Test.url(context.fixture, "/v1/"),
      timeout_ms: 5_000
    }

  defp execute(context) do
    with {:ok, prepared} <- CodeExecution.prepare(config(context), %{"task" => "Sum 1+2"}),
         do: CodeExecution.execute(config(context), prepared)
  end

  defp stub(context, response) do
    Gaoxy.Test.stub(context.fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response.(conn, Jason.decode!(body))))
    end)
  end

  defp message(text, annotations \\ []),
    do: %{
      "type" => "message",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => annotations}]
    }

  defp citation(url), do: %{"type" => "url_citation", "url" => url}
end
