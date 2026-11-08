defmodule Synapsis.Web.ScrapeFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Web.Scrape

  test "identical ordinary calls perform two HTTP requests without a local result cache" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()

    Gaoxy.Test.stub(fixture, "POST", "/v2/scrape", fn conn ->
      {:ok, body, _} = Plug.Conn.read_body(conn)
      send(owner, {:scrape_request, Jason.decode!(body)})

      payload = %{
        "data" => %{
          "markdown" => "  ordinary scrape\n",
          "metadata" => %{"title" => " Title ", "statusCode" => 200}
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
    end)

    config = %{
      api_key: "ordinary-fixture-key",
      credential_id: "fixture",
      credential_version: "1",
      base_url: Gaoxy.Test.url(fixture),
      timeout_ms: 5_000
    }

    args = %{"url" => "https://source.example/a", "maxAgeMs" => 0, "storeInCache" => false}
    assert {:ok, first} = Scrape.scrape(config, args)
    assert {:ok, second} = Scrape.scrape(config, args)
    assert first == second

    assert first == %{
             "url" => args["url"],
             "finalUrl" => args["url"],
             "extractor" => "firecrawl",
             "extractMode" => "markdown",
             "text" => "  ordinary scrape\n",
             "title" => " Title ",
             "status" => 200,
             "rawLength" => 18,
             "length" => 18,
             "truncated" => false
           }

    assert_receive {:scrape_request, body}
    assert_receive {:scrape_request, ^body}
    assert body["maxAge"] == 0
    assert body["storeInCache"] == false
  end
end
