defmodule Synapsis.Provider.Transport.GoogleTest do
  use ExUnit.Case

  alias Synapsis.Provider.Transport.Google

  describe "default_base_url/0" do
    test "returns Google API URL" do
      assert Google.default_base_url() == "https://generativelanguage.googleapis.com"
    end
  end
end
