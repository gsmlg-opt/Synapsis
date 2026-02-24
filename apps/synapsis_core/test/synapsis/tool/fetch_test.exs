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
  end
end
