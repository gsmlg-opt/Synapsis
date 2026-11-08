defmodule Synapsis.Web.CitationRedirectFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Web.{CitationRedirect, Transport}

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    counter = start_supervised!({Agent, fn -> [] end})
    {:ok, fixture: fixture, counter: counter}
  end

  test "ordinary GET transport retains the complete small body and response headers", ctx do
    Gaoxy.Test.stub(ctx.fixture, "GET", "/ordinary-page", fn conn ->
      Agent.update(ctx.counter, &(&1 ++ [{conn.method, conn.request_path}]))

      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.put_resp_header("x-ordinary-page", "source")
      |> Plug.Conn.resp(200, " Ordinary page 雪🙂 ")
    end)

    assert {:ok, response} = Transport.request(URI.parse(url(ctx, "/ordinary-page")), 5000, 4096)
    assert response.status == 200
    assert response.body == " Ordinary page 雪🙂 "
    assert {"x-ordinary-page", "source"} in response.headers
    assert {"content-type", "text/plain; charset=utf-8"} in response.headers
    assert Agent.get(ctx.counter, & &1) == [{"GET", "/ordinary-page"}]
  end

  test "HEAD transport returns raw direct and redirect responses for manual traversal", ctx do
    install(ctx, "/direct", 200)
    install(ctx, "/start", 302, "./direct")

    assert {:ok, direct} = Transport.head(URI.parse(url(ctx, "/direct")), 5000)
    assert direct.status == 200
    assert direct.body == ""
    assert {:ok, redirect} = Transport.head(URI.parse(url(ctx, "/start")), 5000)
    assert redirect.status == 302
    assert redirect.body == ""
    assert {"location", "./direct"} in redirect.headers
    assert Agent.get(ctx.counter, & &1) == [{"HEAD", "/direct"}, {"HEAD", "/start"}]
  end

  test "real relative multihop HEAD chains preserve ordered duplicate citations and all metadata",
       ctx do
    install(ctx, "/grounding/start", 302, "../bridge")
    install(ctx, "/bridge", 307, "/publisher/article?edition=ordinary")
    install(ctx, "/publisher/article", 200)
    install(ctx, "/direct", 200)

    original = [
      %{"url" => url(ctx, "/grounding/start"), "title" => " First source 雪 ", "ordinary" => 1},
      %{"url" => url(ctx, "/direct")},
      %{"url" => url(ctx, "/grounding/start"), "title" => " Duplicate source 🙂 "}
    ]

    expected = [
      %{Enum.at(original, 0) | "url" => url(ctx, "/publisher/article?edition=ordinary")},
      Enum.at(original, 1),
      %{Enum.at(original, 2) | "url" => url(ctx, "/publisher/article?edition=ordinary")}
    ]

    assert {:ok, resolved} =
             CitationRedirect.resolve(original,
               allowed_hosts: [URI.parse(url(ctx, "/")).host],
               deadline_ms: System.monotonic_time(:millisecond) + 15_000,
               transport: &Transport.head/2
             )

    assert resolved == expected

    assert Enum.frequencies(Agent.get(ctx.counter, & &1)) == %{
             {"HEAD", "/grounding/start"} => 2,
             {"HEAD", "/bridge"} => 2,
             {"HEAD", "/publisher/article"} => 2,
             {"HEAD", "/direct"} => 1
           }
  end

  defp url(ctx, path), do: Gaoxy.Test.url(ctx.fixture, path)

  defp install(ctx, path, status, location \\ nil) do
    Gaoxy.Test.stub(ctx.fixture, "HEAD", path, fn conn ->
      Agent.update(ctx.counter, &(&1 ++ [{conn.method, conn.request_path}]))
      conn = if location, do: Plug.Conn.put_resp_header(conn, "location", location), else: conn
      Plug.Conn.resp(conn, status, "")
    end)
  end
end
