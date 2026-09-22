defmodule Synapsis.SkillCatalog do
  @moduledoc "Source-aware, immutable Skill catalog snapshots and prompt rendering."

  alias Backplane.SkillProtocol.{Parser, Validator}

  @description_limit 1_024
  @explicit_token_cap 10_000
  @fallback_character_budget 8_000

  defmodule Entry do
    @moduledoc "A source-qualified Skill catalog entry."
    @enforce_keys [:authority, :source_id, :skill_id, :name, :locator]
    defstruct [
      :authority,
      :source_id,
      :skill_id,
      :revision,
      :artifact_digest,
      :name,
      :description,
      :locator,
      :scope,
      :loader,
      :body,
      enabled: true,
      prompt_visible: true
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Report do
    @moduledoc false
    defstruct [
      :budget,
      total_count: 0,
      included_count: 0,
      omitted_count: 0,
      truncated_description_chars: 0,
      truncated_description_count: 0
    ]
  end

  defmodule Result do
    @moduledoc false
    defstruct [:text, :report]
  end

  @doc "Build a frozen, source-aware snapshot from assigned persisted Skills."
  @spec snapshot([map()]) :: [Entry.t()]
  def snapshot(skills) when is_list(skills) do
    skills
    |> Enum.map(&entry_from_skill/1)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc "A Skill identity is source-aware and never name-only."
  def identity(%Entry{} = entry), do: {entry.authority, entry.source_id, entry.skill_id}

  @doc "Render the model-visible metadata catalog under a bounded budget."
  @spec render([Entry.t()], keyword()) :: Result.t()
  def render(entries, opts \\ []) when is_list(entries) do
    candidates =
      entries
      |> Enum.filter(&(&1.enabled and &1.prompt_visible))
      |> Enum.sort_by(&sort_key/1)
      |> Enum.map(&bounded_entry/1)

    budget = budget(opts)
    {selected, initially_truncated, omitted} = allocate(candidates, budget)
    report = report(candidates, selected, initially_truncated, omitted, budget)

    %Result{text: render_text(selected, report), report: report}
  end

  defp entry_from_skill(skill) do
    config = value(skill, :config_overrides, %{}) || %{}
    body = value(skill, :system_prompt_fragment)
    {document, canonical?} = parse_document(body)
    authority = authority(config)
    source_id = source_id(authority, skill, config)
    skill_id = skill_id(authority, skill, config)
    source_metadata = map_value(config, "source_metadata") || %{}
    revision = map_value(source_metadata, "revision") || map_value(config, "external_revision")
    digest = map_value(source_metadata, "artifact_digest") || map_value(config, "artifact_digest")
    name = (document && document.name) || value(skill, :name) || skill_id
    description = (document && document.description) || value(skill, :description) || ""

    %Entry{
      authority: authority,
      source_id: source_id,
      skill_id: skill_id,
      revision: revision,
      artifact_digest: digest,
      name: name,
      description: one_line(description),
      locator: locator(authority, source_id, skill_id, revision, digest),
      enabled: value(skill, :enabled, true) == true,
      prompt_visible: prompt_visible?(config, document),
      scope: scope(value(skill, :scope)),
      loader: loader(authority, skill, config, canonical?),
      body: body
    }
  end

  defp parse_document(body) when is_binary(body) do
    with {:ok, document} <- Parser.parse(body),
         {:ok, document} <- Validator.validate(document, profile: :legacy) do
      {document, true}
    else
      _ -> {nil, false}
    end
  end

  defp parse_document(_), do: {nil, false}

  defp authority(config) do
    case map_value(config, "source") do
      "backplane" -> :backplane
      "local" -> :local
      _ -> :synapsis
    end
  end

  defp source_id(:backplane, _skill, config),
    do: to_string(map_value(config, "backplane_source_id") || "")

  defp source_id(:local, _skill, config), do: to_string(map_value(config, "source_id") || "local")
  defp source_id(:synapsis, _skill, _config), do: "synapsis"

  defp skill_id(:backplane, skill, config),
    do: to_string(map_value(config, "external_id") || value(skill, :id))

  defp skill_id(:local, skill, config),
    do:
      to_string(
        map_value(config, "skill_id") || map_value(config, "external_id") || value(skill, :name)
      )

  defp skill_id(_authority, skill, _config),
    do: to_string(value(skill, :id) || value(skill, :name))

  defp prompt_visible?(config, document) do
    configured = map_value(config, "prompt_visible")
    implicit = map_value(config, "allow_implicit_invocation")
    source_metadata = map_value(config, "source_metadata") || %{}
    source_implicit = map_value(source_metadata, "allow_implicit_invocation")
    disabled_by_document = document && document.metadata["disable-model-invocation"] == true

    configured != false and implicit != false and source_implicit != false and
      disabled_by_document != true
  end

  defp loader(:backplane, _skill, config, _canonical?) do
    %{type: :backplane, connection_id: map_value(config, "backplane_source_id")}
  end

  defp loader(:local, _skill, config, _canonical?) do
    %{type: :local, root: map_value(config, "root"), path: map_value(config, "path")}
  end

  defp loader(:synapsis, _skill, _config, canonical?),
    do: %{type: :inline, canonical?: canonical?}

  defp locator(:synapsis, _source, skill_id, _revision, _digest),
    do: "synapsis://skills/#{URI.encode(skill_id, &URI.char_unreserved?/1)}"

  defp locator(:local, source_id, skill_id, _revision, _digest),
    do: "local://#{encode(source_id)}/#{encode(skill_id)}"

  defp locator(:backplane, source_id, skill_id, revision, digest) do
    query =
      [revision: revision, digest: digest]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> URI.encode_query()

    base = "backplane://#{encode(source_id)}/#{encode(skill_id)}"
    if query == "", do: base, else: base <> "?" <> query
  end

  defp encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp scope("system"), do: :system
  defp scope("admin"), do: :admin
  defp scope("repo"), do: :repo
  defp scope("user"), do: :user
  defp scope(_), do: :agent

  defp bounded_entry(entry) do
    description = entry.description || ""
    graphemes = String.graphemes(description)

    if length(graphemes) > @description_limit do
      kept = Enum.take(graphemes, @description_limit - 3) |> Enum.join()
      {entry, kept <> "...", length(graphemes) - (@description_limit - 3)}
    else
      {entry, description, 0}
    end
  end

  defp allocate(entries, budget) do
    capacity = budget.value

    full =
      Enum.map(entries, fn {entry, desc, initial} ->
        {entry, desc, initial, full_line(entry, desc)}
      end)

    minimum =
      Enum.map(full, fn {entry, _desc, initial, _line} ->
        {entry, "", initial, min_line(entry)}
      end)

    cond do
      cost(full, budget) <= capacity ->
        {full, true, 0}

      cost(minimum, budget) <= capacity ->
        {allocate_descriptions(minimum, entries, capacity, budget), false, 0}

      true ->
        allocate_minimum(minimum, capacity, budget)
    end
  end

  defp allocate_descriptions(minimum, original, capacity, budget) do
    descriptions = Enum.map(original, fn {_entry, desc, _initial} -> String.graphemes(desc) end)
    grow_descriptions(minimum, descriptions, capacity, budget, 0)
  end

  defp grow_descriptions(lines, descriptions, capacity, budget, index) do
    count = length(lines)

    if count == 0 or Enum.all?(descriptions, &(&1 == [])) do
      lines
    else
      position = rem(index, count)
      remaining = Enum.at(descriptions, position)

      case remaining do
        [next | rest] ->
          {entry, desc, initial, _line} = Enum.at(lines, position)
          candidate = {entry, desc <> next, initial, full_line(entry, desc <> next)}

          if cost(List.replace_at(lines, position, candidate), budget) <= capacity do
            grow_descriptions(
              List.replace_at(lines, position, candidate),
              List.replace_at(descriptions, position, rest),
              capacity,
              budget,
              index + 1
            )
          else
            grow_descriptions(
              lines,
              List.replace_at(descriptions, position, []),
              capacity,
              budget,
              index + 1
            )
          end

        [] ->
          grow_descriptions(lines, descriptions, capacity, budget, index + 1)
      end
    end
  end

  defp allocate_minimum(lines, capacity, budget) do
    {selected, _used, omitted} =
      Enum.reduce(lines, {[], 0, 0}, fn line, {selected, used, omitted} ->
        line_cost = line_cost(elem(line, 3), budget)

        if used + line_cost <= capacity do
          {selected ++ [line], used + line_cost, omitted}
        else
          {selected, used, omitted + 1}
        end
      end)

    {selected, false, omitted}
  end

  defp report(candidates, selected, full?, omitted, budget) do
    truncated =
      Enum.map(selected, fn {entry, desc, initial, _line} ->
        original =
          Enum.find_value(candidates, fn {candidate, bounded, _} ->
            if identity(candidate) == identity(entry), do: bounded
          end) || ""

        initial + max(String.length(original) - String.length(desc), 0)
      end)

    %Report{
      budget: budget,
      total_count: length(candidates),
      included_count: length(selected),
      omitted_count:
        if(full? or omitted == 0, do: length(candidates) - length(selected), else: omitted),
      truncated_description_chars: Enum.sum(truncated),
      truncated_description_count: Enum.count(truncated, &(&1 > 0))
    }
  end

  defp render_text(selected, report) do
    entries = Enum.map_join(selected, "\n", &elem(&1, 3))

    omission =
      if report.omitted_count > 0,
        do:
          "\n\n#{report.omitted_count} skill(s) omitted because the catalog budget was exceeded.",
        else: ""

    """
    ## Skills
    The following skills are available. Select a skill when its description matches the task, then use the skill tool with its locator to load the complete SKILL.md. Read referenced resources only as needed.

    ### Available skills
    #{entries}#{omission}
    """
    |> String.trim()
  end

  defp full_line(entry, ""), do: min_line(entry)
  defp full_line(entry, desc), do: "- #{entry.name}: #{desc} (locator: #{entry.locator})"
  defp min_line(entry), do: "- #{entry.name} (locator: #{entry.locator})"

  defp cost(lines, budget),
    do: Enum.reduce(lines, 0, &(line_cost(elem(&1, 3), budget) + &2))

  defp line_cost(line, %{unit: :tokens}), do: div(byte_size(line) + 3, 4)
  defp line_cost(line, %{unit: :characters}), do: String.length(line)

  defp budget(opts) do
    case Keyword.get(opts, :max_context_tokens) do
      value when is_integer(value) and value > 0 ->
        %{unit: :tokens, value: min(value, @explicit_token_cap)}

      _ ->
        case Keyword.get(opts, :model_context_window) do
          value when is_integer(value) and value > 0 ->
            %{unit: :tokens, value: max(1, div(value * 2, 100))}

          _ ->
            %{unit: :characters, value: @fallback_character_budget}
        end
    end
  end

  defp sort_key(entry) do
    {authority_order(entry.authority), scope_order(entry.scope),
     String.downcase(entry.name || ""), entry.source_id, entry.skill_id, entry.locator}
  end

  defp authority_order(:synapsis), do: 0
  defp authority_order(:local), do: 1
  defp authority_order(:backplane), do: 2
  defp authority_order(_), do: 3
  defp scope_order(:system), do: 0
  defp scope_order(:admin), do: 1
  defp scope_order(:repo), do: 2
  defp scope_order(:user), do: 3
  defp scope_order(:agent), do: 4
  defp scope_order(_), do: 5

  defp one_line(value) when is_binary(value), do: value |> String.split() |> Enum.join(" ")
  defp one_line(_), do: ""

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp map_value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, atom_key(key)))

  defp atom_key("external_revision"), do: :external_revision
  defp atom_key("revision"), do: :revision
  defp atom_key("source_metadata"), do: :source_metadata
  defp atom_key("artifact_digest"), do: :artifact_digest
  defp atom_key("source"), do: :source
  defp atom_key("backplane_source_id"), do: :backplane_source_id
  defp atom_key("source_id"), do: :source_id
  defp atom_key("skill_id"), do: :skill_id
  defp atom_key("external_id"), do: :external_id
  defp atom_key("prompt_visible"), do: :prompt_visible
  defp atom_key("allow_implicit_invocation"), do: :allow_implicit_invocation
  defp atom_key("root"), do: :root
  defp atom_key("path"), do: :path
end
