defmodule Synapsis.Diffs.RequestFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Diffs.Request

  @fixture Path.expand(
             "../../../../synapsis_agent/test/fixtures/openclaw/488631c/diffs-request.json",
             __DIR__
           )
  @defaults %{
    "fontFamily" => "Fira Code",
    "fontSize" => 15,
    "lineSpacing" => 1.6,
    "layout" => "unified",
    "showLineNumbers" => true,
    "diffIndicators" => "bars",
    "wordWrap" => true,
    "background" => true,
    "theme" => "dark",
    "fileFormat" => "png",
    "fileQuality" => "standard",
    "fileScale" => 2,
    "fileMaxWidth" => 960,
    "mode" => "both",
    "ttlSeconds" => 1800
  }
  @changed %{"before" => "old\n", "after" => "new\n"}
  @standard %{
    "format" => "png",
    "qualityPreset" => "standard",
    "scale" => 2,
    "maxWidth" => 960,
    "maxPixels" => 8_000_000
  }

  test "all frozen ordinary source projections match Core preparation" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["referenceCommit"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(fixture["vectors"]) == 16

    for row <- fixture["vectors"] do
      assert Request.prepare(row["arguments"], row["resolved"]) == {:ok, row["result"]}, row["id"]
    end
  end

  test "unchanged input returns literal SDK result before planning" do
    assert {:ok, result} =
             Request.prepare(%{"before" => "", "after" => ""}, %{"defaults" => @defaults})

    assert result == %{
             "content" => [
               %{
                 "type" => "text",
                 "text" => "Before and after are identical — no changes to render."
               }
             ],
             "details" => %{"changed" => false}
           }

    assert {:ok, contextual} =
             Request.prepare(
               %{"before" => "😀\r\n", "after" => "😀\r\n", "mode" => "file"},
               %{
                 "defaults" => @defaults,
                 "context" => %{
                   "agentId" => "\uFEFF agent-1\u00A0",
                   "sessionId" => " session-1 ",
                   "messageChannel" => "\t\n",
                   "agentAccountId" => 7
                 }
               }
             )

    assert contextual["content"] == result["content"]

    assert contextual["details"] == %{
             "changed" => false,
             "context" => %{"agentId" => "agent-1", "sessionId" => "session-1"}
           }
  end

  test "ordinary plan preserves complete explicit presentation defaults" do
    assert {:ok, result} = Request.prepare(@changed, %{"defaults" => @defaults})

    assert result == %{
             "input" => %{"kind" => "before_after", "before" => "old\n", "after" => "new\n"},
             "options" => %{
               "presentation" => @defaults,
               "image" => @standard,
               "expandUnchanged" => false
             },
             "renderTarget" => "both",
             "mode" => "both",
             "ttlMs" => 1_800_000
           }

    assert {:ok, ^result} =
             Request.prepare(
               Map.merge(@changed, %{
                 "patch" => " \n",
                 "path" => "\t",
                 "lang" => "\uFEFF",
                 "title" => " "
               }),
               %{"defaults" => @defaults, "context" => %{}}
             )
  end

  test "patch trimming retains an explicitly blank title and omits an absent title" do
    assert {:ok, blank} =
             Request.prepare(
               %{"patch" => " \n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n \t", "title" => " \t"},
               %{"defaults" => @defaults}
             )

    assert blank["input"] == %{
             "kind" => "patch",
             "patch" => "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b",
             "title" => ""
           }

    assert {:ok, omitted} =
             Request.prepare(%{"patch" => "@@ -1 +1 @@\n-旧\n+新\n"}, %{"defaults" => @defaults})

    assert omitted["input"] == %{"kind" => "patch", "patch" => "@@ -1 +1 @@\n-旧\n+新"}
  end

  test "ECMAScript trimming preserves U+0085 and literal text line endings" do
    assert {:ok, result} =
             Request.prepare(
               %{
                 "before" => "😀 e\u0301\r\n",
                 "after" => "鍵 é\n",
                 "path" => "\uFEFF src/鍵.ts\u3000",
                 "lang" => "\u00A0typescript\u2029",
                 "title" => "\uFEFF\u0085Title\u0085\uFEFF"
               },
               %{"defaults" => @defaults, "languagePackAvailable" => false}
             )

    assert result["input"] == %{
             "kind" => "before_after",
             "before" => "😀 e\u0301\r\n",
             "after" => "鍵 é\n",
             "path" => "src/鍵.ts",
             "lang" => "typescript",
             "title" => "\u0085Title\u0085"
           }

    assert result["options"]["languagePackAvailable"] == false
  end

  test "all ordinary modes map render targets and explicit presentation overrides" do
    for {mode, target} <- [
          {"view", "viewer"},
          {"image", "image"},
          {"file", "image"},
          {"both", "both"}
        ] do
      assert {:ok, result} =
               Request.prepare(Map.put(@changed, "mode", mode), %{"defaults" => @defaults})

      assert result["mode"] == mode
      assert result["renderTarget"] == target
    end

    assert {:ok, view} =
             Request.prepare(
               Map.merge(@changed, %{
                 "theme" => "light",
                 "layout" => "split",
                 "expandUnchanged" => true
               }),
               %{"defaults" => @defaults, "languagePackAvailable" => true}
             )

    assert view["options"]["presentation"] ==
             Map.merge(@defaults, %{"theme" => "light", "layout" => "split"})

    assert view["options"]["expandUnchanged"] == true
    assert view["options"]["languagePackAvailable"] == true
  end

  test "explicit quality even when unchanged resets custom scale and width to profile" do
    defaults =
      Map.merge(@defaults, %{"fileQuality" => "hq", "fileScale" => 3.25, "fileMaxWidth" => 1700})

    assert {:ok, implicit} = Request.prepare(@changed, %{"defaults" => defaults})

    assert implicit["options"]["image"] == %{
             "format" => "png",
             "qualityPreset" => "hq",
             "scale" => 3.25,
             "maxWidth" => 1700,
             "maxPixels" => 14_000_000
           }

    assert {:ok, explicit} =
             Request.prepare(Map.put(@changed, "fileQuality", "hq"), %{"defaults" => defaults})

    assert explicit["options"]["image"] == %{
             "format" => "png",
             "qualityPreset" => "hq",
             "scale" => 2.5,
             "maxWidth" => 1200,
             "maxPixels" => 14_000_000
           }
  end

  test "positive decimal overrides retain binary64 rounding and TTL flooring" do
    assert {:ok, result} =
             Request.prepare(
               Map.merge(@changed, %{
                 "fileQuality" => "print",
                 "fileScale" => 1.005,
                 "fileMaxWidth" => 1200.5,
                 "ttlSeconds" => 1.2349
               }),
               %{"defaults" => @defaults}
             )

    assert result["options"]["image"] == %{
             "format" => "png",
             "qualityPreset" => "print",
             "scale" => 1,
             "maxWidth" => 1201,
             "maxPixels" => 24_000_000
           }

    assert result["ttlMs"] == 1234

    assert {:ok, rounded} =
             Request.prepare(
               Map.merge(@changed, %{
                 "fileScale" => 2.345,
                 "fileMaxWidth" => 999.49,
                 "ttlSeconds" => 1.0019
               }),
               %{"defaults" => @defaults}
             )

    assert rounded["options"]["image"]["scale"] == 2.35
    assert rounded["options"]["image"]["maxWidth"] == 999
    assert rounded["ttlMs"] == 1001
  end
end
