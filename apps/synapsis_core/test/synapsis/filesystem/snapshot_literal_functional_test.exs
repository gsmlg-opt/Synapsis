defmodule Synapsis.Filesystem.SnapshotLiteralFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Filesystem.Local

  @moduletag :tmp_dir

  # Frozen independently from OTP 28.5.0.8 stdlib 7.3.0.3 filelib.erl:
  # compile_part/3 retains an unmatched '[' as an integer literal (651-656),
  # so is_literal_pattern/1 preserves it in the initial prefix (584-606).
  # These selectors name ordinary literal files; expected results are not
  # computed by Path.wildcard, SnapshotMatcher or directory_snapshot.
  test "hidden literal brackets match exact selectors and literal prefixes before wildcards", %{
    tmp_dir: root
  } do
    fixtures = [
      {".note[", <<0, 255, 65, 10>>},
      {".cache[/file.txt", "cached first\n"},
      {".cache[/other.txt", "cached second\n"},
      {"docs/.cache[/file.txt", "nested cached\n"},
      {"docs/visible.txt", "visible child\n"},
      {"visible.txt", "visible root\n"}
    ]

    for {path, bytes} <- fixtures do
      absolute = Path.join(root, path)
      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, bytes)
    end

    cases = [
      {".note[",
       %{
         entries: [%{path: ".note[", type: "file"}],
         files: %{".note[" => <<0, 255, 65, 10>>}
       }},
      {".cache[/file.txt",
       %{
         entries: [%{path: ".cache[/file.txt", type: "file"}],
         files: %{".cache[/file.txt" => "cached first\n"}
       }},
      {".cache[/*.txt",
       %{
         entries: [
           %{path: ".cache[/file.txt", type: "file"},
           %{path: ".cache[/other.txt", type: "file"}
         ],
         files: %{
           ".cache[/file.txt" => "cached first\n",
           ".cache[/other.txt" => "cached second\n"
         }
       }},
      {"docs/.cache[/*.txt",
       %{
         entries: [%{path: "docs/.cache[/file.txt", type: "file"}],
         files: %{"docs/.cache[/file.txt" => "nested cached\n"}
       }}
    ]

    for {pattern, expected} <- cases do
      assert {:ok, ^expected} =
               Local.directory_snapshot(root, ".", %{
                 pattern: pattern,
                 read_patterns: [pattern]
               })
    end

    # Explicit literal capture must not change the default wildcard dot filter.
    expected_visible = %{
      entries: [
        %{path: "docs", type: "directory"},
        %{path: "docs/visible.txt", type: "file"},
        %{path: "visible.txt", type: "file"}
      ],
      files: %{
        "docs/visible.txt" => "visible child\n",
        "visible.txt" => "visible root\n"
      }
    }

    assert {:ok, ^expected_visible} =
             Local.directory_snapshot(root, ".", %{
               pattern: "**/*",
               read_patterns: ["**/*.txt"]
             })
  end
end
