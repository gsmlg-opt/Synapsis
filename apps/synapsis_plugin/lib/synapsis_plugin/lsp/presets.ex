defmodule SynapsisPlugin.LSP.Presets do
  @moduledoc """
  Data-driven LSP server presets for supported languages.

  Presets match the official Claude Code LSP plugins from the Anthropic marketplace.
  Each preset is a built-in LSP that can be enabled/disabled via the UI.
  """

  alias Synapsis.{Repo, PluginConfig}
  import Ecto.Query, only: [from: 2]

  @presets [
    %{
      name: "typescript",
      description: "TypeScript/JavaScript language server for enhanced code intelligence",
      command: "typescript-language-server",
      args: ["--stdio"],
      extensions: [".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs"],
      markers: ["package.json", "tsconfig.json"],
      extension_to_language: %{
        ".ts" => "typescript",
        ".tsx" => "typescriptreact",
        ".js" => "javascript",
        ".jsx" => "javascriptreact",
        ".mts" => "typescript",
        ".cts" => "typescript",
        ".mjs" => "javascript",
        ".cjs" => "javascript"
      }
    },
    %{
      name: "pyright",
      description: "Python language server (Pyright) for type checking and code intelligence",
      command: "pyright-langserver",
      args: ["--stdio"],
      extensions: [".py", ".pyi"],
      markers: ["pyproject.toml", "setup.py", "requirements.txt"],
      extension_to_language: %{".py" => "python", ".pyi" => "python"}
    },
    %{
      name: "gopls",
      description: "Go language server for code intelligence and refactoring",
      command: "gopls",
      args: [],
      extensions: [".go"],
      markers: ["go.mod"],
      extension_to_language: %{".go" => "go"}
    },
    %{
      name: "rust-analyzer",
      description: "Rust language server for code intelligence and analysis",
      command: "rust-analyzer",
      args: [],
      extensions: [".rs"],
      markers: ["Cargo.toml"],
      extension_to_language: %{".rs" => "rust"}
    },
    %{
      name: "clangd",
      description: "C/C++ language server (clangd) for code intelligence",
      command: "clangd",
      args: ["--background-index"],
      extensions: [".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".hxx", ".C", ".H"],
      markers: ["CMakeLists.txt", "Makefile"],
      extension_to_language: %{
        ".c" => "c",
        ".h" => "c",
        ".cpp" => "cpp",
        ".cc" => "cpp",
        ".cxx" => "cpp",
        ".hpp" => "cpp",
        ".hxx" => "cpp",
        ".C" => "cpp",
        ".H" => "cpp"
      }
    },
    %{
      name: "elixir-ls",
      description: "Elixir language server for code intelligence and debugging",
      command: "elixir-ls",
      args: ["--stdio"],
      extensions: [".ex", ".exs"],
      markers: ["mix.exs"],
      extension_to_language: %{".ex" => "elixir", ".exs" => "elixir"}
    },
    %{
      name: "intelephense",
      description: "PHP language server (Intelephense) for code intelligence",
      command: "intelephense",
      args: ["--stdio"],
      extensions: [".php"],
      markers: ["composer.json"],
      extension_to_language: %{".php" => "php"}
    },
    %{
      name: "sourcekit-lsp",
      description: "Swift language server (SourceKit-LSP) for code intelligence",
      command: "sourcekit-lsp",
      args: [],
      extensions: [".swift"],
      markers: ["Package.swift"],
      extension_to_language: %{".swift" => "swift"}
    },
    %{
      name: "kotlin-lsp",
      description: "Kotlin language server for code intelligence",
      command: "kotlin-lsp",
      args: ["--stdio"],
      extensions: [".kt", ".kts"],
      markers: ["build.gradle", "build.gradle.kts"],
      extension_to_language: %{".kt" => "kotlin", ".kts" => "kotlin"}
    },
    %{
      name: "csharp-ls",
      description: "C# language server for code intelligence",
      command: "csharp-ls",
      args: [],
      extensions: [".cs"],
      markers: ["*.csproj", "*.sln"],
      extension_to_language: %{".cs" => "csharp"}
    },
    %{
      name: "jdtls",
      description: "Java language server (Eclipse JDT.LS) for code intelligence",
      command: "jdtls",
      args: [],
      extensions: [".java"],
      markers: ["pom.xml", "build.gradle"],
      extension_to_language: %{".java" => "java"}
    },
    %{
      name: "lua-language-server",
      description: "Lua language server for code intelligence",
      command: "lua-language-server",
      args: [],
      extensions: [".lua"],
      markers: [".luarc.json"],
      extension_to_language: %{".lua" => "lua"}
    },
    %{
      name: "ruby-lsp",
      description: "Ruby language server for code intelligence and analysis",
      command: "ruby-lsp",
      args: [],
      extensions: [".rb", ".rake", ".gemspec", ".ru", ".erb"],
      markers: ["Gemfile"],
      extension_to_language: %{
        ".rb" => "ruby",
        ".rake" => "ruby",
        ".gemspec" => "ruby",
        ".ru" => "ruby",
        ".erb" => "erb"
      }
    }
  ]

  @doc "Return all built-in LSP presets."
  def all, do: @presets

  @doc "Get a preset by name. Returns nil for unknown."
  def get(name) do
    Enum.find(@presets, &(&1.name == name))
  end

  @doc "Check if a name corresponds to a built-in preset."
  def builtin?(name) do
    Enum.any?(@presets, &(&1.name == name))
  end

  @doc "Resolve `{command, args}` for a language from presets. Returns nil for unknown."
  def lsp_command(name) do
    case get(name) do
      nil -> nil
      preset -> {preset.command, preset.args}
    end
  end

  @doc "Detect languages present in a project directory using file extensions and markers."
  def detect_languages(project_path) do
    @presets
    |> Enum.filter(fn preset ->
      has_extensions?(project_path, preset.extensions) ||
        has_markers?(project_path, preset.markers)
    end)
    |> Enum.map(& &1.name)
  end

  @doc "Insert all presets into plugin_configs as type \"lsp\" (idempotent)."
  def seed_defaults do
    Enum.each(@presets, fn preset ->
      %PluginConfig{}
      |> PluginConfig.changeset(%{
        type: "lsp",
        name: preset.name,
        command: preset.command,
        args: preset.args,
        auto_start: false
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:name, :scope, :project_id]
      )
    end)

    :ok
  end

  @doc "Return names of presets already configured in the database."
  def configured_names do
    Repo.all(from(p in PluginConfig, where: p.type == "lsp", select: p.name))
  end

  defp has_extensions?(project_path, extensions) do
    Enum.any?(extensions, fn ext ->
      project_path
      |> Path.join("**/*#{ext}")
      |> Path.wildcard()
      |> Enum.any?()
    end)
  end

  defp has_markers?(project_path, markers) do
    Enum.any?(markers, fn marker ->
      project_path
      |> Path.join(marker)
      |> File.exists?()
    end)
  end
end
