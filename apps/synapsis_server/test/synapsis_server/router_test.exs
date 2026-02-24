defmodule SynapsisServer.RouterTest do
  use SynapsisServer.ConnCase

  @uuid Ecto.UUID.generate()

  # ---------------------------------------------------------------------------
  # Route existence — use Phoenix.Router.route_info to verify that the route
  # table contains the expected entries without hitting controller logic.
  # ---------------------------------------------------------------------------

  describe "API session routes exist" do
    test "GET /api/sessions" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :index} =
               Phoenix.Router.route_info(SynapsisServer.Router, "GET", "/api/sessions", "")
    end

    test "POST /api/sessions" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :create} =
               Phoenix.Router.route_info(SynapsisServer.Router, "POST", "/api/sessions", "")
    end

    test "GET /api/sessions/:id" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :show} =
               Phoenix.Router.route_info(SynapsisServer.Router, "GET", "/api/sessions/#{@uuid}", "")
    end

    test "DELETE /api/sessions/:id" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :delete} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "DELETE",
                 "/api/sessions/#{@uuid}",
                 ""
               )
    end

    test "POST /api/sessions/:id/messages" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :send_message} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "POST",
                 "/api/sessions/#{@uuid}/messages",
                 ""
               )
    end

    test "POST /api/sessions/:id/fork" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :fork} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "POST",
                 "/api/sessions/#{@uuid}/fork",
                 ""
               )
    end

    test "GET /api/sessions/:id/export" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :export_session} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "GET",
                 "/api/sessions/#{@uuid}/export",
                 ""
               )
    end

    test "POST /api/sessions/:id/compact" do
      assert %{plug: SynapsisServer.SessionController, plug_opts: :compact} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "POST",
                 "/api/sessions/#{@uuid}/compact",
                 ""
               )
    end

    test "GET /api/sessions/:id/events routes to SSEController" do
      assert %{plug: SynapsisServer.SSEController, plug_opts: :events} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "GET",
                 "/api/sessions/#{@uuid}/events",
                 ""
               )
    end

    test "PUT /api/sessions/:id is not routable (update not in resource actions)" do
      assert :error =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "PUT",
                 "/api/sessions/#{@uuid}",
                 ""
               )
    end

    test "PATCH /api/sessions/:id is not routable (update not in resource actions)" do
      assert :error =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "PATCH",
                 "/api/sessions/#{@uuid}",
                 ""
               )
    end
  end

  describe "API provider routes exist" do
    test "GET /api/providers" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :index} =
               Phoenix.Router.route_info(SynapsisServer.Router, "GET", "/api/providers", "")
    end

    test "POST /api/providers" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :create} =
               Phoenix.Router.route_info(SynapsisServer.Router, "POST", "/api/providers", "")
    end

    test "GET /api/providers/:id" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :show} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "GET",
                 "/api/providers/#{@uuid}",
                 ""
               )
    end

    test "PUT /api/providers/:id" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :update} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "PUT",
                 "/api/providers/#{@uuid}",
                 ""
               )
    end

    test "PATCH /api/providers/:id" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :update} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "PATCH",
                 "/api/providers/#{@uuid}",
                 ""
               )
    end

    test "DELETE /api/providers/:id" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :delete} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "DELETE",
                 "/api/providers/#{@uuid}",
                 ""
               )
    end

    test "GET /api/providers/:id/models" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :models} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "GET",
                 "/api/providers/#{@uuid}/models",
                 ""
               )
    end

    test "POST /api/providers/:id/test" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :test_connection} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "POST",
                 "/api/providers/#{@uuid}/test",
                 ""
               )
    end

    test "GET /api/providers/by-name/:name/models" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :models_by_name} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "GET",
                 "/api/providers/by-name/anthropic/models",
                 ""
               )
    end
  end

  describe "API auth routes exist" do
    test "POST /api/auth/:provider" do
      assert %{plug: SynapsisServer.ProviderController, plug_opts: :authenticate} =
               Phoenix.Router.route_info(
                 SynapsisServer.Router,
                 "POST",
                 "/api/auth/anthropic",
                 ""
               )
    end
  end

  describe "API config routes exist" do
    test "GET /api/config" do
      assert %{plug: SynapsisServer.ConfigController, plug_opts: :show} =
               Phoenix.Router.route_info(SynapsisServer.Router, "GET", "/api/config", "")
    end
  end

  # ---------------------------------------------------------------------------
  # 404 for unknown routes
  # ---------------------------------------------------------------------------

  describe "unknown routes return 404" do
    test "GET /api/nonexistent", %{conn: conn} do
      conn = get(conn, "/api/nonexistent")
      assert conn.status == 404
    end

    test "POST /api/nonexistent", %{conn: conn} do
      conn = post(conn, "/api/nonexistent", %{})
      assert conn.status == 404
    end

    test "deeply nested unknown path under /api", %{conn: conn} do
      conn = get(conn, "/api/sessions/#{@uuid}/extra/segments/here")
      assert conn.status == 404
    end

    test "route_info returns :error for unknown API path" do
      assert :error =
               Phoenix.Router.route_info(SynapsisServer.Router, "GET", "/api/nonexistent", "")
    end
  end

  # ---------------------------------------------------------------------------
  # API pipeline behaviour
  # ---------------------------------------------------------------------------

  describe "API pipeline" do
    test "responses include JSON content type", %{conn: conn} do
      conn = get(conn, "/api/config")
      content_type = get_resp_header(conn, "content-type") |> hd()
      assert content_type =~ "application/json"
    end

    test "accepts requests with application/json accept header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/config")

      assert conn.status == 200
    end

    test "rejects non-JSON accept header with NotAcceptableError", %{conn: conn} do
      assert_raise Phoenix.NotAcceptableError, fn ->
        conn
        |> put_req_header("accept", "text/xml")
        |> get("/api/config")
      end
    end

    test "accepts wildcard accept header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "*/*")
        |> get("/api/config")

      assert conn.status == 200
    end
  end

  # ---------------------------------------------------------------------------
  # CORS (provided by CORSPlug in the endpoint)
  # ---------------------------------------------------------------------------

  describe "CORS" do
    test "OPTIONS request returns CORS headers for allowed origin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "http://localhost:3000")
        |> put_req_header("access-control-request-method", "GET")
        |> options("/api/config")

      cors_origin = get_resp_header(conn, "access-control-allow-origin")
      assert length(cors_origin) > 0
      assert hd(cors_origin) == "http://localhost:3000"
    end

    test "OPTIONS request returns CORS headers for second allowed origin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "http://localhost:4000")
        |> put_req_header("access-control-request-method", "POST")
        |> options("/api/sessions")

      cors_origin = get_resp_header(conn, "access-control-allow-origin")
      assert length(cors_origin) > 0
      assert hd(cors_origin) == "http://localhost:4000"
    end

    test "GET request with allowed origin includes CORS header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "http://localhost:3000")
        |> get("/api/config")

      cors_origin = get_resp_header(conn, "access-control-allow-origin")
      assert cors_origin != []
    end

    test "CORS allows-methods header is present on OPTIONS", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "http://localhost:3000")
        |> put_req_header("access-control-request-method", "DELETE")
        |> options("/api/sessions/#{@uuid}")

      allow_methods = get_resp_header(conn, "access-control-allow-methods")
      assert length(allow_methods) > 0
    end
  end

  # ---------------------------------------------------------------------------
  # Route path parameters
  # ---------------------------------------------------------------------------

  describe "route path parameters" do
    test "session routes capture :id parameter" do
      info =
        Phoenix.Router.route_info(
          SynapsisServer.Router,
          "GET",
          "/api/sessions/#{@uuid}",
          ""
        )

      assert info.path_params == %{"id" => @uuid}
    end

    test "provider routes capture :id parameter" do
      info =
        Phoenix.Router.route_info(
          SynapsisServer.Router,
          "GET",
          "/api/providers/#{@uuid}",
          ""
        )

      assert info.path_params == %{"id" => @uuid}
    end

    test "auth route captures :provider parameter" do
      info =
        Phoenix.Router.route_info(
          SynapsisServer.Router,
          "POST",
          "/api/auth/anthropic",
          ""
        )

      assert info.path_params == %{"provider" => "anthropic"}
    end

    test "models-by-name route captures :name parameter" do
      info =
        Phoenix.Router.route_info(
          SynapsisServer.Router,
          "GET",
          "/api/providers/by-name/openai/models",
          ""
        )

      assert info.path_params == %{"name" => "openai"}
    end
  end
end
