defmodule Synapsis.Tool.FetchTest do
  use ExUnit.Case

  alias Synapsis.Tool.Fetch

  describe "URL validation" do
    test "returns error for malformed URL without scheme" do
      assert {:error, _msg} = Fetch.execute(%{"url" => "not-a-url"}, %{})
    end

    test "allows external https URL format to pass validation" do
      # We can't actually fetch externally in CI, but verify that validation
      # passes (it may fail at network level, not validation)
      result = Fetch.execute(%{"url" => "https://example.invalid/docs"}, %{})
      # Should be error at network level, NOT an SSRF error
      case result do
        {:error, msg} -> refute msg =~ "internal/private"
        {:ok, _} -> :ok
      end
    end
  end

  describe "SSRF protection" do
    test "blocks localhost" do
      {:error, msg} = Fetch.execute(%{"url" => "http://localhost:8080/admin"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks 127.0.0.1" do
      {:error, msg} = Fetch.execute(%{"url" => "http://127.0.0.1:5432"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks private 10.x range" do
      {:error, msg} = Fetch.execute(%{"url" => "http://10.0.0.1/secret"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks private 172.16.x range" do
      {:error, msg} = Fetch.execute(%{"url" => "http://172.16.0.1/secret"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks private 192.168.x range" do
      {:error, msg} = Fetch.execute(%{"url" => "http://192.168.1.1/secret"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks AWS metadata endpoint" do
      {:error, msg} = Fetch.execute(%{"url" => "http://169.254.169.254/latest/meta-data"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks metadata.google.internal" do
      {:error, msg} =
        Fetch.execute(%{"url" => "http://metadata.google.internal/computeMetadata"}, %{})

      assert msg =~ "internal/private"
    end

    test "blocks non-http schemes" do
      {:error, msg} = Fetch.execute(%{"url" => "file:///etc/passwd"}, %{})
      assert msg =~ "Only http and https"
    end

    test "blocks ftp scheme" do
      {:error, msg} = Fetch.execute(%{"url" => "ftp://evil.com/data"}, %{})
      assert msg =~ "Only http and https"
    end

    test "blocks 0.0.0.0" do
      {:error, msg} = Fetch.execute(%{"url" => "http://0.0.0.0:8080/admin"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks data URI scheme" do
      {:error, msg} = Fetch.execute(%{"url" => "data:text/html,<h1>evil</h1>"}, %{})
      assert msg =~ "Only http and https"
    end

    test "blocks javascript scheme" do
      {:error, msg} = Fetch.execute(%{"url" => "javascript:alert(1)"}, %{})
      assert msg =~ "Only http and https"
    end
  end

  describe "SSRF protection — DNS resolution bypass" do
    test "blocks hostname that resolves to loopback (localhost)" do
      # localhost resolves to 127.0.0.1 which is both in @blocked_hosts
      # and caught by the resolves_to_private? DNS check
      {:error, msg} = Fetch.execute(%{"url" => "http://localhost/admin"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks alternate loopback IP 127.0.0.2" do
      # 127.0.0.2 is not in @blocked_hosts but is caught by private_ip?
      # because private_addr? matches the full {127, _, _, _} range
      {:error, msg} = Fetch.execute(%{"url" => "http://127.0.0.2/admin"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks link-local 169.254.x.x range" do
      {:error, msg} = Fetch.execute(%{"url" => "http://169.254.1.1/metadata"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks 10.x.x.x private range with non-standard port" do
      {:error, msg} = Fetch.execute(%{"url" => "http://10.255.255.1:9090/secret"}, %{})
      assert msg =~ "internal/private"
    end

    test "blocks 172.20.0.1 (within 172.16-31 range)" do
      {:error, msg} = Fetch.execute(%{"url" => "http://172.20.0.1/internal"}, %{})
      assert msg =~ "internal/private"
    end
  end

  describe "tool metadata" do
    test "has correct name and parameters" do
      assert Fetch.name() == "fetch"
      assert is_binary(Fetch.description())
      assert %{"type" => "object", "required" => ["url"]} = Fetch.parameters()
    end
  end
end
