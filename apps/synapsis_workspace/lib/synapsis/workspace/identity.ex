defmodule Synapsis.Workspace.Identity do
  @moduledoc """
  Convenience API for workspace-driven identity files (AI-1).

  Identity files are plain markdown stored as workspace documents at conventional paths.
  They define agent personality, user profile, and environment context.

  ## Paths

  | File             | Path                           | Scope   |
  |------------------|--------------------------------|---------|
  | Soul             | `/global/soul.md`              | Global  |
  | Identity         | `/global/identity.md`          | Global  |
  | Bootstrap        | `/global/bootstrap.md`         | Global  |
  | Project Soul     | `/projects/<id>/soul.md`       | Project |
  | Project Context  | `/projects/<id>/context.md`    | Project |
  """

  alias Synapsis.Workspace

  @global_soul_path "/global/soul.md"
  @global_identity_path "/global/identity.md"
  @global_bootstrap_path "/global/bootstrap.md"
  @global_agents_path "/global/agents.md"
  @global_tools_path "/global/tools.md"
  @global_user_path "/global/user.md"
  @global_heartbeat_path "/global/heartbeat.md"
  @global_memory_path "/global/memory.md"

  @core_files [
    %{name: "AGENTS.md", path: @global_agents_path},
    %{name: "SOUL.md", path: @global_soul_path},
    %{name: "TOOLS.md", path: @global_tools_path},
    %{name: "IDENTITY.md", path: @global_identity_path},
    %{name: "USER.md", path: @global_user_path},
    %{name: "HEARTBEAT.md", path: @global_heartbeat_path},
    %{name: "BOOTSTRAP.md", path: @global_bootstrap_path},
    %{name: "MEMORY.md", path: @global_memory_path}
  ]

  @default_soul """
  # Soul

  You are a coding assistant built into Synapsis.

  ## Personality
  - Be direct and concise
  - Skip pleasantries — help immediately
  - Have opinions about code quality and architecture
  - When uncertain, say so — don't guess

  ## Boundaries
  - Ask before making destructive changes (deleting files, force-pushing)
  - Explain trade-offs when suggesting approaches
  - Respect the user's architectural decisions even when you'd choose differently

  ## Coding Style
  - Prefer functional patterns
  - Write tests for non-trivial changes
  - Commit messages should explain *why*, not just *what*
  """

  @default_identity """
  # User

  (Edit this file to tell the assistant about yourself.)

  ## Preferences
  - Language: (your primary programming language)
  - Editor: (your editor/IDE)
  - OS: (your operating system)
  """

  @default_bootstrap """
  # Environment

  (Edit this file to describe your development environment.)

  ## Tools
  - Version control: git
  - Package manager: (your package manager)

  ## Conventions
  - (Add project-wide conventions here)
  """

  @default_agents """
  # Agents

  Configure agent profiles and routing rules.

  ## Default Agent
  - Mode: build
  - Reasoning: medium
  - Read-only: no

  ## Custom Agents
  (Define custom agent profiles in .opencode.json or here.)
  """

  @default_tools """
  # Tools

  Tool access preferences and guidance for the assistant.

  ## Enabled Categories
  - Filesystem: read, write, edit, delete, move
  - Search: grep, glob
  - Execution: bash
  - Web: fetch, search

  ## Guidance
  (Add tool usage preferences and constraints here.)
  """

  @default_user """
  # User Profile

  (Edit this file to describe yourself to the assistant.)

  ## Name
  (Your name)

  ## Role
  (Your role — developer, designer, data scientist, etc.)

  ## Working Style
  (How you prefer to work — e.g., TDD, prototype-first, etc.)
  """

  @default_heartbeat """
  # Heartbeat

  Proactive execution schedules and configuration.

  ## Schedules
  (Configure heartbeat schedules here or via the Cron Jobs tab.)

  ## Templates
  - morning-briefing: Summarize overnight activity (disabled)
  - stale-pr-check: Check for stale PRs (disabled)
  - daily-summary: End-of-day summary (disabled)
  """

  @default_memory """
  # Memory

  Long-term memory notes and preferences for the assistant.

  (The assistant will automatically load relevant memories into context.
  You can also manually add notes here for the assistant to reference.)
  """

  @doc """
  Load the soul content for a given project. Returns global soul, project soul,
  or concatenation of both per RD-1 precedence rules.

  Returns `nil` if no soul file exists.
  """
  @spec load_soul(String.t() | nil) :: String.t() | nil
  def load_soul(project_id \\ nil) do
    global = read_content(@global_soul_path)

    project =
      if project_id do
        read_content("/projects/#{project_id}/soul.md")
      end

    case {global, project} do
      {nil, nil} -> nil
      {g, nil} -> g
      {nil, p} -> p
      {g, p} -> g <> "\n\n<!-- Project-specific -->\n\n" <> p
    end
  end

  @doc "Load user identity content. Returns `nil` if not set."
  @spec load_identity() :: String.t() | nil
  def load_identity do
    read_content(@global_identity_path)
  end

  @doc "Load bootstrap/environment content. Returns `nil` if not set."
  @spec load_bootstrap() :: String.t() | nil
  def load_bootstrap do
    read_content(@global_bootstrap_path)
  end

  @doc "Load project-specific context. Returns `nil` if not set."
  @spec load_project_context(String.t()) :: String.t() | nil
  def load_project_context(project_id) do
    read_content("/projects/#{project_id}/context.md")
  end

  @doc """
  Load all identity files into a map.

  Returns a map with keys `:soul`, `:identity`, `:bootstrap`, `:project_soul`,
  `:project_context`. Values are `nil` when file doesn't exist.
  """
  @spec load_all(String.t() | nil) :: %{
          soul: String.t() | nil,
          identity: String.t() | nil,
          bootstrap: String.t() | nil,
          project_soul: String.t() | nil,
          project_context: String.t() | nil
        }
  def load_all(project_id \\ nil) do
    %{
      soul: load_soul(project_id),
      identity: load_identity(),
      bootstrap: load_bootstrap(),
      project_soul: if(project_id, do: read_content("/projects/#{project_id}/soul.md")),
      project_context: if(project_id, do: read_content("/projects/#{project_id}/context.md"))
    }
  end

  @doc "Returns the list of core identity files with name and path."
  @spec core_files() :: [%{name: String.t(), path: String.t()}]
  def core_files, do: @core_files

  @doc """
  Seed default identity files on first run. Idempotent — does not overwrite
  existing files.
  """
  @spec seed_defaults() :: :ok
  def seed_defaults do
    seed_if_missing(@global_soul_path, @default_soul)
    seed_if_missing(@global_identity_path, @default_identity)
    seed_if_missing(@global_bootstrap_path, @default_bootstrap)
    seed_if_missing(@global_agents_path, @default_agents)
    seed_if_missing(@global_tools_path, @default_tools)
    seed_if_missing(@global_user_path, @default_user)
    seed_if_missing(@global_heartbeat_path, @default_heartbeat)
    seed_if_missing(@global_memory_path, @default_memory)
    :ok
  end

  @doc "Returns the default soul content."
  @spec default_soul() :: String.t()
  def default_soul, do: @default_soul

  @doc "Returns the default identity content."
  @spec default_identity() :: String.t()
  def default_identity, do: @default_identity

  @doc "Returns the default bootstrap content."
  @spec default_bootstrap() :: String.t()
  def default_bootstrap, do: @default_bootstrap

  # -- Private --

  defp read_content(path) do
    case Workspace.read(path) do
      {:ok, resource} -> resource.content
      {:error, _reason} -> nil
    end
  end

  defp seed_if_missing(path, content) do
    unless Workspace.exists?(path) do
      Workspace.write(path, content, %{author: "system", lifecycle: :shared})
    end
  end
end
