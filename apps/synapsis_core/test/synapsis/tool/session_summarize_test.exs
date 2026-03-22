defmodule Synapsis.Tool.SessionSummarizeTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.SessionSummarize

  test "declares correct metadata" do
    assert SessionSummarize.name() == "session_summarize"
    assert is_binary(SessionSummarize.description())
    assert is_map(SessionSummarize.parameters())
  end

  test "category is memory" do
    assert SessionSummarize.category() == :memory
  end

  test "permission level is read" do
    assert SessionSummarize.permission_level() == :read
  end
end
