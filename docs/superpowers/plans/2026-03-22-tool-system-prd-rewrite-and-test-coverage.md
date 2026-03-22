# Tool System PRD Rewrite & Test Coverage Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the tool system PRD to match the actual codebase, then add dedicated unit tests for every tool that lacks them.

**Architecture:** Tools live in `apps/synapsis_core/lib/synapsis/tool/` under the `Synapsis.Tool` namespace. The behaviour macro is at `apps/synapsis_core/lib/synapsis/tool.ex`. The PRD at `docs/prd/tool_system.md` must be rewritten — it currently references a non-existent `synapsis_tool` sub-app with `SynapsisTool.*` module paths. The test suite lives at `apps/synapsis_core/test/synapsis/tool/`. Each tool should have a dedicated test file.

**Tech Stack:** Elixir 1.18+, OTP 28+, ExUnit, Bypass (HTTP mocking), Phoenix.PubSub

**Scope:** Only `docs/prd/tool_system.md` and `apps/synapsis_core/test/synapsis/tool/` — no changes to tool implementations.

**Key return types (all tools return plain strings, NOT structs):**
- `FileRead.execute/2` → `{:ok, "file content string"}` or `{:error, "error msg"}`
- `FileWrite.execute/2` → `{:ok, "Successfully wrote N bytes to path"}` or `{:error, "..."}`
- `FileEdit.execute/2` → `{:ok, json_string}` (JSON with status/path/message/diff) or `{:error, "..."}`
- `FileDelete.execute/2` → `{:ok, "Successfully deleted path"}` or `{:error, "..."}`
- `FileMove.execute/2` → `{:ok, "Moved src to dst"}` or `{:error, "..."}`
- `ListDir.execute/2` → `{:ok, "entry1\nentry2\n..."}` or `{:error, "..."}`
- `Grep.execute/2` → `{:ok, "match output"}` or `{:ok, "No matches found."}` or `{:error, "..."}`
- `Glob.execute/2` → `{:ok, "file1\nfile2"}` or `{:ok, "No files matched..."}` or `{:error, "..."}`
- `Bash.execute/2` → `{:ok, "output"}` (exit 0) or `{:ok, "Exit code: N\noutput"}` (non-zero) or `{:error, "timeout"}`
- `FileEdit` uses parameter keys `"old_string"` and `"new_string"` (NOT `old_text`/`new_text`)
- `Grep` uses parameter key `"include"` for glob filtering (NOT `"glob"`)

---

## Phase 1: PRD Rewrite

### Task 1: Rewrite PRD Header, Architecture, and Behaviour Contract

**Files:**
- Modify: `docs/prd/tool_system.md`
- Reference: `apps/synapsis_core/lib/synapsis/tool.ex` (behaviour macro, NOT `tool/tool.ex`)
- Reference: `apps/synapsis_core/lib/synapsis/tool/registry.ex`
- Reference: `apps/synapsis_core/lib/synapsis/tool/executor.ex`
- Reference: `apps/synapsis_core/lib/synapsis/tool/permission.ex`

- [ ] **Step 1: Read current tool.ex, registry.ex, executor.ex, permission.ex to capture actual APIs**

Read all four files to extract the real callback signatures, module names, and public APIs.

- [ ] **Step 2: Rewrite sections 1-3 of the PRD**

Replace:
- All `SynapsisTool` → `Synapsis.Tool`
- All `SynapsisTool.Tools.*` → `Synapsis.Tool.*`
- All `SynapsisTool.Registry` → `Synapsis.Tool.Registry`
- All `SynapsisTool.Executor` → `Synapsis.Tool.Executor`
- All `SynapsisTool.Permissions` → `Synapsis.Tool.Permission`
- Remove `apps/synapsis_tool/` references → tools live in `apps/synapsis_core/lib/synapsis/tool/`
- Update dependency graph to match the Constitution in CLAUDE.md:
  ```
  synapsis_data → synapsis_core (tools live here) → synapsis_server/web/lsp/cli
  ```
- Update behaviour contract code to match actual `tool.ex` (`use Synapsis.Tool` macro, `@impl true`)
- Update registry API to match actual `registry.ex` public functions
- Update executor pipeline to match actual `executor.ex` flow
- Update permission model to match actual `permission.ex` (3-step resolution)

- [ ] **Step 3: Verify no code was accidentally broken**

Run: `devenv shell -- bash -c 'mix compile --warnings-as-errors 2>&1 | tail -5'`
Expected: Compilation successful

- [ ] **Step 4: Commit**

```bash
git add docs/prd/tool_system.md
git commit -m "docs(prd): rewrite tool system sections 1-3 to match actual codebase"
```

### Task 2: Rewrite PRD Tool Inventory (Sections 4-5)

**Files:**
- Modify: `docs/prd/tool_system.md`
- Reference: `apps/synapsis_core/lib/synapsis/tool/builtin.ex` (lists all 31 registered tools)
- Reference: All tool files in `apps/synapsis_core/lib/synapsis/tool/`

- [ ] **Step 1: Read builtin.ex to get the actual tool registration list**

This file lists all tools registered at startup. Extract exact names, modules, and categories.

- [ ] **Step 2: Rewrite section 4 (Complete Tool Inventory)**

Update every tool entry:
- Module paths: `SynapsisTool.Tools.FileRead` → `Synapsis.Tool.FileRead`
- Add tools not in original PRD:
  - `memory_save` (category: memory, permission: :write)
  - `memory_search` (category: memory, permission: :read)
  - `memory_update` (category: memory, permission: :write)
  - `session_summarize` (category: memory, permission: :none)
  - `diagnostics` (category: special, permission: :read)
- Update tool count from 27 to actual count from builtin.ex
- Add new category sections: Memory Tools, Diagnostics
- Update summary table to include all tools
- Note: file_read does NOT support PDF parsing
- Note: bash uses ephemeral Port per command (NOT persistent session)
- Note: file_edit uses `old_string`/`new_string` params (NOT `old_text`/`new_text`)
- Note: task tool is currently stubbed (`enabled? = false`)

- [ ] **Step 3: Rewrite section 5 (Summary Table)**

Regenerate the summary table with all tools, correct module paths, and accurate enabled/disabled status.

- [ ] **Step 4: Commit**

```bash
git add docs/prd/tool_system.md
git commit -m "docs(prd): rewrite tool inventory to include all tools"
```

### Task 3: Rewrite PRD Sections 6-10 (Permission, Side Effects, Integration)

**Files:**
- Modify: `docs/prd/tool_system.md`
- Reference: `apps/synapsis_core/lib/synapsis/tool/permission.ex`
- Reference: `apps/synapsis_core/lib/synapsis/tool/permission/session_config.ex`
- Reference: `apps/synapsis_core/lib/synapsis/tool/context.ex`

- [ ] **Step 1: Read permission.ex, session_config.ex, context.ex**

Extract actual permission resolution logic, session config schema, and context struct.

- [ ] **Step 2: Rewrite sections 6-10**

- Section 6 (Permission Model): Update to match actual 3-step resolution in permission.ex
- Section 7 (Side Effect System): Verify PubSub topic format
- Section 8 (Plugin Tool Integration): Update module paths
- Section 9 (Agent Loop Integration): Update to reference graph-based runner in `synapsis_agent` (NOT simple loop)
  - Reference: `apps/synapsis_agent/lib/synapsis/agent/nodes/tool_dispatch.ex`
  - Reference: `apps/synapsis_agent/lib/synapsis/agent/nodes/tool_execute.ex`
- Section 10 (Data Persistence): Verify table names match actual migrations
- Remove the `synapsis_tool` sub-app dependency diagram

- [ ] **Step 3: Final consistency review**

Read complete rewritten PRD. Verify: no remaining `SynapsisTool` references, no `synapsis_tool` app references, all module paths match real files.

- [ ] **Step 4: Commit**

```bash
git add docs/prd/tool_system.md
git commit -m "docs(prd): complete tool system PRD rewrite"
```

---

## Phase 2: Per-Tool Unit Tests

Each task creates a dedicated test file for tools that currently lack one. All tools return **plain strings** from `execute/2`. Tests use `@tag :tmp_dir` for filesystem operations. Pattern after existing `tools_test.exs` style: `{:ok, content} = Tool.execute(input, ctx)` where `content` is a string.

### Task 4: file_read unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/file_read_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/file_read.ex`

- [ ] **Step 1: Write the test file**

```elixir
defmodule Synapsis.Tool.FileReadTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileRead

  @tag :tmp_dir
  test "reads entire file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.txt")
    File.write!(path, "line 1\nline 2\nline 3\n")

    {:ok, content} = FileRead.execute(%{"path" => path}, %{project_path: tmp_dir})
    assert content =~ "line 1"
    assert content =~ "line 3"
  end

  @tag :tmp_dir
  test "reads with offset and limit", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "test.txt")
    lines = Enum.map_join(1..20, "\n", &"line #{&1}")
    File.write!(path, lines)

    {:ok, content} = FileRead.execute(
      %{"path" => path, "offset" => 5, "limit" => 3},
      %{project_path: tmp_dir}
    )
    assert content =~ "line 6"
    refute content =~ "line 1"
  end

  @tag :tmp_dir
  test "returns error for missing file", %{tmp_dir: tmp_dir} do
    {:error, msg} = FileRead.execute(%{"path" => Path.join(tmp_dir, "missing.txt")}, %{project_path: tmp_dir})
    assert msg =~ "not found"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, msg} = FileRead.execute(%{"path" => "/etc/passwd"}, %{project_path: tmp_dir})
    assert msg =~ "outside project root"
  end

  @tag :tmp_dir
  test "reads empty file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "empty.txt")
    File.write!(path, "")

    {:ok, content} = FileRead.execute(%{"path" => path}, %{project_path: tmp_dir})
    assert content == ""
  end

  test "returns correct metadata" do
    assert FileRead.name() == "file_read"
    assert FileRead.permission_level() == :read
    assert FileRead.category() == :filesystem
    assert is_binary(FileRead.description())
    assert is_map(FileRead.parameters())
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/file_read_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/file_read_test.exs
git commit -m "test(tool): add dedicated file_read unit tests"
```

### Task 5: file_write unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/file_write_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/file_write.ex`

- [ ] **Step 1: Write the test file**

```elixir
defmodule Synapsis.Tool.FileWriteTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileWrite

  @tag :tmp_dir
  test "creates new file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "new.txt")

    {:ok, msg} = FileWrite.execute(%{"path" => path, "content" => "hello"}, %{project_path: tmp_dir})
    assert msg =~ "Successfully wrote"
    assert File.read!(path) == "hello"
  end

  @tag :tmp_dir
  test "creates parent directories", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "nested", "deep", "file.txt"])

    {:ok, _} = FileWrite.execute(%{"path" => path, "content" => "nested"}, %{project_path: tmp_dir})
    assert File.read!(path) == "nested"
  end

  @tag :tmp_dir
  test "overwrites existing file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "existing.txt")
    File.write!(path, "old content")

    {:ok, _} = FileWrite.execute(%{"path" => path, "content" => "new content"}, %{project_path: tmp_dir})
    assert File.read!(path) == "new content"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} = FileWrite.execute(%{"path" => "/tmp/evil.txt", "content" => "bad"}, %{project_path: tmp_dir})
  end

  test "declares write permission and file_changed side effect" do
    assert FileWrite.permission_level() == :write
    assert :file_changed in FileWrite.side_effects()
    assert FileWrite.category() == :filesystem
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/file_write_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/file_write_test.exs
git commit -m "test(tool): add dedicated file_write unit tests"
```

### Task 6: file_edit unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/file_edit_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/file_edit.ex`

- [ ] **Step 1: Write the test file**

Note: FileEdit uses `"old_string"` and `"new_string"` params (NOT `old_text`/`new_text`).
FileEdit returns `{:ok, json_string}` where the JSON has `status`, `path`, `message`, `diff` fields.

```elixir
defmodule Synapsis.Tool.FileEditTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileEdit

  @tag :tmp_dir
  test "replaces exact match", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "edit.txt")
    File.write!(path, "hello world")

    {:ok, json} = FileEdit.execute(
      %{"path" => path, "old_string" => "hello", "new_string" => "goodbye"},
      %{project_path: tmp_dir}
    )
    assert File.read!(path) == "goodbye world"
    assert json =~ "ok"
  end

  @tag :tmp_dir
  test "fails when old_string not found", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "edit.txt")
    File.write!(path, "hello world")

    {:error, msg} = FileEdit.execute(
      %{"path" => path, "old_string" => "missing", "new_string" => "replacement"},
      %{project_path: tmp_dir}
    )
    assert msg =~ "not found"
    assert File.read!(path) == "hello world"
  end

  @tag :tmp_dir
  test "fails when file does not exist", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "nonexistent.txt")

    {:error, msg} = FileEdit.execute(
      %{"path" => path, "old_string" => "a", "new_string" => "b"},
      %{project_path: tmp_dir}
    )
    assert msg =~ "not found"
  end

  @tag :tmp_dir
  test "handles multiline replacements", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "multi.txt")
    File.write!(path, "line 1\nline 2\nline 3\n")

    {:ok, _} = FileEdit.execute(
      %{"path" => path, "old_string" => "line 2\nline 3", "new_string" => "replaced"},
      %{project_path: tmp_dir}
    )
    assert File.read!(path) == "line 1\nreplaced\n"
  end

  @tag :tmp_dir
  test "handles multiple occurrences by replacing first", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "dupes.txt")
    File.write!(path, "foo bar foo baz foo")

    {:ok, json} = FileEdit.execute(
      %{"path" => path, "old_string" => "foo", "new_string" => "qux"},
      %{project_path: tmp_dir}
    )
    assert File.read!(path) == "qux bar foo baz foo"
    assert json =~ "first occurrence"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, msg} = FileEdit.execute(
      %{"path" => "/etc/passwd", "old_string" => "root", "new_string" => "evil"},
      %{project_path: tmp_dir}
    )
    assert msg =~ "outside project root"
  end

  test "declares write permission and file_changed side effect" do
    assert FileEdit.permission_level() == :write
    assert :file_changed in FileEdit.side_effects()
    assert FileEdit.category() == :filesystem
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/file_edit_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/file_edit_test.exs
git commit -m "test(tool): add dedicated file_edit unit tests"
```

### Task 7: file_delete unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/file_delete_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/file_delete.ex`

- [ ] **Step 1: Write the test file**

```elixir
defmodule Synapsis.Tool.FileDeleteTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileDelete

  @tag :tmp_dir
  test "deletes existing file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "doomed.txt")
    File.write!(path, "goodbye")

    {:ok, msg} = FileDelete.execute(%{"path" => path}, %{project_path: tmp_dir})
    assert msg =~ "Successfully deleted"
    refute File.exists?(path)
  end

  @tag :tmp_dir
  test "returns error for missing file", %{tmp_dir: tmp_dir} do
    {:error, msg} = FileDelete.execute(%{"path" => Path.join(tmp_dir, "ghost.txt")}, %{project_path: tmp_dir})
    assert msg =~ "does not exist"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} = FileDelete.execute(%{"path" => "/tmp/nope.txt"}, %{project_path: tmp_dir})
  end

  test "declares destructive permission and file_changed side effect" do
    assert FileDelete.permission_level() == :destructive
    assert :file_changed in FileDelete.side_effects()
    assert FileDelete.category() == :filesystem
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/file_delete_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/file_delete_test.exs
git commit -m "test(tool): add dedicated file_delete unit tests"
```

### Task 8: file_move unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/file_move_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/file_move.ex`

- [ ] **Step 1: Write the test file**

```elixir
defmodule Synapsis.Tool.FileMoveTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.FileMove

  @tag :tmp_dir
  test "moves file to new location", %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "original.txt")
    dst = Path.join(tmp_dir, "moved.txt")
    File.write!(src, "content")

    {:ok, msg} = FileMove.execute(%{"source" => src, "destination" => dst}, %{project_path: tmp_dir})
    assert msg =~ "Moved"
    refute File.exists?(src)
    assert File.read!(dst) == "content"
  end

  @tag :tmp_dir
  test "creates destination parent directories", %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "file.txt")
    dst = Path.join([tmp_dir, "nested", "dir", "file.txt"])
    File.write!(src, "data")

    {:ok, _} = FileMove.execute(%{"source" => src, "destination" => dst}, %{project_path: tmp_dir})
    assert File.read!(dst) == "data"
  end

  @tag :tmp_dir
  test "returns error when source does not exist", %{tmp_dir: tmp_dir} do
    {:error, msg} = FileMove.execute(
      %{"source" => Path.join(tmp_dir, "nope.txt"), "destination" => Path.join(tmp_dir, "dest.txt")},
      %{project_path: tmp_dir}
    )
    assert msg =~ "does not exist"
  end

  @tag :tmp_dir
  test "rejects source path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} = FileMove.execute(
      %{"source" => "/etc/passwd", "destination" => Path.join(tmp_dir, "stolen.txt")},
      %{project_path: tmp_dir}
    )
  end

  test "declares write permission and file_changed side effect" do
    assert FileMove.permission_level() == :write
    assert :file_changed in FileMove.side_effects()
    assert FileMove.category() == :filesystem
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/file_move_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/file_move_test.exs
git commit -m "test(tool): add dedicated file_move unit tests"
```

### Task 9: list_dir unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/list_dir_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/list_dir.ex`

- [ ] **Step 1: Write the test file**

```elixir
defmodule Synapsis.Tool.ListDirTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.ListDir

  @tag :tmp_dir
  test "lists directory contents", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "a.txt"), "")
    File.write!(Path.join(tmp_dir, "b.txt"), "")
    File.mkdir_p!(Path.join(tmp_dir, "subdir"))

    {:ok, content} = ListDir.execute(%{"path" => tmp_dir}, %{project_path: tmp_dir})
    assert content =~ "a.txt"
    assert content =~ "b.txt"
    assert content =~ "subdir"
  end

  @tag :tmp_dir
  test "handles empty directory", %{tmp_dir: tmp_dir} do
    empty = Path.join(tmp_dir, "empty")
    File.mkdir_p!(empty)

    {:ok, content} = ListDir.execute(%{"path" => empty}, %{project_path: tmp_dir})
    assert content == ""
  end

  @tag :tmp_dir
  test "returns error for nonexistent directory", %{tmp_dir: tmp_dir} do
    {:error, msg} = ListDir.execute(%{"path" => Path.join(tmp_dir, "nope")}, %{project_path: tmp_dir})
    assert msg =~ "does not exist"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} = ListDir.execute(%{"path" => "/etc"}, %{project_path: tmp_dir})
  end

  @tag :tmp_dir
  test "respects depth parameter", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join([tmp_dir, "a", "b", "c"]))
    File.write!(Path.join([tmp_dir, "a", "b", "c", "deep.txt"]), "")

    {:ok, shallow} = ListDir.execute(%{"path" => tmp_dir, "depth" => 1}, %{project_path: tmp_dir})
    {:ok, deep} = ListDir.execute(%{"path" => tmp_dir, "depth" => 4}, %{project_path: tmp_dir})
    # Deep listing should include more entries than shallow
    assert String.length(deep) >= String.length(shallow)
  end

  test "declares read permission and filesystem category" do
    assert ListDir.permission_level() == :read
    assert ListDir.category() == :filesystem
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/list_dir_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/list_dir_test.exs
git commit -m "test(tool): add dedicated list_dir unit tests"
```

### Task 10: grep unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/grep_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/grep.ex`

- [ ] **Step 1: Write the test file**

Note: Grep uses `"include"` param for file filtering (NOT `"glob"`).

```elixir
defmodule Synapsis.Tool.GrepTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Grep

  @tag :tmp_dir
  test "finds pattern in files", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "haystack.txt"), "needle in a haystack\nno match here\nneedle again")

    {:ok, content} = Grep.execute(
      %{"pattern" => "needle", "path" => tmp_dir},
      %{project_path: tmp_dir}
    )
    assert content =~ "needle"
  end

  @tag :tmp_dir
  test "returns no-matches message when pattern not found", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "file.txt"), "nothing relevant here")

    {:ok, content} = Grep.execute(
      %{"pattern" => "zzz_no_match_zzz", "path" => tmp_dir},
      %{project_path: tmp_dir}
    )
    assert content =~ "No matches"
  end

  @tag :tmp_dir
  test "filters by include glob", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "code.ex"), "defmodule Foo do\nend")
    File.write!(Path.join(tmp_dir, "readme.md"), "defmodule in docs")

    {:ok, content} = Grep.execute(
      %{"pattern" => "defmodule", "path" => tmp_dir, "include" => "*.ex"},
      %{project_path: tmp_dir}
    )
    assert content =~ "code.ex"
  end

  @tag :tmp_dir
  test "rejects path outside project root", %{tmp_dir: tmp_dir} do
    {:error, _} = Grep.execute(
      %{"pattern" => "root", "path" => "/etc"},
      %{project_path: tmp_dir}
    )
  end

  test "declares read permission and search category" do
    assert Grep.permission_level() == :read
    assert Grep.category() == :search
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/grep_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/grep_test.exs
git commit -m "test(tool): add dedicated grep unit tests"
```

### Task 11: glob unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/glob_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/glob.ex`

- [ ] **Step 1: Write the test file**

```elixir
defmodule Synapsis.Tool.GlobTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Glob

  @tag :tmp_dir
  test "finds files matching pattern", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "app.ex"), "")
    File.write!(Path.join(tmp_dir, "app.exs"), "")
    File.write!(Path.join(tmp_dir, "readme.md"), "")

    {:ok, content} = Glob.execute(
      %{"pattern" => "*.ex", "path" => tmp_dir},
      %{project_path: tmp_dir}
    )
    assert content =~ "app.ex"
  end

  @tag :tmp_dir
  test "returns message for no matches", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "file.txt"), "")

    {:ok, content} = Glob.execute(
      %{"pattern" => "*.rs", "path" => tmp_dir},
      %{project_path: tmp_dir}
    )
    assert content =~ "No files matched"
  end

  @tag :tmp_dir
  test "searches nested directories with wildcard", %{tmp_dir: tmp_dir} do
    nested = Path.join([tmp_dir, "a", "b"])
    File.mkdir_p!(nested)
    File.write!(Path.join(nested, "deep.ex"), "")

    {:ok, content} = Glob.execute(
      %{"pattern" => "**/*.ex", "path" => tmp_dir},
      %{project_path: tmp_dir}
    )
    assert content =~ "deep.ex"
  end

  test "declares read permission and search category" do
    assert Glob.permission_level() == :read
    assert Glob.category() == :search
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/glob_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/glob_test.exs
git commit -m "test(tool): add dedicated glob unit tests"
```

### Task 12: bash unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/bash_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/bash.ex`

- [ ] **Step 1: Write the test file**

Note: Bash returns plain strings. Exit code 0 → `{:ok, "output"}`. Non-zero → `{:ok, "Exit code: N\noutput"}`. Timeout → `{:error, "Command timed out..."}`.

```elixir
defmodule Synapsis.Tool.BashTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.Bash

  @tag :tmp_dir
  test "executes simple command", %{tmp_dir: tmp_dir} do
    {:ok, output} = Bash.execute(%{"command" => "echo hello"}, %{project_path: tmp_dir})
    assert output =~ "hello"
  end

  @tag :tmp_dir
  test "captures non-zero exit code in output", %{tmp_dir: tmp_dir} do
    {:ok, output} = Bash.execute(%{"command" => "exit 42"}, %{project_path: tmp_dir})
    assert output =~ "Exit code: 42"
  end

  @tag :tmp_dir
  test "respects working directory", %{tmp_dir: tmp_dir} do
    {:ok, output} = Bash.execute(%{"command" => "pwd"}, %{project_path: tmp_dir})
    assert output =~ tmp_dir
  end

  @tag :tmp_dir
  test "handles timeout", %{tmp_dir: tmp_dir} do
    {:error, msg} = Bash.execute(
      %{"command" => "sleep 60", "timeout" => 500},
      %{project_path: tmp_dir}
    )
    assert msg =~ "timed out"
  end

  @tag :tmp_dir
  test "captures stderr merged with stdout", %{tmp_dir: tmp_dir} do
    {:ok, output} = Bash.execute(
      %{"command" => "echo out && echo err >&2"},
      %{project_path: tmp_dir}
    )
    assert output =~ "out"
    assert output =~ "err"
  end

  test "declares execute permission and execution category" do
    assert Bash.permission_level() == :execute
    assert Bash.category() == :execution
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/bash_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/bash_test.exs
git commit -m "test(tool): add dedicated bash unit tests"
```

### Task 13: enter_plan_mode and exit_plan_mode dedicated tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/enter_plan_mode_test.exs`
- Create: `apps/synapsis_core/test/synapsis/tool/exit_plan_mode_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/enter_plan_mode.ex`
- Reference: `apps/synapsis_core/lib/synapsis/tool/exit_plan_mode.ex`

- [ ] **Step 1: Write enter_plan_mode test**

```elixir
defmodule Synapsis.Tool.EnterPlanModeTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.EnterPlanMode

  test "declares none permission and session category" do
    assert EnterPlanMode.permission_level() == :none
    assert EnterPlanMode.category() == :session
    assert EnterPlanMode.name() == "enter_plan_mode"
    assert is_binary(EnterPlanMode.description())
  end

  test "returns correct parameters schema" do
    params = EnterPlanMode.parameters()
    assert is_map(params)
  end
end
```

- [ ] **Step 2: Write exit_plan_mode test**

```elixir
defmodule Synapsis.Tool.ExitPlanModeTest do
  use ExUnit.Case, async: true

  alias Synapsis.Tool.ExitPlanMode

  test "declares none permission and session category" do
    assert ExitPlanMode.permission_level() == :none
    assert ExitPlanMode.category() == :session
    assert ExitPlanMode.name() == "exit_plan_mode"
    assert is_binary(ExitPlanMode.description())
  end

  test "parameters schema includes plan" do
    params = ExitPlanMode.parameters()
    assert is_map(params)
  end
end
```

- [ ] **Step 3: Run tests**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/enter_plan_mode_test.exs apps/synapsis_core/test/synapsis/tool/exit_plan_mode_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/enter_plan_mode_test.exs apps/synapsis_core/test/synapsis/tool/exit_plan_mode_test.exs
git commit -m "test(tool): add dedicated plan mode unit tests"
```

### Task 14: session_summarize unit tests

**Files:**
- Create: `apps/synapsis_core/test/synapsis/tool/session_summarize_test.exs`
- Reference: `apps/synapsis_core/lib/synapsis/tool/session_summarize.ex`

- [ ] **Step 1: Write the test file**

```elixir
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

  test "permission level is none" do
    assert SessionSummarize.permission_level() == :none
  end
end
```

- [ ] **Step 2: Run test to verify**

Run: `devenv shell -- bash -c 'mix test apps/synapsis_core/test/synapsis/tool/session_summarize_test.exs --trace 2>&1 | tail -20'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add apps/synapsis_core/test/synapsis/tool/session_summarize_test.exs
git commit -m "test(tool): add dedicated session_summarize unit tests"
```

---

## Phase 3: Final Verification

### Task 15: Full test suite and format check

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `devenv shell -- bash -c 'mix test 2>&1 | tail -10'`
Expected: All tests pass (441+ existing tests plus ~50 new tests)

- [ ] **Step 2: Check formatting**

Run: `devenv shell -- bash -c 'mix format --check-formatted 2>&1 | tail -10'`
Expected: All files formatted

- [ ] **Step 3: Compile with warnings as errors**

Run: `devenv shell -- bash -c 'mix compile --warnings-as-errors 2>&1 | tail -10'`
Expected: No warnings

- [ ] **Step 4: Final commit if any formatting changes needed**

```bash
devenv shell -- bash -c 'mix format'
git add -A
git commit -m "chore: format tool system tests"
```

---

## Summary

| Phase | Tasks | Description |
|-------|-------|-------------|
| Phase 1 | Tasks 1-3 | Rewrite PRD to match actual codebase |
| Phase 2 | Tasks 4-14 | Add dedicated unit tests for 12 tools |
| Phase 3 | Task 15 | Full verification |

**Total: 15 tasks**

### Tools Getting New Dedicated Tests (Phase 2)

| Tool | Return Type | New Test File |
|------|-------------|---------------|
| file_read | `{:ok, "content string"}` | file_read_test.exs |
| file_write | `{:ok, "Successfully wrote..."}` | file_write_test.exs |
| file_edit | `{:ok, json_string}` | file_edit_test.exs |
| file_delete | `{:ok, "Successfully deleted..."}` | file_delete_test.exs |
| file_move | `{:ok, "Moved..."}` | file_move_test.exs |
| list_dir | `{:ok, "entries\n..."}` | list_dir_test.exs |
| grep | `{:ok, "match output"}` | grep_test.exs |
| glob | `{:ok, "file paths\n..."}` | glob_test.exs |
| bash | `{:ok, "output"}` | bash_test.exs |
| enter_plan_mode | metadata only | enter_plan_mode_test.exs |
| exit_plan_mode | metadata only | exit_plan_mode_test.exs |
| session_summarize | metadata only | session_summarize_test.exs |

### Descoped (not in this plan)

- **Task tool implementation** — `task.ex` is stubbed (`enabled? = false`) but cannot be wired to the agent runtime from `synapsis_core` because `synapsis_core` cannot depend on `synapsis_agent` per the Constitution's dependency graph. Implementing the task tool requires either: (a) a callback/behaviour injected at runtime, or (b) moving the tool to `synapsis_agent`. This is a separate architectural decision tracked separately.
- **PDF support in file_read** — not implemented, noted in PRD rewrite
- **Persistent bash port session** — not implemented, noted in PRD rewrite
