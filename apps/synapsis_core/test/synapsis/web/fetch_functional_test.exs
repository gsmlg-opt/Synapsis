defmodule Synapsis.Web.FetchFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Web.Fetch
  alias Synapsis.Web.Fetch.Document

  # Whole pinned source callbacks define every expected content/metadata field.
  # No candidate helper, transport or decoder generates an oracle.
  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/web-fetch.json",
             __DIR__
           )
  @external_resource @fixture
  @oracle @fixture |> File.read!() |> Jason.decode!()
  @direct_ids ~w(plain markdown markdown-text article article-text json json-subtype declared-charset bom document-charset repeat-cache)
  @source_keys %{
    "finalUrl" => "final_url",
    "contentType" => "content_type",
    "extractMode" => "extract_mode",
    "externalContent" => "external_content",
    "rawLength" => "raw_length",
    "fetchedAt" => "fetched_at",
    "tookMs" => "took_ms"
  }

  setup_all do
    node = Application.fetch_env!(:synapsis_agent, :filesystem_node)
    assert is_binary(node) and Path.type(node) == :absolute
    assert node == System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE")
    assert File.regular?(node)

    assert Base.encode16(:crypto.hash(:sha256, File.read!(@fixture)), case: :lower) ==
             "2fc7a79709a6d23fe109f21958223dae40d9e7e3f17271bc217e45bab5c4fd08"

    {:ok, node: node}
  end

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  for id <- @direct_ids do
    @id id
    test "real successful HTTP bytes retain the full #{@id} document", ctx do
      group = group(@id)
      path = "/ordinary/#{@id}"
      owner = self()
      bytes = input_bytes(group)
      header = group["input"]["contentType"]
      url = Gaoxy.Test.url(ctx.fixture, path)

      Gaoxy.Test.expect_once(ctx.fixture, "GET", path, fn conn ->
        assert conn.request_path == path

        assert Plug.Conn.get_req_header(conn, "accept") ==
                 ["text/markdown, text/html;q=0.9, */*;q=0.1"]

        send(owner, {:document_http, path, bytes, header})
        conn |> Plug.Conn.put_resp_header("content-type", header) |> Plug.Conn.resp(200, bytes)
      end)

      arguments = %{
        "url" => url,
        "extract_mode" => group["args"]["extractMode"] || "markdown",
        "max_chars" => 8192
      }

      assert {:ok, result} = fetch_document(arguments, options(ctx))
      assert_public_document(result, group, url, url)
      assert_receive {:document_http, ^path, ^bytes, ^header}
      assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
    end
  end

  test "relative then absolute successful redirects use real paths and final URL", ctx do
    group = group("final-url")
    owner = self()
    start_url = Gaoxy.Test.url(ctx.fixture, "/pages/start")
    final_url = Gaoxy.Test.url(ctx.fixture, "/destination/final?q=page")

    for {path, status, location} <- [
          {"/pages/start", 302, "../stage/next?phase=two"},
          {"/stage/next", 307, final_url}
        ] do
      Gaoxy.Test.expect_once(ctx.fixture, "GET", path, fn conn ->
        expected_query = if path == "/stage/next", do: "phase=two", else: ""
        assert conn.query_string == expected_query
        send(owner, {:redirect_hop, path})
        conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.resp(status, "Moved")
      end)
    end

    bytes = input_bytes(group)

    Gaoxy.Test.expect_once(ctx.fixture, "GET", "/destination/final", fn conn ->
      assert conn.query_string == "q=page"
      send(owner, {:redirect_hop, "/destination/final"})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, bytes)
    end)

    assert {:ok, result} = fetch_document(%{"url" => start_url}, options(ctx))
    assert_public_document(result, group, start_url, final_url)
    assert_receive {:redirect_hop, "/pages/start"}
    assert_receive {:redirect_hop, "/stage/next"}
    assert_receive {:redirect_hop, "/destination/final"}
    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 3
  end

  test "actual chunked response reconstructs split UTF8 characters before source decoding", ctx do
    group = group("plain")
    owner = self()
    path = "/stream/ordinary"
    url = Gaoxy.Test.url(ctx.fixture, path)
    chunks = [<<"Ordinary caf", 0xC3>>, <<0xA9, 32, 0xF0, 0x9F>>, <<0x98, 0x80, 46, 10>>]
    assert IO.iodata_to_binary(chunks) == input_bytes(group)

    Gaoxy.Test.expect_once(ctx.fixture, "GET", path, fn conn ->
      conn =
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
        |> Plug.Conn.send_chunked(200)

      Enum.reduce(Enum.with_index(chunks), conn, fn {bytes, index}, conn ->
        assert {:ok, next} = Plug.Conn.chunk(conn, bytes)
        send(owner, {:ordinary_chunk_sent, index, bytes})
        next
      end)
    end)

    assert {:ok, result} = fetch_document(%{"url" => url}, options(ctx))
    assert_public_document(result, group, url, url)

    for {bytes, index} <- Enum.with_index(chunks) do
      assert_receive {:ordinary_chunk_sent, ^index, ^bytes}
    end

    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 1
  end

  test "Document succeeds only after normal OS exit, released Port and broker DOWN", ctx do
    group = group("plain")
    bytes = input_bytes(group)
    url = group["args"]["url"]

    metadata = %{
      "url" => url,
      "finalUrl" => url,
      "status" => 200,
      "contentType" => group["input"]["contentType"],
      "extractMode" => "markdown",
      "maxChars" => 8192
    }

    observer = self()

    task =
      Task.async(fn ->
        Document.prepare(bytes, metadata,
          node_executable: ctx.node,
          observer_pid: observer,
          deadline: System.monotonic_time(:millisecond) + 5_000
        )
      end)

    assert_receive {:web_fetch_helper_started, broker, started}, 2_000
    assert %{port: port, os_pid: os_pid} = started
    assert started == %{port: port, os_pid: os_pid}
    assert is_port(port) and is_integer(os_pid) and os_pid > 0
    monitor = Process.monitor(broker)
    assert {:ok, result} = Task.await(task, 6_000)
    refute Process.alive?(broker)
    assert Port.info(port) == nil
    assert normalize_document(result) == normalize_document(source_document(group))

    assert_receive {:web_fetch_helper_retired, ^broker, retired}, 1_000
    assert retired == %{exit_status: 0, port_released: true}
    assert_receive {:DOWN, ^monitor, :process, ^broker, :normal}, 1_000
    refute Process.alive?(broker)
    assert Port.info(port) == nil
    refute File.exists?("/proc/#{os_pid}")
  end

  test "standalone calls bypass shared native cache and each acquire the ordinary response",
       ctx do
    group = group("repeat-cache")
    owner = self()
    path = "/standalone/repeat"
    url = Gaoxy.Test.url(ctx.fixture, path)
    bytes = input_bytes(group)

    Gaoxy.Test.stub(ctx.fixture, "GET", path, fn conn ->
      send(owner, :standalone_http_acquired)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, bytes)
    end)

    # No fake runtime_context, invocation identity or cache-scope authority.
    for _ <- 1..2 do
      assert {:ok, result} = fetch_document(%{"url" => url}, options(ctx))
      assert_public_document(result, group, url, url)
      assert_receive :standalone_http_acquired
    end

    assert length(Gaoxy.Test.requests(ctx.fixture).entries) == 2
  end

  defp fetch_document(arguments, options) do
    earliest = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    started = System.monotonic_time(:millisecond)
    assert {:ok, result} = Fetch.fetch(arguments, options)
    elapsed = System.monotonic_time(:millisecond) - started
    latest = DateTime.utc_now() |> DateTime.truncate(:millisecond)
    assert {:ok, fetched_at, 0} = DateTime.from_iso8601(result["fetched_at"])
    assert DateTime.compare(fetched_at, earliest) in [:eq, :gt]
    assert DateTime.compare(fetched_at, latest) in [:eq, :lt]
    assert result["took_ms"] <= elapsed
    {:ok, result}
  end

  defp group(id), do: Enum.find(@oracle["groups"], &(&1["id"] == id))

  defp input_bytes(%{"input" => %{"bytes" => bytes}}), do: :binary.list_to_bin(bytes)

  defp input_bytes(%{"input" => %{"body" => body, "encoding" => "latin1"}}),
    do: :unicode.characters_to_binary(body, :utf8, :latin1)

  defp input_bytes(%{"input" => %{"body" => body}}), do: body

  defp options(ctx),
    do: [
      node_executable: ctx.node,
      allowed_hosts: ["127.0.0.1", "localhost"],
      timeout: 5_000,
      result_limit: 1_048_576
    ]

  defp source_document(group),
    do: group["results"] |> hd() |> Map.fetch!("details") |> Map.drop(["fetchedAt", "tookMs"])

  defp assert_public_document(result, group, url, final_url) do
    assert {:ok, timestamp, 0} = DateTime.from_iso8601(result["fetched_at"])
    assert timestamp.time_zone == "Etc/UTC"
    assert is_integer(result["took_ms"]) and result["took_ms"] >= 0
    assert result["length"] == utf16_length(result["text"])

    expected =
      group
      |> source_document()
      |> Map.put("url", url)
      |> Map.put("finalUrl", final_url)
      |> Map.new(fn {key, value} -> {Map.get(@source_keys, key, key), value} end)

    # Full maps retain title, extractor, source lengths, media type and all
    # framing. Only actual host timing and independently random marker IDs vary.
    actual = Map.drop(result, ["fetched_at", "took_ms"])
    assert normalize_document(actual) == normalize_document(expected)
  end

  defp utf16_length(text),
    do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2)

  defp normalize_document(document) do
    Enum.reduce(["text", "title", "warning"], document, fn key, document ->
      case Map.fetch(document, key) do
        {:ok, value} -> Map.put(document, key, normalize_wrapped(value))
        :error -> document
      end
    end)
  end

  defp normalize_wrapped(value) do
    markers = Regex.scan(~r/<<<(?:END_)?EXTERNAL_UNTRUSTED_CONTENT id="([a-f0-9]{16})">>>/, value)
    assert [[opening, id], [closing, id]] = markers
    assert String.starts_with?(opening, "<<<EXTERNAL_")
    assert String.starts_with?(closing, "<<<END_EXTERNAL_")
    String.replace(value, "id=\"#{id}\"", "id=\"3636363636363636\"")
  end
end
