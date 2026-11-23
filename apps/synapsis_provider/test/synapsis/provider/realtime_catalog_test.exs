defmodule Synapsis.Provider.Realtime.CatalogTest do
  use ExUnit.Case, async: false

  alias Synapsis.Provider.Realtime.Catalog

  test "root and v1 provider URLs select the independent Realtime catalog" do
    fixture = Gaoxy.Test.open()
    base = String.trim_trailing(Gaoxy.Test.url(fixture), "/")

    Gaoxy.Test.expect_once(fixture, "GET", "/v1/realtime/models", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Formata.JSON.encode!(%{
          "data" => [%{"id" => "openai/gpt-realtime", "name" => "Realtime"}]
        })
      )
    end)

    config = %{base_url: base <> "/v1/", api_key: "fixture", type: "openai_responses"}
    assert {:ok, [%{id: "openai/gpt-realtime", name: "Realtime"}]} = Catalog.list(config)

    assert {:ok, %{models_url: models, websocket_url: socket, headers: headers}} =
             Catalog.connection(config)

    assert models == base <> "/v1/realtime/models"
    assert socket == String.replace(base, "http://", "ws://") <> "/v1/realtime"
    assert headers == [{"authorization", "Bearer fixture"}]
    assert Catalog.connection(%{config | base_url: base}) == Catalog.connection(config)
  end

  test "named endpoints and OAuth cannot silently change credential scope" do
    assert {:error, :named_endpoint_unsupported} =
             Catalog.connection(%{
               base_url: "https://backplane.example/endpoints/private/v1",
               api_key: "secret"
             })

    assert {:error, :oauth_unsupported} =
             Catalog.connection(%{base_url: "https://backplane.example/v1", oauth: true})
  end

  test "authorization failures differ from an empty configured directory" do
    fixture = Gaoxy.Test.open()
    config = %{base_url: String.trim_trailing(Gaoxy.Test.url(fixture), "/"), api_key: "fixture"}

    Gaoxy.Test.expect_once(
      fixture,
      "GET",
      "/v1/realtime/models",
      &Plug.Conn.send_resp(&1, 403, "denied")
    )

    assert {:error, :forbidden} = Catalog.list(config)

    fixture = Gaoxy.Test.open()
    config = %{config | base_url: Gaoxy.Test.url(fixture)}

    Gaoxy.Test.expect_once(fixture, "GET", "/v1/realtime/models", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"data":[]}))
    end)

    assert {:ok, []} = Catalog.list(config)
  end
end
