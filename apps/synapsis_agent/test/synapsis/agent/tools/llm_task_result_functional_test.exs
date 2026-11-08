defmodule Synapsis.Agent.Tools.LLMTaskResultFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Tools.LLMTask.Result

  @fixture Path.expand("../../../fixtures/openclaw/488631c/llm-task.json", __DIR__)
  @expected [
    {"primary-string", %{"ok" => true, "text" => "雪😀"}},
    {"primary-object", nil},
    {"plugin-defaults", true},
    {"request-overrides", 0},
    {"explicit-provider-nested", " padded value "},
    {"configured-alias", [1, nil, "雪😀"]},
    {"configured-provider-alias", false},
    {"fenced-object", %{"nested" => [1, false, nil]}},
    {"fenced-array", ["a", 2]},
    {"valid-schema", %{"kind" => "ok", "count" => 2}},
    {"local-ref-schema", ["one", "雪😀"]},
    {"plugin-timeout-token-only", "done"}
  ]
  @whitespace [
    0x0009,
    0x000A,
    0x000B,
    0x000C,
    0x000D,
    0x0020,
    0x00A0,
    0x1680,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2007,
    0x2008,
    0x2009,
    0x200A,
    0x2028,
    0x2029,
    0x202F,
    0x205F,
    0x3000,
    0xFEFF
  ]

  test "decodes all twelve frozen callback results without injecting schema defaults" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert Enum.map(fixture["vectors"], & &1["id"]) == Enum.map(@expected, &elem(&1, 0))

    for {vector, {id, expected}} <- Enum.zip(fixture["vectors"], @expected) do
      assert vector["id"] == id
      assert vector["result"]["details"]["json"] === expected

      assert Result.decode(vector["completion"]["text"], vector["arguments"]["schema"]) ===
               {:ok, expected}
    end
  end

  test "keeps every JSON root type with object schemas and scalar constraints" do
    cases = [
      {"null", %{"type" => "null"}, nil},
      {"true", %{"type" => "boolean"}, true},
      {"4", %{"type" => "integer", "minimum" => 1, "maximum" => 5}, 4},
      {"1.25", %{"type" => "number", "multipleOf" => 0.25}, 1.25},
      {"\"雪😀\"", %{"type" => "string", "minLength" => 2, "maxLength" => 2}, "雪😀"},
      {"[1,2]", %{"type" => "array", "items" => %{"type" => "integer"}}, [1, 2]},
      {"{}", %{"type" => "object", "additionalProperties" => false}, %{}}
    ]

    for {text, schema, expected} <- cases do
      assert Result.decode(text, schema) === {:ok, expected}
    end
  end

  test "uses valid local references, applicators and object constraints without rewriting values" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => %{
        "score" => %{
          "allOf" => [%{"type" => "integer"}, %{"minimum" => 1, "maximum" => 5}]
        }
      },
      "type" => "object",
      "properties" => %{
        "score" => %{"$ref" => "#/$defs/score"},
        "choice" => %{"oneOf" => [%{"const" => "雪😀"}, %{"type" => "integer"}]},
        "items" => %{
          "type" => "array",
          "items" => %{"anyOf" => [%{"type" => "null"}, %{"type" => "boolean"}]},
          "minItems" => 2,
          "maxItems" => 2,
          "uniqueItems" => true
        },
        "optional" => %{"type" => "string", "default" => "unused"}
      },
      "required" => ["score", "choice", "items"],
      "additionalProperties" => false
    }

    expected = %{"score" => 4, "choice" => "雪😀", "items" => [nil, true]}

    assert Result.decode(~s({"score":4,"choice":"雪😀","items":[null,true]}), schema) ===
             {:ok, expected}
  end

  test "accepts ECMAScript boundary whitespace and complete mixed-case JSON fences" do
    for codepoint <- @whitespace do
      whitespace = <<codepoint::utf8>>
      assert Result.decode(whitespace <> "\" 雪😀 \"" <> whitespace) == {:ok, " 雪😀 "}

      fenced =
        whitespace <>
          "```jSoN" <> whitespace <> "[null,\"雪😀\"]" <> whitespace <> "```" <> whitespace

      assert Result.decode(fenced) == {:ok, [nil, "雪😀"]}
    end
  end

  test "retains successful format and encoded-content annotation values" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "email" => %{"type" => "string", "format" => "email"},
        "payload" => %{
          "type" => "string",
          "contentEncoding" => "base64",
          "contentMediaType" => "text/plain"
        }
      },
      "required" => ["email", "payload"]
    }

    assert Result.decode(~s({"email":"user@example.test","payload":"SGVsbG8="}), schema) ===
             {:ok, %{"email" => "user@example.test", "payload" => "SGVsbG8="}}
  end
end
