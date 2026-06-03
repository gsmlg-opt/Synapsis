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

  @impl Synapsis.Memory.Adapter
  def store(attrs) do
    GenServer.call(__MODULE__, {:store, attrs})
  end

  @impl Synapsis.Memory.Adapter
  def search(query, filters \\ []) do
    candidate_ids = search_index(query, filters)
    scope_filter = Keyword.get(filters, :scope)
    scope_id_filter = Keyword.get(filters, :scope_id)
    kind_filter = Keyword.get(filters, :kinds)

    candidate_ids
    |> Enum.flat_map(fn id ->
      case read_by_id(id) do
        {:ok, m} -> [m]
        _ -> []
      end
    end)
    |> Enum.filter(fn m ->
      scope_ok = is_nil(scope_filter) or m.scope == to_string(scope_filter)
      scope_id_ok = is_nil(scope_id_filter) or m.scope_id == scope_id_filter
      kind_ok = is_nil(kind_filter) or m.kind in kind_filter
      scope_ok and scope_id_ok and kind_ok
    end)
    |> Enum.sort_by(& &1.importance, :desc)
  end

  @impl Synapsis.Memory.Adapter
  def get(id) do
    read_by_id(id)
  end

  @impl Synapsis.Memory.Adapter
  def list(filters \\ []) do
    scope = Keyword.get(filters, :scope)
    scope_id = Keyword.get(filters, :scope_id)
    dir = memory_dir()

    pattern =
      case {scope, scope_id} do
        {nil, _} -> Path.join(dir, "**/*.md")
        {s, nil} -> Path.join([dir, to_string(s), "**/*.md"])
        {s, sid} -> Path.join([dir, to_string(s), sid, "*.md"])
      end

    pattern
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read_file(path) do
        {:ok, m} -> [m]
        _ -> []
      end
    end)
    |> Enum.reject(& &1[:archived_at])
  end

  @impl Synapsis.Memory.Adapter
  def update(id, attrs) do
    GenServer.call(__MODULE__, {:update, id, attrs})
  end

  @impl Synapsis.Memory.Adapter
  def archive(id) do
    GenServer.call(__MODULE__, {:archive, id})
  end

  @impl Synapsis.Memory.Adapter
  def touch_accessed(_ids), do: :ok

  # --- Supervisor/GenServer ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :bag, :public, read_concurrency: true])
    build_index()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:store, attrs}, _from, state) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id()

    memory =
      %{
        id: id,
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

    case write_file(memory) do
      :ok ->
        index_memory(memory)
        {:reply, {:ok, memory}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    e -> {:reply, {:error, Exception.message(e)}, state}
  end

  def handle_call({:update, id, attrs}, _from, state) do
    case read_by_id(id) do
      {:ok, existing} ->
        updated =
          existing
          |> Map.merge(atomize_keys(attrs))
          |> Map.put(:updated_at, DateTime.utc_now())

        case write_file(updated) do
          :ok ->
            remove_from_index(id)
            index_memory(updated)
            {:reply, {:ok, updated}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      error ->
        {:reply, error, state}
    end
  rescue
    e -> {:reply, {:error, Exception.message(e)}, state}
  end

  def handle_call({:archive, id}, _from, state) do
    case read_by_id(id) do
      {:ok, memory} ->
        archived = Map.put(memory, :archived_at, DateTime.utc_now())
        write_file(archived)
        remove_from_index(id)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  rescue
    e -> {:reply, {:error, Exception.message(e)}, state}
  end

  # --- Private ---

  defp memory_dir do
    System.get_env("SYNAPSIS_MEMORY_DIR") ||
      Application.get_env(:synapsis_core, :memory_dir, @default_memory_dir)
  end

  defp file_path(memory) do
    scope_id = if memory.scope_id == "", do: "_global", else: memory.scope_id
    dir = Path.join([memory_dir(), memory.scope, scope_id])
    Path.join(dir, "#{memory.id}.md")
  end

  defp write_file(memory) do
    path = file_path(memory)
    File.mkdir_p!(Path.dirname(path))

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

    File.write(path, content)
  end

  defp read_by_id(id) do
    case :ets.lookup(@table, {:id, id}) do
      [{_, path}] -> read_file(path)
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> parse_memory_file(path, content)
      {:error, _} -> {:error, :not_found}
    end
  end

  defp parse_memory_file(_path, content) do
    case String.split(content, "---\n", parts: 3) do
      ["", fm_str, body] ->
        case YamlElixir.read_from_string(fm_str) do
          {:ok, fm} ->
            {:ok,
             %{
               id: fm["id"] || "",
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

  defp search_index(query, filters) do
    tags = Keyword.get(filters, :tags, [])

    tag_ids =
      Enum.flat_map(tags, fn tag ->
        :ets.lookup(@table, {:tag, String.downcase(tag)})
        |> Enum.map(fn {_, id} -> id end)
      end)
      |> MapSet.new()

    token_ids =
      query
      |> String.downcase()
      |> String.split(~r/\W+/, trim: true)
      |> Enum.flat_map(fn token ->
        :ets.lookup(@table, {:token, token})
        |> Enum.map(fn {_, id} -> id end)
      end)
      |> MapSet.new()

    cond do
      tags != [] and query == "" -> MapSet.to_list(tag_ids)
      tags != [] -> MapSet.to_list(MapSet.intersection(tag_ids, token_ids))
      true -> MapSet.to_list(token_ids)
    end
  rescue
    _ -> []
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
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
    if String.contains?(s, ["\n", "\"", "'", ":", "#"]) do
      encoded = String.replace(s, "\"", "\\\"")
      "\"#{encoded}\""
    else
      s
    end
  end

  defp yaml_value(list) when is_list(list) do
    items = Enum.map_join(list, ", ", &yaml_value/1)
    "[#{items}]"
  end

  defp yaml_value(v), do: inspect(v)
end
