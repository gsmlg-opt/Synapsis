defmodule Synapsis.Diffs.ConfigFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Config.Store
  alias Synapsis.Diffs.Config

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

  setup do
    partition = System.get_env("MIX_TEST_PARTITION", "0")

    root =
      Path.join(System.tmp_dir!(), "synapsis-diffs-config-#{partition}-#{Ecto.UUID.generate()}")

    File.mkdir_p!(root)
    previous = System.get_env("SYNAPSIS_CONFIG_DIR")

    on_exit(fn ->
      if previous,
        do: System.put_env("SYNAPSIS_CONFIG_DIR", previous),
        else: System.delete_env("SYNAPSIS_CONFIG_DIR")

      Store.reload(:diffs)
      File.rm_rf!(root)
    end)

    System.put_env("SYNAPSIS_CONFIG_DIR", root)
    %{root: root}
  end

  test "resolves the complete source defaults and data-owned host defaults", %{root: root} do
    assert {:ok, resolved} = Config.resolve(%{})
    assert resolved["id"] == "default"
    assert resolved["defaults"] == @defaults
    assert resolved["security"] == %{"allowRemoteViewer" => false}

    assert resolved["host"] == %{
             "artifactRoot" => Path.join(root, "diffs"),
             "timeoutMs" => 120_000
           }

    assert Map.keys(resolved) |> Enum.sort() == ~w(defaults host id security)
  end

  test "resolves every deprecated file alias and quality profile with source precedence" do
    for {quality, scale, width} <- [
          {"standard", 2, 960},
          {"hq", 2.5, 1200},
          {"print", 3, 1400}
        ] do
      assert {:ok, resolved} = Config.resolve(%{"defaults" => %{"imageQuality" => quality}})

      assert resolved["defaults"] ==
               Map.merge(@defaults, %{
                 "fileQuality" => quality,
                 "fileScale" => scale,
                 "fileMaxWidth" => width
               })
    end

    for alias_name <- ~w(format imageFormat) do
      assert {:ok, resolved} = Config.resolve(%{"defaults" => %{alias_name => "pdf"}})
      assert resolved["defaults"] == %{@defaults | "fileFormat" => "pdf"}
    end

    assert {:ok, aliased} =
             Config.resolve(%{
               "defaults" => %{
                 "imageFormat" => "pdf",
                 "format" => "png",
                 "imageQuality" => "hq",
                 "imageScale" => 2.25,
                 "imageMaxWidth" => 1100
               }
             })

    assert aliased["defaults"] ==
             Map.merge(@defaults, %{
               "fileFormat" => "pdf",
               "fileQuality" => "hq",
               "fileScale" => 2.25,
               "fileMaxWidth" => 1100
             })

    assert {:ok, canonical} =
             Config.resolve(%{
               "defaults" => %{
                 "fileFormat" => "png",
                 "imageFormat" => "pdf",
                 "format" => "pdf",
                 "fileQuality" => "print",
                 "imageQuality" => "hq",
                 "fileScale" => 2.75,
                 "imageScale" => 2.25,
                 "fileMaxWidth" => 1300,
                 "imageMaxWidth" => 1100
               }
             })

    assert canonical["defaults"] ==
             Map.merge(@defaults, %{
               "fileQuality" => "print",
               "fileScale" => 2.75,
               "fileMaxWidth" => 1300
             })
  end

  test "retains authored presentation and host settings with a prefixed viewer URL", %{root: root} do
    defaults = %{
      "fontFamily" => "JetBrains Mono",
      "fontSize" => 17,
      "lineSpacing" => 1.8,
      "layout" => "split",
      "showLineNumbers" => false,
      "diffIndicators" => "classic",
      "wordWrap" => false,
      "background" => false,
      "theme" => "light",
      "fileFormat" => "pdf",
      "fileQuality" => "hq",
      "fileScale" => 2.25,
      "fileMaxWidth" => 1120,
      "mode" => "image",
      "ttlSeconds" => 2400
    }

    host = %{
      "nodeExecutable" => Path.join(root, "node"),
      "chromiumExecutable" => Path.join(root, "chromium"),
      "helperPath" => Path.join(root, "stdio.mjs"),
      "artifactRoot" => Path.join(root, "published"),
      "timeoutMs" => 60_000
    }

    assert {:ok, resolved} =
             Config.resolve(%{
               "id" => "default",
               "defaults" => defaults,
               "viewerBaseUrl" => "  https://diffs.example.test/ops/  ",
               "host" => host
             })

    assert resolved["defaults"] == defaults
    assert resolved["host"] == host
    assert resolved["viewerBaseUrl"] == "https://diffs.example.test/ops"
  end

  test "persists and reloads a singleton through Config.Store", %{root: root} do
    assert :diffs in Store.types()
    assert Store.file_path(:diffs) == Path.join(root, "diffs.toml")
    File.write!(Store.file_path(:diffs), "")
    assert :ok = Store.reload(:diffs)

    entry = %{
      "id" => "default",
      "defaults" => %{"fileFormat" => "pdf", "fileQuality" => "print"},
      "viewerBaseUrl" => "https://diffs.example.test/team",
      "host" => %{"artifactRoot" => Path.join(root, "published"), "timeoutMs" => 60_000}
    }

    assert {:ok, saved} = Store.put(:diffs, entry)
    assert {:ok, expected} = Config.resolve(saved)
    assert {:ok, ^expected} = Config.load()
    assert [^saved] = Store.list(:diffs)

    assert {:ok, decoded} = Store.file_path(:diffs) |> File.read!() |> Toml.decode()
    assert decoded["defaults"]["fileFormat"] == "pdf"
    assert decoded["viewerBaseUrl"] == entry["viewerBaseUrl"]
    assert is_map(decoded["host"])

    assert :ok = Store.reload(:diffs)
    assert {:ok, ^saved} = Store.get(:diffs, "default")
    assert {:ok, ^expected} = Config.load()
    assert [^saved] = Store.list(:diffs)
  end
end
