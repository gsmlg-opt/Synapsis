defmodule Synapsis.Tool.WebSearchTest do
  use ExUnit.Case

  alias Synapsis.Tool.WebSearch

  describe "tool metadata" do
    test "has correct name" do
      assert WebSearch.name() == "web_search"
    end

    test "has correct description" do
      assert is_binary(WebSearch.description())
      assert WebSearch.description() =~ "Search"
    end

    test "has correct parameters schema" do
      params = WebSearch.parameters()
      assert params["type"] == "object"
      assert params["required"] == ["query"]
      assert Map.has_key?(params["properties"], "query")
      assert Map.has_key?(params["properties"], "max_results")
    end

    test "has read permission level" do
      assert WebSearch.permission_level() == :read
    end

    test "has web category" do
      assert WebSearch.category() == :web
    end
  end

  describe "missing API key" do
    test "returns error when no API key is configured" do
      original = System.get_env("BRAVE_SEARCH_API_KEY")
      System.delete_env("BRAVE_SEARCH_API_KEY")
      Application.delete_env(:synapsis_core, :brave_search_api_key)

      result = WebSearch.execute(%{"query" => "elixir programming"}, %{})
      assert {:error, msg} = result
      assert msg =~ "API key not configured"

      if original, do: System.put_env("BRAVE_SEARCH_API_KEY", original)
    end
  end

  describe "search via Bypass" do
    setup do
      bypass = Bypass.open()

      Application.put_env(
        :synapsis_core,
        :brave_search_base_url,
        "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        Application.delete_env(:synapsis_core, :brave_search_base_url)
        System.delete_env("BRAVE_SEARCH_API_KEY")
      end)

      {:ok, bypass: bypass}
    end

    test "returns structured results for a successful query", %{bypass: bypass} do
      brave_response =
        Jason.encode!(%{
          "web" => %{
            "results" => [
              %{
                "title" => "Elixir Language",
                "url" => "https://elixir-lang.org",
                "description" => "A dynamic, functional language."
              },
              %{
                "title" => "Elixir School",
                "url" => "https://elixirschool.com",
                "description" => "Learn Elixir step by step."
              }
            ]
          }
        })

      Bypass.expect_once(bypass, "GET", "/res/v1/web/search", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["q"] == "elixir programming"
        assert conn.params["count"] == "5"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, brave_response)
      end)

      System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

      assert {:ok, json} = WebSearch.execute(%{"query" => "elixir programming"}, %{})
      parsed = Jason.decode!(json)
      assert length(parsed) == 2
      assert hd(parsed)["title"] == "Elixir Language"
      assert hd(parsed)["url"] == "https://elixir-lang.org"
      assert hd(parsed)["snippet"] == "A dynamic, functional language."
    end

    test "passes max_results parameter correctly", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/res/v1/web/search", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.params["count"] == "3"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"web" => %{"results" => []}}))
      end)

      System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

      assert {:ok, json} = WebSearch.execute(%{"query" => "test", "max_results" => 3}, %{})
      assert Jason.decode!(json) == []
    end

    test "handles non-200 status codes", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/res/v1/web/search", fn conn ->
        Plug.Conn.resp(conn, 429, "Rate limited")
      end)

      System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

      assert {:error, msg} = WebSearch.execute(%{"query" => "test"}, %{})
      assert msg =~ "HTTP 429"
    end

    test "handles empty web results", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/res/v1/web/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"web" => %{"results" => []}}))
      end)

      System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

      assert {:ok, json} = WebSearch.execute(%{"query" => "nonexistent"}, %{})
      assert Jason.decode!(json) == []
    end

    test "handles missing web key in response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/res/v1/web/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"query" => %{"original" => "test"}}))
      end)

      System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

      assert {:ok, json} = WebSearch.execute(%{"query" => "test"}, %{})
      assert Jason.decode!(json) == []
    end

    test "handles network errors", %{bypass: bypass} do
      Bypass.down(bypass)

      System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

      assert {:error, msg} = WebSearch.execute(%{"query" => "test"}, %{})
      assert msg =~ "Search request failed"
    end
  end
end
