defmodule Synapsis.Provider.Decision.OpenAIFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Decision
  alias Synapsis.Provider.Decision.OpenAI

  @reference Path.expand("../../../fixtures/openclaw/488631c/openai-decisions.json", __DIR__)
  @ids ~w(text-three json-three legacy-text legacy-null legacy-array image-text image-only missing-instructions null-instructions explicit-choice-estimates custom-api-prefix)

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, fixture: fixture, tasks: tasks}
  end

  test "legacy evidence converts without changing text, null or array order" do
    questions = %{"question" => %{"type" => "boolean"}}

    for {evidence, state} <- [
          {"  Evidence 雪\n", %{"type" => "text", "text" => "  Evidence 雪\n"}},
          {nil, %{"type" => "json", "value" => nil}},
          {["b", "a"], %{"type" => "json", "value" => ["b", "a"]}},
          {%{"z" => 2, "a" => 1}, %{"type" => "json", "value" => %{"z" => 2, "a" => 1}}}
        ] do
      assert {:ok, batch} = Decision.normalize(%{"state" => evidence, "questions" => questions})
      assert batch == %{"state" => state, "questions" => questions}
    end
  end

  test "canonical rubric excludes evidence and preserves arrays and explicit null" do
    assert Decision.canonical_json(%{"z" => ["b", "a"], "a" => nil}) ==
             ~s({"a":null,"z":["b","a"]})

    {:ok, batch} = Decision.normalize(input())
    canonical = Decision.canonical_json(batch["questions"])

    expected =
      "synapsis-decision-v1-" <>
        binary_part(Base.encode16(:crypto.hash(:sha256, canonical), case: :lower), 0, 24)

    assert Decision.rubric_version(batch) == expected

    assert Decision.rubric_version(
             Map.put(batch, "state", %{"type" => "text", "text" => "other"})
           ) == expected
  end

  test "builds canonical native predicate, choice and score requests with a required model" do
    assert {:ok, batch} = Decision.normalize(input())

    assert {:ok, built} =
             OpenAI.build_request(batch, config("https://fixture.example/custom/v1///"))

    assert built.url == "https://fixture.example/custom/v1/decisions"
    assert built.max_response_bytes == 1_048_576
    assert built.timeout_ms > 0 and built.timeout_ms <= 5_000
    assert built.body == request()
  end

  test "omitted and null entries remain distinct native instructions" do
    for {question, expected} <- [
          {%{"type" => "boolean"}, ""},
          {%{"type" => "boolean", "instructions" => nil}, "null"},
          {%{"type" => "boolean", "criteria" => %{}}, "\nTrue criterion: \nFalse criterion: "},
          {%{"type" => "boolean", "criteria" => %{"true" => nil}},
           "\nTrue criterion: null\nFalse criterion: "},
          {%{"type" => "boolean", "criteria" => nil}, ""}
        ] do
      assert {:ok, batch} =
               Decision.normalize(%{
                 "contractVersion" => 2,
                 "state" => %{"type" => "text", "text" => "x"},
                 "questions" => %{"q" => question}
               })

      assert {:ok, built} = OpenAI.build_request(batch, config("https://fixture.example/v1"))
      assert [%{"instructions" => ^expected}] = built.body["questions"]
    end
  end

  test "tagged JSON scalars remain JSON and images preserve supplied content order" do
    for value <- ["text encoded as JSON", true, 1.25, nil] do
      assert {:ok, batch} =
               Decision.normalize(%{
                 "contractVersion" => 2,
                 "state" => %{"type" => "json", "value" => value},
                 "questions" => %{"q" => %{"type" => "boolean"}}
               })

      assert {:ok, built} = OpenAI.build_request(batch, config("https://fixture.example/v1"))
      assert built.body["input"] == Decision.canonical_json(value)
    end

    for mime <- ~w(png jpeg webp), text <- [nil, "", "Caption 雪"] do
      uri = "data:image/" <> mime <> ";base64,AQID"
      state = %{"type" => "image", "dataUri" => uri}
      state = if text == nil, do: state, else: Map.put(state, "text", text)

      assert {:ok, batch} =
               Decision.normalize(%{
                 "contractVersion" => 2,
                 "state" => state,
                 "questions" => %{"q" => %{"type" => "boolean"}}
               })

      assert {:ok, built} = OpenAI.build_request(batch, config("https://fixture.example/v1"))
      prefix = if text in [nil, ""], do: [], else: [%{"type" => "input_text", "text" => text}]

      assert built.body["input"] == [
               %{
                 "role" => "user",
                 "content" => prefix ++ [%{"type" => "input_image", "image_url" => uri}]
               }
             ]
    end
  end

  test "ordinary supported question and choice ceilings are representable" do
    questions = Map.new(1..400, fn i -> {"q#{i}", %{"type" => "boolean"}} end)

    assert {:ok, batch} =
             Decision.normalize(%{
               "contractVersion" => 2,
               "state" => %{"type" => "text", "text" => "x"},
               "questions" => questions
             })

    assert {:ok, built} = OpenAI.build_request(batch, config("https://fixture.example/v1"))
    assert length(built.body["questions"]) == 400

    criteria = Map.new(1..255, fn i -> {"c#{i}", "choice #{i}"} end)

    assert {:ok, batch} =
             Decision.normalize(%{
               "state" => "x",
               "questions" => %{"q" => %{"type" => "choice", "criteria" => criteria}}
             })

    assert {:ok, built} = OpenAI.build_request(batch, config("https://fixture.example/v1"))
    assert length(hd(built.body["questions"])["choices"]) == 255
  end

  test "real native HTTP keeps provider decisions, fractional score, nonnormalized estimates and usage",
       %{fixture: fixture, tasks: tasks} do
    owner = self()

    Gaoxy.Test.expect_once(fixture, "POST", "/custom/v1/decisions", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == request()
      send(owner, {:decision_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response()))
    end)

    {:ok, batch} = Decision.normalize(input())

    assert {:ok, outcome} =
             tasks
             |> Task.Supervisor.async_nolink(fn ->
               OpenAI.evaluate(batch, config(Gaoxy.Test.url(fixture, "/custom/v1")))
             end)
             |> Task.await(10_000)

    assert outcome == outcome()
    assert_receive {:decision_request, _}, 1_000
  end

  test "successful response can occupy its complete raw byte budget and arrive in chunks", %{
    fixture: fixture,
    tasks: tasks
  } do
    body = Jason.encode!(response())
    body = body <> String.duplicate(" ", 1_048_576 - byte_size(body))

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/decisions", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      conn =
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_chunked(200)

      <<first::binary-size(17), rest::binary>> = body
      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, rest)
      conn
    end)

    {:ok, batch} = Decision.normalize(input())

    assert {:ok, actual} =
             tasks
             |> Task.Supervisor.async_nolink(fn ->
               OpenAI.evaluate(batch, config(Gaoxy.Test.url(fixture, "/v1")))
             end)
             |> Task.await(10_000)

    assert actual == outcome()
  end

  test "every whole-source positive vector retains its normalized batch and native request" do
    capture = @reference |> File.read!() |> Jason.decode!()
    assert capture["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert Enum.map(capture["observations"], & &1["id"]) == @ids

    for row <- capture["observations"] do
      assert {:ok, batch} = Decision.normalize(row["arguments"])
      assert batch == row["batch"], row["id"]
      options = config(row["baseUrl"]) |> Map.put(:model, row["request"]["body"]["model"])
      assert {:ok, built} = OpenAI.build_request(batch, options)
      assert built.url == row["request"]["url"], row["id"]
      assert built.body == row["request"]["body"], row["id"]
      assert built.max_response_bytes == hd(row["readerCalls"])["maxBytes"], row["id"]
    end
  end

  test "every captured native response is translated after an actual ordinary local HTTP request",
       %{fixture: fixture, tasks: tasks} do
    capture = @reference |> File.read!() |> Jason.decode!()
    owner = self()

    for row <- capture["observations"] do
      path = "/reference/" <> row["id"] <> "/v1"

      Gaoxy.Test.expect_once(fixture, "POST", path <> "/decisions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == row["request"]["body"]
        send(owner, {:reference_decision, row["id"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(row["response"]))
      end)

      assert {:ok, batch} = Decision.normalize(row["arguments"])

      options =
        config(Gaoxy.Test.url(fixture, path)) |> Map.put(:model, row["request"]["body"]["model"])

      assert {:ok, actual} =
               tasks
               |> Task.Supervisor.async_nolink(fn -> OpenAI.evaluate(batch, options) end)
               |> Task.await(10_000)

      assert actual == row["outcome"], row["id"]
      assert_receive {:reference_decision, id}, 1_000
      assert id == row["id"]
    end
  end

  defp config(base_url),
    do: %{
      base_url: base_url,
      api_key: "decision-fixture",
      model: "configured-decision-model",
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

  defp input do
    %{
      "contractVersion" => 2,
      "state" => %{
        "type" => "json",
        "value" => %{"report" => "The parcel is damaged", "count" => 2}
      },
      "questions" => %{
        "damaged" => %{
          "type" => "boolean",
          "instructions" => "Is it damaged?",
          "criteria" => %{"true" => "Damage reported", "false" => "Intact"}
        },
        "route" => %{
          "type" => "choice",
          "instructions" => "Choose a team",
          "criteria" => %{"support" => %{"handles" => "damage"}, "sales" => "New orders"}
        },
        "urgency" => %{
          "type" => "score",
          "instructions" => "Rate urgency",
          "criteria" => ["Routine", "Soon", "Immediate"]
        }
      }
    }
  end

  defp request do
    %{
      "model" => "configured-decision-model",
      "input" => ~s({"count":2,"report":"The parcel is damaged"}),
      "questions" => [
        %{
          "name" => "damaged",
          "type" => "predicate",
          "instructions" =>
            "Is it damaged?\nTrue criterion: Damage reported\nFalse criterion: Intact"
        },
        %{
          "name" => "route",
          "type" => "choice",
          "instructions" => "Choose a team",
          "choices" => [
            %{"value" => "sales", "description" => "New orders"},
            %{"value" => "support", "description" => ~s({"handles":"damage"})}
          ]
        },
        %{
          "name" => "urgency",
          "type" => "score",
          "instructions" => "Rate urgency",
          "levels" => [
            %{"label" => "0", "description" => "Routine"},
            %{"label" => "1", "description" => "Soon"},
            %{"label" => "2", "description" => "Immediate"}
          ]
        }
      ]
    }
  end

  defp response do
    %{
      "model" => "provider-returned-model",
      "answers" => [
        %{"name" => "damaged", "type" => "predicate", "probability" => 0.95},
        %{
          "name" => "route",
          "type" => "choice",
          "choice" => "support",
          "confidence" => 2.5,
          "probabilities" => [
            %{"value" => "support", "probability" => 0.2},
            %{"value" => "sales", "probability" => 0.7}
          ]
        },
        %{
          "name" => "urgency",
          "type" => "score",
          "score" => 1.25,
          "confidence" => 0.7,
          "probabilities" => [
            %{"label" => "2", "value" => 2, "probability" => 0.3},
            %{"label" => "0", "value" => 0, "probability" => 0.05},
            %{"label" => "1", "value" => 1, "probability" => 0.65}
          ]
        }
      ],
      "usage" => %{"input_tokens" => 42, "output_tokens" => 0, "total_tokens" => 42}
    }
  end

  defp outcome do
    %{
      "status" => "ok",
      "result" => %{
        "model" => "provider-returned-model",
        "answers" => %{
          "damaged" => %{"type" => "boolean", "probabilityTrue" => 0.95},
          "route" => %{
            "type" => "choice",
            "choice" => "support",
            "confidence" => 2.5,
            "probabilities" => %{"sales" => 0.7, "support" => 0.2}
          },
          "urgency" => %{
            "type" => "score",
            "score" => 1.25,
            "confidence" => 0.7,
            "probabilities" => [0.05, 0.65, 0.3]
          }
        },
        "usage" => %{"inputTokens" => 42, "outputTokens" => 0}
      }
    }
  end
end
