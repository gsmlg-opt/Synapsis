defmodule Synapsis.Provider.Decision.OpenRouterFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Provider.Decision
  alias Synapsis.Provider.Decision.OpenRouter

  setup do
    {:ok, tasks: start_supervised!({Task.Supervisor, []})}
  end

  test "three explicit Jev models preserve native state questions preferences and output", %{
    tasks: tasks
  } do
    for model <- ~w(typesafe/jev-1.13 typesafe/jev-1.14 ~typesafe/jev-latest) do
      fixture = Gaoxy.Test.open()
      {:ok, batch} = Decision.normalize(arguments())

      options =
        config(Gaoxy.Test.url(fixture, "/tenant/api/v1"), model)
        |> Map.put(:headers, %{"X-Decision-Route" => "explicit"})
        |> Map.put(:params, %{"provider" => %{"order" => ["TypeSafe"], "only" => ["TypeSafe"]}})

      assert {:ok, built} = OpenRouter.build_request(batch, options)
      assert built.url == Gaoxy.Test.url(fixture, "/tenant/api/v1/systemone")
      assert built.body == request(model)

      Gaoxy.Test.expect_once(fixture, "POST", "/tenant/api/v1/systemone", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == request(model)
        assert Plug.Conn.get_req_header(conn, "x-decision-route") == ["explicit"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response()))
      end)

      assert {:ok, actual} =
               Task.Supervisor.async_nolink(tasks, fn -> OpenRouter.evaluate(batch, options) end)
               |> Task.await(10_000)

      assert actual == outcome()
      Gaoxy.Test.verify_and_close!(fixture)
    end
  end

  test "Jev 1.14 and latest accept supplied PNG and JPEG boxes without changing coordinates", %{
    tasks: tasks
  } do
    for model <- ~w(typesafe/jev-1.14 ~typesafe/jev-latest),
        mime <- ~w(png jpeg),
        caption <- [nil, "", "Locate the supplied object"] do
      fixture = Gaoxy.Test.open()
      state = %{"type" => "image", "dataUri" => "data:image/#{mime};base64,AA=="}
      state = if caption == nil, do: state, else: Map.put(state, "text", caption)

      args = %{
        "contractVersion" => 2,
        "state" => state,
        "questions" => %{"target" => %{"type" => "box", "instructions" => "Locate object"}}
      }

      {:ok, batch} = Decision.normalize(args)
      box = %{"top" => 0.25, "bottom" => 0.75, "left" => 0.25, "right" => 0.76}

      wire = %{
        response()
        | "answers" => %{"target" => %{"type" => "box", "box" => box, "confidence" => 0.91}}
      }

      Gaoxy.Test.expect_once(fixture, "POST", "/v1/systemone", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        expected_state =
          if(caption == nil, do: [], else: [caption]) ++
            [%{"type" => "image_url", "image_url" => %{"url" => state["dataUri"]}}]

        assert Jason.decode!(body) == %{
                 "model" => model,
                 "state" => expected_state,
                 "questions" => args["questions"]
               }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(wire))
      end)

      assert {:ok, %{"status" => "ok", "result" => result}} =
               Task.Supervisor.async_nolink(tasks, fn ->
                 OpenRouter.evaluate(batch, config(Gaoxy.Test.url(fixture, "/v1"), model))
               end)
               |> Task.await(10_000)

      assert result["answers"]["target"] == %{"type" => "box", "box" => box, "confidence" => 0.91}
      Gaoxy.Test.verify_and_close!(fixture)
    end
  end

  test "usage keeps absent cost explicit zero and complete additional raw usage", %{
    tasks: tasks
  } do
    {:ok, batch} = Decision.normalize(arguments())

    for usage <- [
          %{"input_tokens" => 0, "output_tokens" => 0, "cost" => 0},
          %{"input_tokens" => 3, "output_tokens" => 1},
          %{"input_tokens" => 2, "output_tokens" => 1, "provider_units" => 3}
        ] do
      fixture = Gaoxy.Test.open()
      wire = Map.put(response(), "usage", usage) |> Map.delete("provider")

      Gaoxy.Test.expect_once(fixture, "POST", "/v1/systemone", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(wire))
      end)

      assert {:ok, %{"status" => "ok", "result" => result}} =
               Task.Supervisor.async_nolink(tasks, fn ->
                 OpenRouter.evaluate(
                   batch,
                   config(Gaoxy.Test.url(fixture, "/v1"), "typesafe/jev-1.13")
                 )
               end)
               |> Task.await(10_000)

      expected = %{
        "inputTokens" => usage["input_tokens"],
        "outputTokens" => usage["output_tokens"]
      }

      expected =
        if Map.has_key?(usage, "cost"),
          do: Map.put(expected, "costUsd", usage["cost"]),
          else: expected

      expected =
        if Map.has_key?(usage, "provider_units"),
          do: Map.put(expected, "raw", usage),
          else: expected

      assert result["usage"] == expected
      assert Map.has_key?(result, "metadata") == false
      Gaoxy.Test.verify_and_close!(fixture)
    end
  end

  test "successful chunked response can occupy the complete raw byte allowance", %{
    tasks: tasks
  } do
    fixture = Gaoxy.Test.open()
    {:ok, batch} = Decision.normalize(arguments())
    body = Jason.encode!(response())
    body = body <> String.duplicate(" ", 1_048_576 - byte_size(body))

    Gaoxy.Test.expect_once(fixture, "POST", "/v1/systemone", fn conn ->
      conn =
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_chunked(200)

      <<first::binary-size(17), rest::binary>> = body
      {:ok, conn} = Plug.Conn.chunk(conn, first)
      {:ok, conn} = Plug.Conn.chunk(conn, rest)
      conn
    end)

    assert {:ok, actual} =
             Task.Supervisor.async_nolink(tasks, fn ->
               OpenRouter.evaluate(
                 batch,
                 config(Gaoxy.Test.url(fixture, "/v1"), "typesafe/jev-1.13")
               )
             end)
             |> Task.await(10_000)

    assert actual == outcome()
  end

  @reference Path.expand("../../../fixtures/openclaw/488631c/openrouter-decisions.json", __DIR__)

  test "all pinned OpenClaw source vectors match exact native wire requests and successful outcomes",
       %{tasks: tasks} do
    reference = @reference |> File.read!() |> Jason.decode!()
    assert reference["referencePin"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(reference["observations"]) == 16

    for row <- reference["observations"] do
      fixture = Gaoxy.Test.open()
      assert {:ok, batch} = Decision.normalize(row["arguments"])
      assert batch == row["batch"]
      prefix = URI.parse(row["baseUrl"]).path

      options =
        config(Gaoxy.Test.url(fixture, prefix), row["model"]) |> Map.put(:params, row["params"])

      assert {:ok, built} = OpenRouter.build_request(batch, options)
      assert built.url == Gaoxy.Test.url(fixture, prefix <> "/systemone")
      assert built.body == row["request"]["body"]
      assert row["request"]["url"] == String.trim_trailing(row["baseUrl"], "/") <> "/systemone"

      Gaoxy.Test.expect_once(fixture, "POST", prefix <> "/systemone", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == row["request"]["body"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(row["response"]))
      end)

      assert {:ok, actual} =
               Task.Supervisor.async_nolink(tasks, fn -> OpenRouter.evaluate(batch, options) end)
               |> Task.await(10_000)

      assert actual == row["outcome"], row["id"]
      Gaoxy.Test.verify_and_close!(fixture)
    end
  end

  defp config(base_url, model),
    do: %{
      base_url: base_url,
      api_key: "router-decision-fixture",
      model: model,
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

  defp arguments do
    %{
      "contractVersion" => 2,
      "state" => %{"type" => "json", "value" => %{"ticket" => "Synthetic ticket"}},
      "questions" => %{
        "q" => %{"type" => "boolean", "instructions" => "Is this urgent?"},
        "c" => %{
          "type" => "choice",
          "instructions" => "Which team?",
          "criteria" => %{"a" => nil, "b" => "Billing"}
        },
        "s" => %{
          "type" => "score",
          "instructions" => "How urgent?",
          "criteria" => ["Low", "High"]
        }
      }
    }
  end

  defp request(model) do
    %{
      "model" => model,
      "state" => %{"ticket" => "Synthetic ticket"},
      "questions" => put_in(arguments()["questions"], ["q", "type"], "noul"),
      "provider" => %{"order" => ["TypeSafe"], "only" => ["TypeSafe"]}
    }
  end

  defp response do
    %{
      "model" => "typesafe/jev-served",
      "provider" => "TypeSafe",
      "answers" => %{
        "q" => %{"type" => "noul", "noul" => 0.37},
        "c" => %{
          "type" => "choice",
          "choice" => "a",
          "probabilities" => %{"a" => 0.49, "b" => 0.5},
          "confidence" => 0.1
        },
        "s" => %{
          "type" => "score",
          "score" => 0.71,
          "probabilities" => %{"0" => 0.3, "1" => 0.69},
          "confidence" => 0.2
        }
      },
      "usage" => %{"input_tokens" => 476, "output_tokens" => 70, "cost" => 0.000019992}
    }
  end

  defp outcome do
    %{
      "status" => "ok",
      "result" => %{
        "model" => "typesafe/jev-served",
        "metadata" => %{"provider" => "TypeSafe"},
        "answers" => %{
          "q" => %{"type" => "boolean", "probabilityTrue" => 0.37},
          "c" => %{
            "type" => "choice",
            "choice" => "a",
            "probabilities" => %{"a" => 0.49, "b" => 0.5},
            "confidence" => 0.1
          },
          "s" => %{
            "type" => "score",
            "score" => 0.71,
            "probabilities" => [0.3, 0.69],
            "confidence" => 0.2
          }
        },
        "usage" => %{"inputTokens" => 476, "outputTokens" => 70, "costUsd" => 0.000019992}
      }
    }
  end
end
