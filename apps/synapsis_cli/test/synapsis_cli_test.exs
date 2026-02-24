defmodule SynapsisCliTest do
  use ExUnit.Case

  describe "argument parsing" do
    test "parses --help flag" do
      assert {:ok, output} = capture_main(["--help"])
      assert output =~ "Synapsis - AI Coding Agent"
      assert output =~ "--prompt"
    end

    test "parses --version flag" do
      assert {:ok, output} = capture_main(["--version"])
      assert output =~ "Synapsis CLI v0.1.0"
    end

    test "parses --serve flag" do
      assert {:ok, output} = capture_main(["--serve"])
      assert output =~ "mix phx.server"
    end

    test "--help output includes all major options" do
      {:ok, output} = capture_main(["--help"])
      assert output =~ "--model"
      assert output =~ "--provider"
      assert output =~ "--host"
    end

    test "help output lists example commands" do
      {:ok, output} = capture_main(["--help"])
      assert output =~ "synapsis -p"
      assert output =~ "--provider"
    end
  end

  describe "version output" do
    test "includes version number pattern" do
      {:ok, output} = capture_main(["--version"])
      assert output =~ ~r/v\d+\.\d+\.\d+/
    end
  end

  defp capture_main(args) do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        SynapsisCli.Main.main(args)
      end)

    {:ok, output}
  end
end
