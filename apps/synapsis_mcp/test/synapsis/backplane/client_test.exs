defmodule Synapsis.Backplane.ClientTest do
  use ExUnit.Case, async: true

  alias Synapsis.Backplane.{Client, Connection}

  test "discovers the exact Backplane REST and MCP contracts into one snapshot", %{test: test} do
    bypass = Bypass.open()
    connection = connection!(bypass, credential: "client-secret")
    archive = archive!(test, "review", "Review from the archive.")
    parent = self()

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      send(parent, :models)
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer client-secret"]
      json(conn, %{"object" => "list", "data" => [%{"id" => "model-a"}]})
    end)

    Bypass.expect_once(bypass, "GET", "/skills", fn conn ->
      send(parent, :skills)
      assert conn.query_string == "limit=100"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer client-secret"]

      json(conn, %{
        "data" => [
          %{
            "id" => "archive-id",
            "slug" => "review",
            "name" => "Review",
            "source_kind" => "archive",
            "content_hash" => String.duplicate("a", 64)
          },
          %{
            "id" => "generated-id",
            "slug" => "generated",
            "name" => "Generated",
            "source_kind" => "generated",
            "content_hash" => String.duplicate("b", 64)
          }
        ]
      })
    end)

    Bypass.expect_once(bypass, "GET", "/skills/review", fn conn ->
      send(parent, :archive_detail)

      json(conn, %{
        "id" => "archive-id",
        "slug" => "review",
        "name" => "Review",
        "source_kind" => "archive",
        "files" => ["review/SKILL.md"]
      })
    end)

    Bypass.expect_once(bypass, "GET", "/skills/review/archive", fn conn ->
      send(parent, :archive)

      conn
      |> Plug.Conn.put_resp_content_type("application/x-tar+gzip")
      |> Plug.Conn.send_resp(200, archive)
    end)

    Bypass.expect_once(bypass, "GET", "/skills/generated", fn conn ->
      send(parent, :generated_detail)

      json(conn, %{
        "id" => "generated-id",
        "slug" => "generated",
        "name" => "Generated",
        "source_kind" => "generated",
        "content" => "Generated body."
      })
    end)

    Bypass.expect(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      message = Jason.decode!(body)

      case message["method"] do
        "initialize" ->
          send(parent, :initialize)

          conn
          |> Plug.Conn.put_resp_header("mcp-session-id", "session-1")
          |> json(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => %{"protocolVersion" => "2025-03-26"}
          })

        "notifications/initialized" ->
          send(parent, :initialized)
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-1"]
          Plug.Conn.send_resp(conn, 202, "")

        "tools/list" ->
          send(parent, :tools)
          assert Plug.Conn.get_req_header(conn, "mcp-session-id") == ["session-1"]

          json(conn, %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "result" => %{"tools" => [%{"name" => "memory::search"}]}
          })
      end
    end)

    assert {:ok, %{__struct__: Synapsis.Backplane.Snapshot} = snapshot} =
             Client.fetch_snapshot(connection, timeout: 500)

    assert Enum.map(snapshot.models, & &1.external_id) == ["model-a"]

    assert Enum.map(snapshot.skills, &{&1.external_id, &1.metadata["content"]}) == [
             {"archive-id", "Review from the archive."},
             {"generated-id", "Generated body."}
           ]

    assert Enum.map(snapshot.mcp_tools, & &1.external_id) == ["memory::search"]
    assert snapshot.errors == %{}

    assert_receive :models
    assert_receive :skills
    assert_receive :archive_detail
    assert_receive :archive
    assert_receive :generated_detail
    assert_receive :initialize
    assert_receive :initialized
    assert_receive :tools
  end

  test "keeps successful surfaces when another discovery surface fails" do
    bypass = Bypass.open()
    connection = connection!(bypass)

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      Plug.Conn.send_resp(conn, 503, "offline")
    end)

    Bypass.expect_once(bypass, "GET", "/skills", fn conn ->
      json(conn, %{"data" => []})
    end)

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      Plug.Conn.send_resp(conn, 503, "offline")
    end)

    assert {:ok, snapshot} = Client.fetch_snapshot(connection, timeout: 500)
    assert snapshot.skills == []
    assert snapshot.errors == %{models: {:http_status, 503}, mcp_tools: {:http_status, 503}}
  end

  test "redacts credentials from per-surface protocol errors" do
    bypass = Bypass.open()
    connection = connection!(bypass, credential: "never-print-this")

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      json(conn, %{"data" => []})
    end)

    Bypass.expect_once(bypass, "GET", "/skills", fn conn ->
      json(conn, %{"data" => []})
    end)

    Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "error" => %{"code" => -32_000, "message" => "rejected never-print-this"}
      })
    end)

    assert {:ok, snapshot} = Client.fetch_snapshot(connection, timeout: 500)
    refute inspect(snapshot.errors) =~ "never-print-this"
    assert inspect(snapshot.errors) =~ "[REDACTED]"
  end

  test "rejects unsafe and over-limit archive contents", %{test: test} do
    bypass = Bypass.open()
    connection = connection!(bypass)

    for {slug, entries, expected} <- [
          {"unsafe", [{"../SKILL.md", "unsafe"}], :unsafe_archive_path},
          {"encoded", [{"%2e%2e/SKILL.md", "unsafe"}], :unsafe_archive_path},
          {"windows", [{"C:/SKILL.md", "unsafe"}], :unsafe_archive_path},
          {"large", [{"large/SKILL.md", String.duplicate("x", 2_000)}], :skill_content_too_large}
        ] do
      archive = archive_entries!(test, slug, entries)

      Bypass.expect_once(bypass, "GET", "/skills/#{slug}", fn conn ->
        json(conn, %{"slug" => slug, "source_kind" => "archive"})
      end)

      Bypass.expect_once(bypass, "GET", "/skills/#{slug}/archive", fn conn ->
        Plug.Conn.send_resp(conn, 200, archive)
      end)

      assert {:error, ^expected} =
               Client.fetch_skill(connection, slug,
                 timeout: 500,
                 max_skill_content_bytes: 1_000
               )
    end
  end

  test "reads a validated Backplane archive that contains its root directory", %{test: test} do
    bypass = Bypass.open()
    connection = connection!(bypass)
    archive = archive_with_directory!(test, "rooted", "Rooted body.")

    assert {:ok, [{_name, :directory, 0, _mtime, _mode, _uid, _gid} | _rest]} =
             :erl_tar.table({:binary, archive}, [:compressed, :verbose])

    Bypass.expect_once(bypass, "GET", "/skills/rooted", fn conn ->
      json(conn, %{"slug" => "rooted", "source_kind" => "archive"})
    end)

    Bypass.expect_once(bypass, "GET", "/skills/rooted/archive", fn conn ->
      Plug.Conn.send_resp(conn, 200, archive)
    end)

    assert {:ok, %{"content" => "Rooted body."}} =
             Client.fetch_skill(connection, "rooted", timeout: 500)
  end

  test "bounds archive directory entries as well as regular files", %{test: test} do
    bypass = Bypass.open()
    connection = connection!(bypass)
    regular = archive!(test, "bounded", "Bounded body.") |> :zlib.gunzip()

    directories =
      for index <- 1..257, into: "" do
        tar_directory_header("bounded/dir-#{index}/")
      end

    archive = :zlib.gzip(directories <> regular)

    Bypass.expect_once(bypass, "GET", "/skills/bounded", fn conn ->
      json(conn, %{"slug" => "bounded", "source_kind" => "archive"})
    end)

    Bypass.expect_once(bypass, "GET", "/skills/bounded/archive", fn conn ->
      Plug.Conn.send_resp(conn, 200, archive)
    end)

    assert {:error, :archive_entry_limit_exceeded} =
             Client.fetch_skill(connection, "bounded", timeout: 500)
  end

  test "rejects an archive with a corrupt tar header checksum", %{test: test} do
    bypass = Bypass.open()
    connection = connection!(bypass)
    tar = archive!(test, "checksum", "Checksum body.") |> :zlib.gunzip()
    <<header::binary-size(512), rest::binary>> = tar
    archive = :zlib.gzip(put_tar_field(header, 0, 1, "X") <> rest)

    Bypass.expect_once(bypass, "GET", "/skills/checksum", fn conn ->
      json(conn, %{"slug" => "checksum", "source_kind" => "archive"})
    end)

    Bypass.expect_once(bypass, "GET", "/skills/checksum/archive", fn conn ->
      Plug.Conn.send_resp(conn, 200, archive)
    end)

    assert {:error, :invalid_archive} =
             Client.fetch_skill(connection, "checksum", timeout: 500)
  end

  test "stops inflating a high-ratio gzip archive at the expanded-size bound", %{test: test} do
    bypass = Bypass.open()
    connection = connection!(bypass)
    archive = archive!(test, "bomb", String.duplicate("x", 1_000_000))
    assert byte_size(archive) < 10_000

    Bypass.expect_once(bypass, "GET", "/skills/bomb", fn conn ->
      json(conn, %{"slug" => "bomb", "source_kind" => "archive"})
    end)

    Bypass.expect_once(bypass, "GET", "/skills/bomb/archive", fn conn ->
      Plug.Conn.send_resp(conn, 200, archive)
    end)

    assert {:error, :archive_expanded_too_large} =
             Client.fetch_skill(connection, "bomb",
               timeout: 500,
               max_expanded_bytes: 32_000,
               max_skill_content_bytes: 2_000_000
             )
  end

  test "omits authorization for blank credentials" do
    bypass = Bypass.open()
    connection = connection!(bypass, credential: "  ")

    Bypass.expect_once(bypass, "GET", "/v1/models", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      json(conn, %{"data" => []})
    end)

    assert {:ok, []} = Client.fetch_models(connection, timeout: 500)
  end

  defp connection!(bypass, opts \\ []) do
    {:ok, connection} =
      Connection.new(%{
        name: "http",
        endpoint: "http://localhost:#{bypass.port}",
        credential: Keyword.get(opts, :credential)
      })

    connection
  end

  defp archive!(test, slug, content) do
    archive_entries!(test, slug, [{"#{slug}/SKILL.md", content}])
  end

  defp archive_entries!(test, slug, entries) do
    path =
      Path.join(
        System.tmp_dir!(),
        "synapsis-backplane-#{test}-#{slug}-#{System.unique_integer([:positive])}.tar.gz"
      )

    tar_entries = Enum.map(entries, fn {name, content} -> {String.to_charlist(name), content} end)
    :ok = :erl_tar.create(String.to_charlist(path), tar_entries, [:compressed])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp archive_with_directory!(test, slug, content) do
    regular = archive!(test, slug, content) |> :zlib.gunzip()
    :zlib.gzip(tar_directory_header(slug <> "/") <> regular)
  end

  defp tar_directory_header(name) do
    header =
      :binary.copy(<<0>>, 512)
      |> put_tar_field(0, 100, name)
      |> put_tar_field(100, 8, "0000755\0")
      |> put_tar_field(108, 8, "0000000\0")
      |> put_tar_field(116, 8, "0000000\0")
      |> put_tar_field(124, 12, "00000000000\0")
      |> put_tar_field(136, 12, "00000000000\0")
      |> put_tar_field(148, 8, "        ")
      |> put_tar_field(156, 1, "5")
      |> put_tar_field(257, 6, "ustar\0")
      |> put_tar_field(263, 2, "00")

    checksum =
      header
      |> :binary.bin_to_list()
      |> Enum.sum()
      |> Integer.to_string(8)
      |> String.pad_leading(6, "0")

    put_tar_field(header, 148, 8, checksum <> <<0, 32>>)
  end

  defp put_tar_field(binary, offset, length, value) do
    value = value <> :binary.copy(<<0>>, length - byte_size(value))
    <<prefix::binary-size(offset), _old::binary-size(length), suffix::binary>> = binary
    prefix <> value <> suffix
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
