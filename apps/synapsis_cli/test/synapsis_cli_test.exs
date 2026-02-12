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
  end

  defp capture_main(args) do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        SynapsisCli.Main.main(args)
      end)

    {:ok, output}
  end
end
