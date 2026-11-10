defmodule Synapsis.Provider.GrokSearchFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Synapsis.Provider.WebSearch
  alias Synapsis.Provider.WebSearch.Grok

  test "all 48 pinned HTTP callbacks match exact pure requests and complete raw provider maps" do
    reference = reference()

    callbacks =
      for group <- reference["groups"], step <- group["steps"], step["request"], do: {group, step}

    assert length(reference["groups"]) == 41
    assert length(callbacks) == 48

    for {group, step} <- callbacks do
      source = step["request"]
      selected = config(step)
      assert {:ok, prepared} = Grok.prepare_config(selected)
      assert WebSearch.prepare_config(selected) == {:ok, prepared}
      assert Grok.prepare_config(prepared) == {:ok, prepared}
      assert {:ok, args} = Grok.prepare(prepared, step["arguments"])
      assert WebSearch.prepare(prepared, step["arguments"]) == {:ok, args}
      assert args == %{"query" => String.trim(step["arguments"]["query"])}, group["id"]
      assert {:ok, :post, url, headers, body} = Grok.request(prepared, args)
      assert url == source["url"], group["id"]
      assert Map.new(headers) == source["headers"], group["id"]
      assert body == source["body"], group["id"]
      assert {:ok, raw} = Grok.result(prepared, args, group["httpPayload"])
      expected = Map.delete(step["providerPortableResult"], "tookMs")
      assert Map.merge(raw, %{"provider" => "grok", "query" => args["query"]}) == expected

      fixture = Gaoxy.Test.open()

      try do
        owner = self()

        Gaoxy.Test.stub(fixture, "POST", source["path"], fn conn ->
          {:ok, encoded, conn} = Plug.Conn.read_body(conn)

          send(
            owner,
            {:grok_post, conn.method, conn.request_path, conn.query_string,
             Jason.decode!(encoded), conn.req_headers}
          )

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(group["httpPayload"]))
        end)

        base_path = URI.parse(prepared.base_url).path || ""

        local_base =
          if base_path == "",
            do: String.trim_trailing(Gaoxy.Test.url(fixture), "/"),
            else: Gaoxy.Test.url(fixture, base_path)

        assert {:ok, actual} =
                 WebSearch.search(%{prepared | base_url: local_base}, step["arguments"])

        assert Map.delete(actual, "tookMs") == expected, group["id"]
        assert is_integer(actual["tookMs"]) and actual["tookMs"] >= 0
        assert_receive {:grok_post, "POST", path, "", actual_body, actual_headers}, 5000
        assert path == source["path"], group["id"]
        assert actual_body == source["body"], group["id"]
        assert Map.take(Map.new(actual_headers), Map.keys(source["headers"])) == source["headers"]
        assert step["arguments"] == step["argumentsAfter"]
        assert step["setup"] == step["setupAfter"]
      after
        Gaoxy.Test.close(fixture)
      end
    end
  end

  test "endpoint preparation trims only the root and is idempotent before blindly appending responses" do
    for {input, root} <- [
          {nil, "https://api.x.ai/v1"},
          {"https://api.x.ai/", "https://api.x.ai"},
          {" https://api.x.ai/v1/// ", "https://api.x.ai/v1"},
          {"https://proxy.example/Case/", "https://proxy.example/Case"},
          {"https://proxy.example/v1/responses/", "https://proxy.example/v1/responses"}
        ] do
      selected = %{
        provider: "grok",
        base_url: input,
        api_key: "fixture-grok-key",
        timeout_ms: 60_000,
        count: 5,
        mode: "web"
      }

      assert Grok.endpoint(input) == {:ok, root}
      assert {:ok, prepared} = Grok.prepare_config(selected)
      assert prepared.base_url == root
      assert prepared.model == "grok-4.7"
      assert prepared.inline_citations == false
      assert Grok.prepare_config(prepared) == {:ok, prepared}
      assert WebSearch.prepare_config(prepared) == {:ok, prepared}
      assert {:ok, args} = Grok.prepare(prepared, %{"query" => " ordinary root ", "count" => 2})
      assert {:ok, :post, url, headers, body} = Grok.request(prepared, args)
      assert url == root <> "/responses"

      assert Map.new(headers) == %{
               "accept" => "application/json",
               "authorization" => "Bearer fixture-grok-key",
               "content-type" => "application/json"
             }

      assert body == %{
               "model" => "grok-4.7",
               "input" => [%{"role" => "user", "content" => "ordinary root"}],
               "tools" => [%{"type" => "web_search"}],
               "store" => false,
               "reasoning" => %{"effort" => "low"}
             }
    end
  end

  defp config(step) do
    options =
      get_in(step, ["setup", "config", "plugins", "entries", "xai", "config", "webSearch"])

    search = step["setup"]["searchConfig"]

    %{
      provider: "grok",
      base_url: options["baseUrl"],
      api_key: "fixture-grok-key",
      model: options["model"],
      inline_citations: Map.get(options, "inlineCitations", false),
      timeout_ms: Map.get(search, "timeoutSeconds", 60) * 1000,
      count: Map.get(search, "maxResults", 5),
      mode: "web"
    }
  end

  defp reference do
    Path.expand(
      "../../../../synapsis_agent/test/fixtures/openclaw/488631c/grok-search.json",
      __DIR__
    )
    |> File.read!()
    |> Jason.decode!()
  end
end
