defmodule Synapsis.Memory.FileAdapter do
  @moduledoc """
  File-backed semantic memory adapter.

  Memories are stored as Markdown files with YAML frontmatter at
  `<memory_dir>/<scope>/<scope_id>/<id>.md`. An ETS inverted index
  (tokens → ids, tags → ids) is built at boot and updated on write.

  The GenServer serialises writes. ETS is `:public` so reads bypass it.
  """

  @behaviour Synapsis.Memory.Adapter

  use GenServer
  require Logger

  @table :synapsis_memory_file_index
  @default_memory_dir Path.join(System.user_home!() || "/tmp", ".config/synapsis/memory")

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ADR-006 C4: markdown files are the durable fallback store. Operations are
  # direct file I/O — they must not depend on the (best-effort) GenServer index,
  # so a down/restarting adapter process never surfaces `:noproc` to callers.
  @impl Synapsis.Memory.Adapter
  def store(attrs) do
    memory = build_memory(attrs)

    case write_file(memory) do
      :ok ->
        safe_index(memory)
        {:ok, memory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Synapsis.Memory.Adapter
  def search(query, filters \\ []) do
    tokens = query |> to_string() |> String.downcase() |> String.split(~r/\W+/, trim: true)
    want_tags = filters |> Keyword.get(:tags, []) |> Enum.map(&String.downcase/1)
    scope_filter = Keyword.get(filters, :scope)
    scope_id_filter = Keyword.get(filters, :scope_id)
    kind_filter = Keyword.get(filters, :kinds)

    list(Keyword.delete(filters, :limit))
    |> Enum.filter(fn m ->
      mem_tags = m.tags |> List.wrap() |> Enum.map(&String.downcase(to_string(&1)))
      text = [m.title, m.summary, Enum.join(mem_tags, " ")] |> Enum.join(" ") |> String.downcase()

      # Match if any query token appears (token index semantics) and, when a tag
      # filter is given, the memory carries one of the requested tags.
      (tokens == [] or Enum.any?(tokens, &String.contains?(text, &1))) and
        (want_tags == [] or Enum.any?(want_tags, &(&1 in mem_tags))) and
        (is_nil(scope_filter) or m.scope == to_string(scope_filter)) and
        (is_nil(scope_id_filter) or m.scope_id == scope_id_filter) and
        (is_nil(kind_filter) or m.kind in kind_filter)
    end)
    |> Enum.sort_by(& &1.importance, :desc)
    |> take_limit(filters)
  end

  @impl Synapsis.Memory.Adapter
  def get(id), do: read_by_id(id)

  @doc "Read an exact record within caller-selected semantic scope pairs."
  def get(id, filters), do: read_by_id(id, filters)

  @impl Synapsis.Memory.Adapter
  def list(filters \\ []) do
    scope = Keyword.get(filters, :scope)
    scope_id = Keyword.get(filters, :scope_id)
    dir = memory_dir()

    patterns =
      case Keyword.get(filters, :scopes) do
        scopes when is_list(scopes) ->
          Enum.map(scopes, fn {s, sid} ->
            Path.join([dir, to_string(s), directory_id(sid), "*.md"])
          end)

        nil ->
          case {scope, scope_id} do
            {nil, _} -> [Path.join(dir, "**/*.md")]
            {s, nil} -> [Path.join([dir, to_string(s), "**/*.md"])]
            {s, sid} -> [Path.join([dir, to_string(s), directory_id(sid), "*.md"])]
          end
      end

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      case read_file(path) do
        {:ok, m} -> [m]
        _ -> []
      end
    end)
    |> Enum.filter(&scope_match?(&1, filters))
    |> Enum.reject(& &1[:archived_at])
    |> take_limit(filters)
  end

  @impl Synapsis.Memory.Adapter
  def update(id, attrs), do: update(id, attrs, [])

  @doc "Update an exact record while retaining its expected scope."
  def update(id, attrs, filters) do
    case read_by_id(id, filters) do
      {:ok, existing} ->
        updated =
          existing
          |> Map.merge(atomize_keys(attrs))
          |> Map.put(:updated_at, DateTime.utc_now())

        case write_file(updated) do
          :ok ->
            safe_reindex(id, updated)
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end

      error ->
        error
    end
  end

  @impl Synapsis.Memory.Adapter
  def archive(id), do: archive(id, [])

  @doc "Archive only after the scoped record's write succeeds."
  def archive(id, filters) do
    case read_by_id(id, filters) do
      {:ok, memory} ->
        with :ok <- write_file(Map.put(memory, :archived_at, DateTime.utc_now())) do
          safe_remove_from_index(id)
          :ok
        end

      _ ->
        {:error, :not_found}
    end
  end

  @impl Synapsis.Memory.Adapter
  def touch_accessed(_ids), do: :ok

  # --- Supervisor/GenServer ---

  @impl true
  def init(_opts) do
    # Tolerate a pre-existing (orphaned) table and a malformed file on disk so the
    # singleton can always (re)start — a crash here would leave it permanently
    # down past its restart budget.
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:named_table, :bag, :public, read_concurrency: true])
    end

    try do
      build_index()
    rescue
      _ -> :ok
    end

    {:ok, %{}}
  end

  # GenServer call paths delegate to the direct (file-I/O) public API for
  # backward compatibility; the index ETS table is maintained best-effort.
  @impl true
  def handle_call({:store, attrs}, _from, state), do: {:reply, store(attrs), state}
  def handle_call({:update, id, attrs}, _from, state), do: {:reply, update(id, attrs), state}
  def handle_call({:archive, id}, _from, state), do: {:reply, archive(id), state}

  # --- Private ---

  defp build_memory(attrs) do
    %{
      id: Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id(),
      scope: to_str(Map.get(attrs, :scope, "shared")),
      scope_id: to_str(Map.get(attrs, :scope_id, "")),
      kind: to_str(Map.get(attrs, :kind, "fact")),
      title: to_str(Map.get(attrs, :title, "")),
      summary: to_str(Map.get(attrs, :summary, "")),
      detail: Map.get(attrs, :detail, %{}),
      tags: List.wrap(Map.get(attrs, :tags, [])),
      importance: Map.get(attrs, :importance, 0.5),
      confidence: Map.get(attrs, :confidence, 0.5),
      freshness: Map.get(attrs, :freshness, 1.0),
      source: to_str(Map.get(attrs, :source, "agent")),
      contributed_by: to_str(Map.get(attrs, :contributed_by, "")),
      evidence_event_ids: List.wrap(Map.get(attrs, :evidence_event_ids, [])),
      access_count: Map.get(attrs, :access_count, 0),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  # Best-effort inverted-index maintenance (search works without it via list/0).
  defp safe_index(memory), do: safe(fn -> index_memory(memory) end)

  defp safe_reindex(id, memory),
    do:
      safe(fn ->
        remove_from_index(id)
        index_memory(memory)
      end)

  defp safe_remove_from_index(id), do: safe(fn -> remove_from_index(id) end)

  defp safe(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  end

  defp memory_dir do
    System.get_env("SYNAPSIS_MEMORY_DIR") ||
      Application.get_env(:synapsis_core, :memory_dir, @default_memory_dir)
  end

  defp file_path(memory) do
    scope_id = directory_id(memory.scope_id)
    dir = Path.join([memory_dir(), memory.scope, scope_id])
    Path.join(dir, "#{memory.id}.md")
  end

  defp write_file(memory) do
    path = file_path(memory)

    frontmatter =
      %{
        "id" => memory.id,
        "scope" => memory.scope,
        "scope_id" => memory.scope_id,
        "kind" => memory.kind,
        "title" => memory.title,
        "tags" => memory.tags,
        "importance" => memory.importance,
        "confidence" => memory.confidence,
        "freshness" => memory.freshness,
        "source" => memory.source,
        "contributed_by" => Map.get(memory, :contributed_by),
        "evidence_event_ids" => Map.get(memory, :evidence_event_ids, []),
        "access_count" => Map.get(memory, :access_count, 0),
        "archived_at" => format_dt(Map.get(memory, :archived_at)),
        "inserted_at" => format_dt(memory.inserted_at),
        "updated_at" => format_dt(memory.updated_at)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.into(%{})

    yaml = frontmatter_to_yaml(frontmatter)
    content = "---\n#{yaml}---\n\n#{memory.summary}\n"

    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, content)
  end

  # The file name is the id, so resolve it by direct wildcard (no ETS/GenServer).
  defp read_by_id(id, filters \\ []) do
    pattern =
      case {Keyword.get(filters, :scope), Keyword.fetch(filters, :scope_id)} do
        {scope, {:ok, scope_id}} when not is_nil(scope) ->
          Path.join([memory_dir(), to_string(scope), directory_id(scope_id), "#{id}.md"])

        _ ->
          Path.join(memory_dir(), "**/#{id}.md")
      end

    case Path.wildcard(pattern) do
      [path] ->
        with {:ok, memory} <- read_file(path),
             true <- memory.id == id and scope_match?(memory, filters) do
          {:ok, memory}
        else
          false -> {:error, :ownership_mismatch}
          error -> error
        end

      [] ->
        {:error, :not_found}

      _ ->
        {:error, :ownership_mismatch}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp directory_id(""), do: "_global"
  defp directory_id(id), do: id

  defp scope_match?(memory, filters) do
    (is_nil(Keyword.get(filters, :scope)) or memory.scope == to_string(filters[:scope])) and
      (not Keyword.has_key?(filters, :scope_id) or memory.scope_id == filters[:scope_id]) and
      (is_nil(filters[:scopes]) or {memory.scope, memory.scope_id} in filters[:scopes])
  end

  defp take_limit(records, filters) do
    case Keyword.get(filters, :limit) do
      limit when is_integer(limit) and limit >= 0 -> Enum.take(records, limit)
      _ -> records
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_memory_file(path, content)
      {:error, _} -> {:error, :not_found}
    end
  end

  defp parse_memory_file(path, content) do
    case String.split(content, "---\n", parts: 3) do
      ["", fm_str, body] ->
        case YamlElixir.read_from_string(fm_str) do
          {:ok, fm} ->
            {:ok,
             %{
               id: stored_id(fm["id"], path, fm_str),
               scope: fm["scope"] || "shared",
               scope_id: fm["scope_id"] || "",
               kind: fm["kind"] || "fact",
               title: fm["title"] || "",
               summary: String.trim(body),
               detail: %{},
               tags: fm["tags"] || [],
               importance: fm["importance"] || 0.5,
               confidence: fm["confidence"] || 0.5,
               freshness: fm["freshness"] || 1.0,
               source: fm["source"] || "agent",
               contributed_by: fm["contributed_by"] || "",
               evidence_event_ids: fm["evidence_event_ids"] || [],
               access_count: fm["access_count"] || 0,
               archived_at: parse_dt(fm["archived_at"]),
               inserted_at: parse_dt(fm["inserted_at"]),
               updated_at: parse_dt(fm["updated_at"])
             }}

          _ ->
            {:error, :parse_error}
        end

      _ ->
        {:error, :parse_error}
    end
  end

  defp build_index do
    memory_dir()
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      case read_file(path) do
        {:ok, memory} -> index_memory_at(memory, path)
        _ -> :ok
      end
    end)
  end

  defp index_memory(memory) do
    path = file_path(memory)
    index_memory_at(memory, path)
  end

  defp index_memory_at(memory, path) do
    :ets.insert(@table, {{:id, memory.id}, path})

    Enum.each(memory.tags, fn tag ->
      :ets.insert(@table, {{:tag, String.downcase(tag)}, memory.id})
    end)

    memory.title
    |> String.downcase()
    |> String.split(~r/\W+/, trim: true)
    |> Enum.each(fn token ->
      :ets.insert(@table, {{:token, token}, memory.id})
    end)

    memory.summary
    |> String.downcase()
    |> String.split(~r/\W+/, trim: true)
    |> Enum.take(20)
    |> Enum.each(fn token ->
      :ets.insert(@table, {{:token, token}, memory.id})
    end)
  end

  defp remove_from_index(id) do
    :ets.match_delete(@table, {{:id, id}, :_})
    :ets.match_delete(@table, {{:tag, :_}, id})
    :ets.match_delete(@table, {{:token, :_}, id})
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Historical plain YAML IDs can decode as numbers, losing leading zeros.
  # Recover only when the exact old scalar agrees with the record's filename.
  defp stored_id(id, _path, _frontmatter) when is_binary(id), do: id

  defp stored_id(id, path, frontmatter) do
    filename_id = path |> Path.basename() |> Path.rootname(".md")

    if "id: #{filename_id}" in String.split(frontmatter, "\n"),
      do: filename_id,
      else: id || ""
  end

  defp to_str(v) when is_atom(v), do: Atom.to_string(v)
  defp to_str(v), do: to_string(v)

  defp format_dt(nil), do: nil
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_dt(nil), do: nil

  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(_), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Minimal YAML serialiser for flat string/number/list maps (frontmatter only).
  defp frontmatter_to_yaml(map) do
    Enum.map_join(map, "", fn {k, v} ->
      "#{k}: #{yaml_value(v)}\n"
    end)
  end

  defp yaml_value(nil), do: "null"
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(n) when is_number(n), do: to_string(n)

  defp yaml_value(s) when is_binary(s) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_ .\/-]*\z/, s) and String.trim(s) == s and
         String.downcase(s) not in ~w(true false null yes no on off) do
      s
    else
      Jason.encode!(s)
    end
  end

  defp yaml_value(list) when is_list(list) do
    items = Enum.map_join(list, ", ", &yaml_value/1)
    "[#{items}]"
  end

  defp yaml_value(v), do: inspect(v)
end
