defmodule Synapsis.Filesystem.DirectoryQuoteFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.{DirectoryList, Local}

  @moduletag :tmp_dir

  # Authored before repair from OpenClaw pin488631c ls.ts:44,86:
  # JSON.stringify emits lowercase hexadecimal control escapes while keeping
  # the case of literal filename bytes, including a literal backslash-u word.
  test "complete names use lowercase control escapes without rewriting literal backslash text" do
    entries = [
      %{name: "e\u001Ff", is_directory: false},
      %{name: ~S(a\u000B), is_directory: false},
      %{name: "c\u000Ed", is_directory: true},
      %{name: "a\u000Bb", is_directory: false}
    ]

    expected =
      ~S("a\u000bb") <>
        "\n" <>
        ~S("a\\u000B") <>
        "\n" <>
        ~S("c\u000ed/") <>
        "\n" <>
        ~S("e\u001ff")

    assert DirectoryList.page(entries, %{}) == result(expected)
  end

  test "paged names quote both footer cursors and names while nextAfter stays raw" do
    cases = [
      {"a\u000B\u000E\u001Fb", true,
       ~S("a\u000b\u000e\u001fb/") <>
         "\n\n" <>
         ~S([More entries. Continue with the same path and after="a\u000b\u000e\u001fb".])},
      {~S(a\u000B), false,
       ~S("a\\u000B") <>
         "\n\n" <>
         ~S([More entries. Continue with the same path and after="a\\u000B".])}
    ]

    for {raw_name, directory, expected} <- cases do
      entries = [
        %{name: "z", is_directory: false},
        %{name: raw_name, is_directory: directory}
      ]

      assert DirectoryList.page(entries, %{"limit" => 1}) == result(expected, raw_name)

      assert DirectoryList.page(entries, %{"limit" => 1, "after" => raw_name}) ==
               result(~S("z"))
    end
  end

  test "real directory control names and literal uppercase backslash sequence round trip", %{
    tmp_dir: root
  } do
    File.mkdir_p!(Path.join(root, "names"))
    directory = "c\u000Ed"
    files = ["a\u000Bb", ~S(a\u000B), "e\u001Ff"]
    File.mkdir!(Path.join([root, "names", directory]))

    for name <- files do
      File.write!(Path.join([root, "names", name]), "ordinary body")
    end

    expected =
      ~S("a\u000bb") <>
        "\n" <>
        ~S("a\\u000B") <>
        "\n" <>
        ~S("c\u000ed/") <>
        "\n" <>
        ~S("e\u001ff")

    assert {:ok, page} = Local.list_directory(root, "names", %{})
    assert {:ok, page} == result(expected)

    assert page.details.content |> String.split("\n") |> Enum.map(&Jason.decode!/1) ==
             ["a\u000Bb", ~S(a\u000B), directory <> "/", "e\u001Ff"]

    assert File.ls!(Path.join(root, "names")) |> MapSet.new() ==
             MapSet.new([directory | files])

    for name <- files do
      assert File.read!(Path.join([root, "names", name])) == "ordinary body"
    end
  end

  defp result(text),
    do: {:ok, %{content: [%{type: "text", text: text}], details: %{content: text}}}

  defp result(text, raw_name),
    do:
      {:ok,
       %{content: [%{type: "text", text: text}], details: %{content: text, nextAfter: raw_name}}}
end
