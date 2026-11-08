defmodule Synapsis.Agent.Tools.LLMTaskRequestFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Tools.LLMTask.{Request, Result}

  @fixture Path.expand("../../../fixtures/openclaw/488631c/llm-task.json", __DIR__)
  @resolved %{
    provider_context: %{
      provider_config: %{type: "openai", base_url: "http://fixture.invalid", api_key: "fixture"},
      request_options: %{
        model: "selected-model",
        max_tokens: 17,
        temperature: 0,
        reasoning_effort: "medium"
      }
    },
    timeout_ms: 12_345,
    output_limit: 65_536
  }

  test "preserves original task bytes and uses newline envelope separators with native pretty JSON" do
    task = %{
      "prompt" => " \uFEFFclassify 雪😀\nnext\t ",
      "input" => %{"z" => 2, "a" => ["one", nil]},
      "schema" => %{"type" => "object"}
    }

    assert {:ok, request} = Request.prepare(task, @resolved)

    assert request.prompt ==
             "TASK:\n \uFEFFclassify 雪😀\nnext\t \n\nINPUT_JSON:\n" <>
               "{\n  \"a\": [\n    \"one\",\n    null\n  ],\n  \"z\": 2\n}\n"

    assert request == %{
             prompt: request.prompt,
             schema: %{"type" => "object"},
             provider_context: @resolved.provider_context,
             timeout_ms: 12_345,
             output_limit: 65_536
           }

    assert task["prompt"] == " \uFEFFclassify 雪😀\nnext\t "
    assert task["input"] == %{"z" => 2, "a" => ["one", nil]}
  end

  test "preserves every native JSON root and native integer precision" do
    cases = [
      {nil, "null"},
      {false, "false"},
      {true, "true"},
      {0, "0"},
      {1.25, "1.25"},
      {9_007_199_254_740_993, "9007199254740993"},
      {"", "\"\""},
      {" 雪😀\n\"\\ ", "\" 雪😀\\n\\\"\\\\ \""},
      {[], "[]"},
      {%{}, "{}"},
      {[false, 0, " padded ", nil], "[\n  false,\n  0,\n  \" padded \",\n  null\n]"},
      {%{"nested" => [1, false, nil]}, "{\n  \"nested\": [\n    1,\n    false,\n    null\n  ]\n}"}
    ]

    for {value, expected} <- cases do
      assert {:ok, request} = Request.prepare(%{"prompt" => "task", "input" => value}, @resolved)
      assert request.prompt == "TASK:\ntask\n\nINPUT_JSON:\n" <> expected <> "\n"
      assert {:ok, %{content: ^expected, details: %{json: ^value}}} = Result.present(value)
    end

    assert {:ok, absent} = Request.prepare(%{"prompt" => "task"}, @resolved)
    assert absent.prompt == "TASK:\ntask\n\nINPUT_JSON:\nnull\n"
  end

  test "keeps explicit resolved options without interpreting raw overrides or adding defaults" do
    task = %{
      "prompt" => "task",
      "provider" => "unresolved-provider",
      "model" => "unresolved-model",
      "authProfileId" => "unresolved-profile",
      "timeoutMs" => 1,
      "maxTokens" => 2,
      "temperature" => 1,
      "thinking" => "high"
    }

    assert {:ok, request} = Request.prepare(task, @resolved)
    assert request.provider_context === @resolved.provider_context
    assert request.timeout_ms == 12_345
    assert request.output_limit == 65_536
    assert request.provider_context.request_options.temperature === 0
    assert request.provider_context.request_options.reasoning_effort == "medium"

    minimal = put_in(@resolved.provider_context.request_options, %{model: "explicit-model"})
    assert {:ok, prepared} = Request.prepare(%{"prompt" => "task"}, minimal)
    assert prepared.provider_context.request_options === %{model: "explicit-model"}

    assert Map.keys(prepared) |> Enum.sort() ==
             [:output_limit, :prompt, :provider_context, :schema, :timeout_ms]
  end

  test "retains active object schemas separately and normalizes source-inactive schema values" do
    schema = %{
      "type" => "object",
      "properties" => %{"optional" => %{"type" => "string", "default" => "unused"}}
    }

    for active <- [%{}, schema] do
      assert {:ok, request} =
               Request.prepare(%{"prompt" => "task", "schema" => active}, @resolved)

      assert request.schema === active
      assert request.prompt == "TASK:\ntask\n\nINPUT_JSON:\nnull\n"
    end

    for inactive <- [nil, false, true, 0, "schema", [], [schema]] do
      assert {:ok, %{schema: nil}} =
               Request.prepare(%{"prompt" => "task", "schema" => inactive}, @resolved)
    end
  end

  test "presents only supplied observed identity and preserves the decoded value" do
    value = %{"kind" => "ok", "count" => 2}

    assert {:ok, native} =
             Result.present(value, %{
               provider: "observed-provider",
               model: "observed-model",
               usage: %{input_tokens: 5},
               locator: %{run_id: "internal"}
             })

    assert native == %{
             content: "{\n  \"count\": 2,\n  \"kind\": \"ok\"\n}",
             details: %{json: value, provider: "observed-provider", model: "observed-model"}
           }

    assert {:ok, %{details: %{json: ^value} = details}} = Result.present(value)
    assert Map.keys(details) == [:json]

    assert {:ok, %{details: %{json: nil, provider: "observed-provider"}}} =
             Result.present(nil, %{provider: "observed-provider"})
  end

  test "uses frozen source task syntax and JSON semantics with native representation differences" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(fixture["vectors"]) == 12

    for vector <- fixture["vectors"] do
      task = vector["arguments"]
      assert {:ok, request} = Request.prepare(task, @resolved)
      [source_call] = vector["completeCalls"]
      [source_message] = source_call["messages"]
      prefix = "TASK:\n" <> task["prompt"] <> "\n\nINPUT_JSON:\n"
      assert String.starts_with?(request.prompt, prefix)
      assert String.starts_with?(source_message["content"], prefix)

      native_input =
        request.prompt |> String.replace_prefix(prefix, "") |> String.replace_suffix("\n", "")

      source_input =
        source_message["content"]
        |> String.replace_prefix(prefix, "")
        |> String.replace_suffix("\n", "")

      assert Jason.decode!(native_input) === Jason.decode!(source_input)

      assert {:ok, value} = Result.decode(vector["completion"]["text"], request.schema)
      assert {:ok, rendered} = Result.present(value)
      assert rendered.details === %{json: vector["result"]["details"]["json"]}
      [source_content] = vector["result"]["content"]
      assert Jason.decode!(rendered.content) === Jason.decode!(source_content["text"])
    end
  end
end
