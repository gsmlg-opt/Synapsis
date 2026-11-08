defmodule Synapsis.Provider.WebExtract.TavilyFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.WebExtract.Tavily
  alias Synapsis.Provider.WebSearch.TextBudget

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "preparation trims source arguments and preserves URL order and duplicates" do
    arguments = %{
      "urls" => [" https://one.example/a ", "https://two.example/b", "https://one.example/a"],
      "query" => " focused passage ",
      "extract_depth" => " advanced ",
      "chunks_per_source" => 5,
      "include_images" => true
    }

    assert {:ok, prepared} = Tavily.prepare(%{}, arguments)

    assert prepared == %{
             arguments
             | "urls" => [
                 "https://one.example/a",
                 "https://two.example/b",
                 "https://one.example/a"
               ],
               "query" => "focused passage",
               "extract_depth" => "advanced"
           }

    assert hd(arguments["urls"]) == " https://one.example/a "

    assert {:ok, %{"urls" => ["https://one.example/a"]}} =
             Tavily.prepare(%{}, %{
               "urls" => [" https://one.example/a "],
               "include_images" => false
             })
  end

  test "basic POST preserves proxy query and projects only extraction fields", context do
    owner = self()

    stub(context, "/proxy/extract", fn conn, body ->
      send(
        owner,
        {:request, Plug.Conn.fetch_query_params(conn).query_params, conn.req_headers, body}
      )

      %{
        "results" => [
          %{
            "url" => "https://source.example",
            "raw_content" => "  source text\n",
            "title" => "discard",
            "score" => 1
          }
        ],
        "request_id" => "discard",
        "response_time" => 0.1
      }
    end)

    assert {:ok, result} =
             Tavily.extract(config(context, "/proxy/?route=ordinary"), %{
               "urls" => [" https://source.example "],
               "include_images" => false
             })

    assert_receive {:request, %{"route" => "ordinary"}, headers,
                    %{"urls" => ["https://source.example"]}}

    assert {"accept", "application/json"} in headers
    assert {"content-type", "application/json"} in headers
    assert {"x-client-source", "openclaw"} in headers

    assert result["results"] == [
             %{"url" => "https://source.example", "rawContent" => "  source text\n"}
           ]

    assert result["provider"] == "tavily"
    assert result["count"] == 1
    assert is_integer(result["tookMs"]) and result["tookMs"] >= 0
    assert Enum.sort(Map.keys(result)) == ~w(count provider results tookMs)
  end

  test "full POST options and empty optional result values survive", context do
    owner = self()

    args = %{
      "urls" => ["https://one.example/a", "https://two.example/b", "https://one.example/a"],
      "query" => "focused passage",
      "extract_depth" => "advanced",
      "chunks_per_source" => 5,
      "include_images" => true
    }

    stub(context, "/extract", fn _, body ->
      send(owner, {:body, body})

      %{
        "results" => [
          %{
            "url" => "https://ONE.example:443/a",
            "raw_content" => "raw",
            "content" => "",
            "images" => []
          },
          %{
            "url" => "http://TWO.example:80/b",
            "content" => "  passage  ",
            "images" => ["https://IMAGE.example:443/picture.png"]
          }
        ]
      }
    end)

    assert {:ok, result} = Tavily.extract(config(context), args)
    assert_receive {:body, ^args}

    assert result["results"] == [
             %{
               "url" => "https://one.example/a",
               "rawContent" => "raw",
               "content" => "",
               "images" => []
             },
             %{
               "url" => "http://two.example/b",
               "rawContent" => "",
               "content" => "  passage  ",
               "images" => ["https://image.example/picture.png"]
             }
           ]
  end

  test "twenty successful rows fit and twenty-one rows set truncation", context do
    rows =
      for i <- 1..21,
          do: %{"url" => "https://source.example/#{i}", "raw_content" => "passage #{i}"}

    stub(context, "/twenty/extract", fn _, _ -> %{"results" => Enum.take(rows, 20)} end)
    stub(context, "/extra/extract", fn _, _ -> %{"results" => rows} end)
    args = %{"urls" => ["https://source.example"]}
    assert {:ok, exact} = Tavily.extract(config(context, "/twenty"), args)
    assert exact["count"] == 20
    assert Map.keys(exact) |> Enum.sort() == ~w(count provider results tookMs)
    assert {:ok, extra} = Tavily.extract(config(context, "/extra"), args)
    assert extra["count"] == 20
    assert extra["truncated"] == true

    assert Enum.map(extra["results"], & &1["url"]) ==
             Enum.map(1..20, &"https://source.example/#{&1}")
  end

  test "images share a twenty-image budget across ordinary rows", context do
    images = for i <- 1..21, do: "https://images.example/#{i}.png"

    stub(context, "/extract", fn _, _ ->
      %{
        "results" => [
          %{
            "url" => "https://one.example",
            "raw_content" => "one",
            "images" => Enum.take(images, 12)
          },
          %{
            "url" => "https://two.example",
            "raw_content" => "two",
            "images" => Enum.drop(images, 12)
          }
        ]
      }
    end)

    assert {:ok, result} =
             Tavily.extract(config(context), %{
               "urls" => ["https://one.example", "https://two.example"],
               "include_images" => true
             })

    assert Enum.flat_map(result["results"], & &1["images"]) == Enum.take(images, 20)
    assert result["truncated"] == true
  end

  test "shared UTF16 budget charges raw content before content and preserves scalar prefixes",
       context do
    vectors = [
      {"supplementary", String.duplicate("a", 19_999), "😀tail", ""},
      {"combining", String.duplicate("a", 19_998), "étail", "é"},
      {"zwj", String.duplicate("a", 19_996), "👩‍💻tail", "👩‍"}
    ]

    for {name, prefix, content, expected} <- vectors do
      stub(context, "/#{name}/extract", fn _, _ ->
        %{
          "results" => [
            %{"url" => "https://one.example", "raw_content" => prefix, "content" => content},
            %{"url" => "https://two.example", "raw_content" => "later", "content" => ""}
          ]
        }
      end)

      assert {:ok, result} =
               Tavily.extract(config(context, "/#{name}"), %{"urls" => ["https://one.example"]})

      assert result["results"] == [
               %{"url" => "https://one.example", "rawContent" => prefix, "content" => expected},
               %{
                 "url" => "https://two.example",
                 "rawContent" =>
                   if(name == "supplementary",
                     do: "l",
                     else: if(name == "zwj", do: "l", else: "")
                   ),
                 "content" => ""
               }
             ]

      assert Enum.reduce(result["results"], 0, fn row, n ->
               n + TextBudget.units(row["rawContent"]) + TextBudget.units(row["content"])
             end) == 20_000

      assert result["truncated"] == true
    end
  end

  test "exact shared prose boundary preserves whitespace without truncation", context do
    first = "  " <> String.duplicate("a", 9_998)
    second = String.duplicate("b", 9_999) <> "\n"

    stub(context, "/extract", fn _, _ ->
      %{
        "results" => [
          %{"url" => "https://source.example", "raw_content" => first, "content" => second}
        ]
      }
    end)

    assert {:ok, result} =
             Tavily.extract(config(context), %{"urls" => ["https://source.example"]})

    assert result["results"] == [
             %{"url" => "https://source.example", "rawContent" => first, "content" => second}
           ]

    assert Map.keys(result) |> Enum.sort() == ~w(count provider results tookMs)
  end

  @tag timeout: 30_000
  test "successful raw payload above sixteen MiB uses the extraction transport bound", context do
    text = String.duplicate("x", 16 * 1024 * 1024 + 1)

    stub(context, "/extract", fn _, _ ->
      %{"results" => [%{"url" => "https://large.example", "raw_content" => text}]}
    end)

    assert {:ok, result} = Tavily.extract(config(context), %{"urls" => ["https://large.example"]})

    assert result["results"] == [
             %{"url" => "https://large.example", "rawContent" => String.duplicate("x", 20_000)}
           ]

    assert result["truncated"] == true
  end

  test "whole pinned extraction factory groups replay exact ordinary HTTP and result semantics" do
    reference =
      Path.expand(
        "../../../../../synapsis_agent/test/fixtures/openclaw/488631c/tavily-extract.json",
        __DIR__
      )
      |> File.read!()
      |> Jason.decode!()

    for group <- reference["groups"] do
      step = Enum.find(group["steps"], &is_map(&1["request"]))
      request = step["request"]
      expected_uri = URI.parse(request["url"])
      fixture = Gaoxy.Test.open()
      owner = self()
      id = group["id"]

      try do
        Gaoxy.Test.stub(fixture, request["method"], expected_uri.path, fn conn ->
          {:ok, body, _} = Plug.Conn.read_body(conn)
          query = Plug.Conn.fetch_query_params(conn).query_params

          send(
            owner,
            {:reference_http, id, conn.method, conn.request_path, query,
             Map.new(conn.req_headers), Jason.decode!(body)}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
        end)

        local = URI.parse(Gaoxy.Test.url(fixture))
        base_path = String.replace_suffix(expected_uri.path, "/extract", "")
        base_url = URI.to_string(%{local | path: base_path, query: expected_uri.query})
        config = %{base_url: base_url, api_key: "ordinary-fixture-key", timeout_ms: 60_000}

        assert {:ok, prepared} = Tavily.prepare(config, step["arguments"])
        assert prepared == request["body"], id
        assert {:ok, actual} = Tavily.extract(config, step["arguments"])

        assert Map.delete(actual, "tookMs") ==
                 Map.drop(step["resultUnframed"], ["externalContent", "tookMs"]),
               id

        assert_receive {:reference_http, ^id, method, path, query, headers, body}
        assert method == request["method"], id
        assert path == expected_uri.path, id
        assert query == request["query"], id
        assert body == request["body"], id
        expected_headers = Map.drop(request["headers"], ["authorization"])
        assert Map.take(headers, Map.keys(expected_headers)) == expected_headers, id
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  defp config(context, path \\ "") do
    %{
      api_key: "ordinary-fixture-key",
      base_url: String.trim_trailing(Gaoxy.Test.url(context.fixture), "/") <> path,
      timeout_ms: 10_000,
      credential_id: "fixture",
      credential_version: "1"
    }
  end

  defp stub(context, path, response) do
    Gaoxy.Test.stub(context.fixture, "POST", path, fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      payload = response.(conn, Jason.decode!(body))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)
  end
end
