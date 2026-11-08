defmodule Synapsis.PDF.SourceFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.PDF.Source

  @moduletag :tmp_dir
  @fixture Path.expand("../../fixtures/pdf/ordinary.pdf", __DIR__)

  test "relative and file URL inputs preserve actual binary PDF bytes and provenance", %{
    tmp_dir: root
  } do
    bytes = File.read!(@fixture)
    refute String.valid?(bytes)
    target = Path.join(root, "ordinary report.pdf")
    File.write!(target, bytes)

    for reference <- ["ordinary report.pdf", "file://" <> URI.encode(target)] do
      assert {:ok, result} =
               Source.load(reference, %{project_root: root}, byte_size(bytes), deadline())

      assert result.bytes == bytes
      assert :crypto.hash(:sha256, result.bytes) == :crypto.hash(:sha256, bytes)
      assert result.resolved_input == target
      assert result.rewritten_from == reference
    end
  end

  test "local HTTP acquisition retains bytes beyond the web text transport budget", %{
    tmp_dir: root
  } do
    fixture = Gaoxy.Test.open()
    bytes = File.read!(@fixture) <> :binary.copy(<<0>>, 300_000)
    owner = self()

    Gaoxy.Test.stub(fixture, "GET", "/ordinary.pdf", fn conn ->
      send(owner, :pdf_acquired)
      conn |> Plug.Conn.put_resp_content_type("application/pdf") |> Plug.Conn.resp(200, bytes)
    end)

    reference = Gaoxy.Test.url(fixture, "/ordinary.pdf")
    context = %{project_root: root, web_allowed_hosts: ["127.0.0.1", "localhost"]}
    assert {:ok, result} = Source.load(reference, context, byte_size(bytes), deadline())
    assert result.bytes == bytes
    assert result.resolved_input == reference
    assert result.rewritten_from == nil
    assert_receive :pdf_acquired
    refute_receive :pdf_acquired, 0
  end

  for status <- [301, 302, 303, 307, 308] do
    @status status
    test "HTTP #{@status} acquisition follows a valid Location and retains initial provenance", %{
      tmp_dir: root
    } do
      status = @status
      fixture = Gaoxy.Test.open()
      on_exit(fn -> Gaoxy.Test.close(fixture) end)
      bytes = File.read!(@fixture) <> :binary.copy(<<0, 255>>, 150_000)
      owner = self()
      initial_path = "/#{status}/start"
      final_path = "/#{status}/files/ordinary.pdf"

      location =
        if status in [301, 303, 308],
          do: "files/ordinary.pdf",
          else: Gaoxy.Test.url(fixture, final_path)

      Gaoxy.Test.expect_once(fixture, "GET", initial_path, fn conn ->
        send(owner, {:pdf_redirect, status})

        conn
        |> Plug.Conn.put_resp_header("location", location)
        |> Plug.Conn.resp(status, "Ordinary PDF moved")
      end)

      Gaoxy.Test.expect_once(fixture, "GET", final_path, fn conn ->
        send(owner, {:redirected_pdf, status})
        conn |> Plug.Conn.put_resp_content_type("application/pdf") |> Plug.Conn.resp(200, bytes)
      end)

      reference = Gaoxy.Test.url(fixture, initial_path)
      context = %{project_root: root, web_allowed_hosts: ["127.0.0.1", "localhost"]}

      assert {:ok, result} = Source.load(reference, context, byte_size(bytes), deadline())
      assert result.bytes == bytes
      assert result.resolved_input == reference
      assert result.rewritten_from == nil
      assert_receive {:pdf_redirect, ^status}
      assert_receive {:redirected_pdf, ^status}
    end
  end

  test "three sequential redirects resolve against each current URL and preserve exact PDF bytes",
       %{
         tmp_dir: root
       } do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    bytes = File.read!(@fixture) <> :binary.copy(<<255, 0>>, 150_000)
    owner = self()

    for {path, status, location} <- [
          {"/exports/start", 302, "../stage/two?format=pdf"},
          {"/stage/two", 307, "/stage/three"},
          {"/stage/three", 308, Gaoxy.Test.url(fixture, "/assets/ordinary.pdf")}
        ] do
      Gaoxy.Test.expect_once(fixture, "GET", path, fn conn ->
        if path == "/stage/two", do: assert(conn.query_string == "format=pdf")
        send(owner, {:pdf_hop, path})

        conn
        |> Plug.Conn.put_resp_header("location", location)
        |> Plug.Conn.resp(status, "Ordinary PDF redirect")
      end)
    end

    Gaoxy.Test.expect_once(fixture, "GET", "/assets/ordinary.pdf", fn conn ->
      send(owner, {:pdf_hop, "/assets/ordinary.pdf"})
      conn |> Plug.Conn.put_resp_content_type("application/pdf") |> Plug.Conn.resp(200, bytes)
    end)

    reference = Gaoxy.Test.url(fixture, "/exports/start")
    context = %{project_root: root, web_allowed_hosts: ["127.0.0.1", "localhost"]}
    assert {:ok, result} = Source.load(reference, context, byte_size(bytes), deadline())
    assert result.bytes == bytes
    assert :crypto.hash(:sha256, result.bytes) == :crypto.hash(:sha256, bytes)
    assert result.resolved_input == reference
    assert result.rewritten_from == nil

    for path <- ["/exports/start", "/stage/two", "/stage/three", "/assets/ordinary.pdf"] do
      assert_receive {:pdf_hop, ^path}
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 10_000
end
