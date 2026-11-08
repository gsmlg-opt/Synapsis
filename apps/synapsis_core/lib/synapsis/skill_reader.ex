defmodule Synapsis.SkillReader do
  @moduledoc """
  Bounded, inert reads of assigned and private learned skills for a persisted agent.

  Snapshots bind assignment UUIDs separately from source-qualified catalog IDs.
  Schema-2 discovery pairs assigned bindings with revision-qualified workshop
  bindings. Search can use a trusted prepared body view. Reads recheck assigned
  source configuration and validate only the selected learned tree/document.
  Historical nil digests remain nil; a document hash is evidence of the read,
  not an immutable snapshot.

  Assigned documents use the protocol parser's 2 MiB document ceiling; learned
  acquisition retains the workshop owner's 1 MiB limit. The installed source's
  256 KiB non-prompt read rule uses host `prompt_visible` eligibility here.
  Actual prompt rendering can omit otherwise eligible entries, so this host
  adaptation is not a claim of identical source `promptListed` membership.

  Local reads reject links and check ancestry/file identity around bounded IO;
  they do not provide atomic containment against hostile concurrent renames.
  Remote reads reuse the host loader's exact revision/optional artifact digest
  checks and per-request credentials. A deadline and owner-loss predicate allow
  cooperative unwinding. A forced kill cannot guarantee loader `after` cleanup.
  """

  alias Backplane.SkillProtocol.{Eligibility, Parser, Source.Local, Validator}
  alias Synapsis.{AgentConfigs, SkillCatalog, SkillDiscovery, SkillSearch, Skills, SkillWorkshop}
  alias Synapsis.Config.Store
  alias Synapsis.SkillCatalog.Entry

  @max_document 2 * 1_024 * 1_024
  @non_prompt_instruction_bytes 256 * 1_024
  @max_candidates 128
  @timeout 1_000

  def snapshot(agent_id) do
    bounded([], fn _ -> capture(agent_id) end)
  end

  def valid_snapshot?(%{schema: 2} = snapshot), do: SkillDiscovery.valid_snapshot?(snapshot)

  def valid_snapshot?(%{agent_id: agent_id, assignment_ids: ids, bindings: bindings} = snapshot) do
    Map.keys(snapshot) |> Enum.sort() == [:agent_id, :assignment_ids, :bindings] and
      valid_id?(agent_id) and is_list(ids) and length(ids) <= @max_candidates and
      Enum.all?(ids, &valid_id?/1) and ids == Enum.uniq(ids) and
      is_list(bindings) and length(bindings) <= @max_candidates and
      Enum.all?(bindings, fn
        %{record_id: id, entry: %Entry{}, fingerprint: fingerprint} = binding ->
          Enum.sort(Map.keys(binding)) == [:entry, :fingerprint, :record_id] and
            id in ids and is_binary(fingerprint) and byte_size(fingerprint) == 64

        _ ->
          false
      end)
  end

  def valid_snapshot?(_), do: false

  @doc "Persisted Agent identity from a captured legacy or combined snapshot."
  def agent_id(%{schema: 2, assigned: %{agent_id: id}}), do: id
  def agent_id(%{agent_id: id}), do: id
  def agent_id(_), do: nil

  @doc "Exact assigned-first bindings from a valid legacy or combined snapshot."
  def bindings(%{schema: 2} = snapshot), do: SkillDiscovery.bindings(snapshot)

  def bindings(snapshot) do
    if valid_snapshot?(snapshot), do: snapshot.bindings, else: {:error, :invalid_snapshot}
  end

  @doc "Stable typed identity, separate from the binding's captured content revision."
  defdelegate binding_key(binding), to: SkillDiscovery

  def search(snapshot, query, opts \\ []) do
    with true <- valid_snapshot?(snapshot),
         :ok <- options(opts, [:limit, :deadline, :body_view]),
         true <- is_binary(query) and String.valid?(query) and byte_size(query) in 1..2048,
         limit = Keyword.get(opts, :limit, 5),
         true <- is_integer(limit) and limit in 1..20,
         :ok <- body_view(snapshot, Keyword.get(opts, :body_view)) do
      bounded(opts, fn _ ->
        with :ok <- current(snapshot) do
          matches =
            bindings(snapshot)
            |> Enum.filter(&eligible?(&1.entry))
            |> Enum.map(fn %{entry: entry} = binding ->
              %{name: entry.name, description: entry.description, binding: binding}
            end)
            |> rank(query, Keyword.get(opts, :body_view))
            |> Enum.map(& &1.binding)

          result = %{
            results: Enum.take(matches, limit) |> Enum.map(&public/1),
            truncated: length(matches) > limit
          }

          output(search_coverage(result, Keyword.get(opts, :body_view)))
        end
      end)
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp body_view(_snapshot, nil), do: :ok

  defp body_view(snapshot, %{snapshot: same, index: index, coverage: coverage}) do
    count = Enum.count(bindings(snapshot), &eligible?(&1.entry))

    if same === snapshot and is_map(index) and
         match?(
           %{bodyIndexed: indexed, metadataOnly: metadata, truncatedBodies: truncated}
           when is_integer(indexed) and indexed >= 0 and is_integer(metadata) and metadata >= 0 and
                  is_integer(truncated) and truncated >= 0 and truncated <= indexed,
           coverage
         ) and coverage.bodyIndexed + coverage.metadataOnly == count,
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp body_view(_, _), do: {:error, :invalid_input}

  defp rank(entries, query, nil), do: SkillSearch.rank(entries, query)
  defp rank(entries, query, %{index: index}), do: SkillSearch.rank(entries, query, index)

  defp search_coverage(result, %{coverage: %{metadataOnly: 0, truncatedBodies: 0}}), do: result
  defp search_coverage(result, %{coverage: coverage}), do: Map.put(result, :coverage, coverage)
  defp search_coverage(result, nil), do: result

  @doc "Read a search prefix after the selected source's required content verification."
  def search_body(snapshot, binding, max_bytes, opts \\ []) do
    with true <- valid_snapshot?(snapshot),
         true <- binding in bindings(snapshot) and eligible?(binding.entry),
         true <- is_integer(max_bytes) and max_bytes in 1..16_384,
         :ok <- options(opts, [:deadline, :recheck]),
         recheck = Keyword.get(opts, :recheck, fn -> :ok end),
         true <- is_function(recheck, 0) do
      bounded(
        opts,
        fn context ->
          context = source_context(snapshot, context)

          with :ok <- body_current(snapshot, context, recheck) do
            result = source_prefix(binding.entry, max_bytes, context)

            with :ok <- body_current(snapshot, context, recheck) do
              case result do
                {:error, reason} -> {:metadata_only, reason}
                other -> other
              end
            end
          end
        end,
        true
      )
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp body_current(snapshot, context, recheck) do
    with :ok <- body_alive(context),
         :ok <- recheck.(),
         :ok <- current(snapshot),
         :ok <- body_alive(context),
         do: :ok
  end

  defp body_alive(context),
    do: if(context.cancelled?.(), do: {:error, :timeout}, else: :ok)

  defp source_prefix(%Entry{loader: %{type: :inline}, body: body} = entry, max_bytes, _context)
       when is_binary(body) do
    with {:ok, _} <- native_validate(entry, body, :automatic) do
      prefix(body, max_bytes)
    end
  end

  defp source_prefix(%Entry{loader: %{type: :local, root: root}} = entry, max_bytes, context) do
    with :ok <- local_path(root, entry.skill_id),
         {:ok, raw, truncated, fallback?} <-
           local_prefix(root, entry.skill_id, max_bytes, context),
         :ok <- prefix_name(raw, entry.skill_id, fallback?),
         :ok <- prefix_integrity(entry, raw, truncated) do
      {:ok, %{content: utf8_replacement(raw), truncated: truncated}}
    end
  end

  defp source_prefix(%Entry{loader: %{type: :workshop}} = entry, max_bytes, context) do
    with {:ok, content} <- native_load(entry, context),
         :ok <- content_size(content),
         do: prefix(content, max_bytes)
  end

  defp source_prefix(_, _, _), do: {:metadata_only, :opaque_source}

  defp prefix(body, max_bytes) do
    size = min(byte_size(body), max_bytes)

    {:ok,
     %{content: utf8_replacement(binary_part(body, 0, size)), truncated: byte_size(body) > size}}
  end

  # Node's Buffer.toString replaces each maximal valid subpart once, then
  # reprocesses the rejecting byte. Never claim this is a whole read.
  defp utf8_replacement(bytes) do
    case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
      text when is_binary(text) ->
        text

      {:incomplete, valid, _tail} ->
        valid <> "\uFFFD"

      {:error, valid, invalid} ->
        rest =
          case invalid do
            <<lead, second, third, rest::binary>>
            when third in 0x80..0xBF and
                   ((lead == 0xF0 and second in 0x90..0xBF) or
                      (lead in 0xF1..0xF3 and second in 0x80..0xBF) or
                      (lead == 0xF4 and second in 0x80..0x8F)) ->
              rest

            <<lead, second, rest::binary>>
            when (lead == 0xE0 and second in 0xA0..0xBF) or
                   (lead in 0xE1..0xEC and second in 0x80..0xBF) or
                   (lead == 0xED and second in 0x80..0x9F) or
                   (lead in 0xEE..0xEF and second in 0x80..0xBF) or
                   (lead == 0xF0 and second in 0x90..0xBF) or
                   (lead in 0xF1..0xF3 and second in 0x80..0xBF) or
                   (lead == 0xF4 and second in 0x80..0x8F) ->
              rest

            <<_invalid, rest::binary>> ->
              rest
          end

        valid <> "\uFFFD" <> utf8_replacement(rest)
    end
  end

  defp local_path(root, skill_id) do
    if is_binary(root) and Path.type(root) == :absolute and Path.expand(root) == root and
         is_binary(skill_id) and Path.type(skill_id) == :relative and
         not String.contains?(skill_id, ["\\", "\0"]) and
         Enum.all?(String.split(skill_id, "/"), &(&1 not in ["", ".", ".."])),
       do: :ok,
       else: {:error, :unsafe_path}
  end

  defp local_prefix(root, skill_id, max_bytes, context) do
    case prefix_file(Path.join([root, skill_id, "SKILL.md"]), max_bytes, context) do
      {:error, :not_found} ->
        with {:ok, raw, truncated} <-
               prefix_file(Path.join(root, "SKILL.md"), max_bytes, context),
             do: {:ok, raw, truncated, true}

      {:ok, raw, truncated} ->
        {:ok, raw, truncated, false}

      other ->
        other
    end
  end

  defp prefix_name(_raw, _skill_id, false), do: :ok

  defp prefix_name(raw, skill_id, true) do
    with {:ok, document} <- Parser.parse(utf8_replacement(raw)),
         true <- document.name == skill_id do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp prefix_integrity(%Entry{artifact_digest: digest}, _raw, true) when not is_nil(digest),
    do: {:error, :unverified_whole_digest}

  defp prefix_integrity(_entry, _raw, true), do: :ok

  defp prefix_integrity(entry, raw, false) do
    with :ok <- content_size(raw),
         {:ok, _} <- native_validate(entry, raw, :automatic),
         :ok <- local_digest(entry, raw),
         do: :ok
  end

  defp prefix_file(path, max_bytes, context) do
    with :ok <- body_alive(context),
         {:ok, ancestors} <- ancestry(Path.dirname(path)),
         {:ok, stat} <- prefix_leaf(path),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with :ok <- body_alive(context),
             {:ok, info} <- :file.read_file_info(io, time: :posix),
             true <- same_file?(stat, File.Stat.from_record(info)),
             {:ok, bytes} <- prefix_bytes(io, max_bytes),
             :ok <- body_alive(context),
             {:ok, after_info} <- :file.read_file_info(io, time: :posix),
             true <- same_file?(stat, File.Stat.from_record(after_info)),
             {:ok, ^ancestors} <- ancestry(Path.dirname(path)),
             {:ok, final} <- prefix_leaf(path),
             true <- same_file?(stat, final) do
          {:ok, binary_part(bytes, 0, min(byte_size(bytes), max_bytes)),
           byte_size(bytes) > max_bytes}
        else
          false -> {:error, :unsafe_path}
          {:ok, _} -> {:error, :unsafe_path}
          error -> error
        end
      after
        File.close(io)
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  defp prefix_leaf(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular, links: 1} = stat} -> {:ok, stat}
      {:ok, _} -> {:error, :unsafe_path}
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  defp prefix_bytes(io, max_bytes) do
    case :file.read(io, max_bytes + 1) do
      :eof -> {:ok, ""}
      result -> result
    end
  end

  def select(snapshot, locator) do
    with true <- valid_snapshot?(snapshot),
         true <- is_binary(locator) and String.valid?(locator) and byte_size(locator) in 1..4096 do
      case Enum.filter(bindings(snapshot), &(&1.entry.locator == locator and eligible?(&1.entry))) do
        [binding] -> {:ok, binding}
        _ -> {:error, :not_found}
      end
    else
      _ -> {:error, :invalid_input}
    end
  end

  @doc "Select a skill explicitly, retaining locator and unique-name compatibility."
  def select_explicit(snapshot, input) do
    with true <- valid_snapshot?(snapshot),
         :ok <- explicit_input(input) do
      candidates = Enum.filter(bindings(snapshot), &explicit_eligible?(&1.entry))

      matches =
        case input do
          %{"locator" => locator} when locator != "" ->
            case Enum.find(candidates, &(&1.entry.locator == locator)) do
              nil -> []
              binding -> [binding]
            end

          %{"name" => name} when name != "" ->
            Enum.filter(candidates, &(&1.entry.name == name))

          _ ->
            []
        end

      case matches do
        [binding] -> {:ok, binding}
        [] -> {:error, :not_found}
        _ -> {:error, :ambiguous}
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  def read(snapshot, locator, opts \\ []) do
    with {:ok, binding} <- select(snapshot, locator) do
      read_selected(snapshot, binding, :automatic, opts)
    end
  end

  @doc "Read an enabled skill explicitly without granting automatic invocation."
  def read_explicit(snapshot, input, opts \\ []) do
    with {:ok, binding} <- select_explicit(snapshot, input) do
      read_selected(snapshot, binding, :explicit, opts)
    end
  end

  defp read_selected(snapshot, binding, trigger, opts) do
    with :ok <- options(opts, [:deadline]) do
      bounded(opts, fn context ->
        context = source_context(snapshot, context)

        with :ok <- current(snapshot),
             {:ok, content} <- native_load(binding.entry, context),
             :ok <- instruction_size(binding.entry, content),
             {:ok, content} <- native_validate(binding.entry, content, trigger),
             :ok <- local_digest(binding.entry, content),
             :ok <- current(snapshot) do
          output(
            Map.merge(public(binding), %{
              content: content,
              document_digest: digest(content),
              citation: binding.entry.locator
            })
          )
        end
      end)
    end
  end

  defp source_context(%{schema: 2, learned: %{scope: scope}} = snapshot, context) do
    Map.merge(context, %{agent_id: agent_id(snapshot), workshop_scope: scope})
  end

  defp source_context(snapshot, context), do: Map.put(context, :agent_id, agent_id(snapshot))

  defp capture(agent_id) do
    with true <- valid_id?(agent_id),
         %{enabled: true, config: config} <- AgentConfigs.get(agent_id),
         ids when is_list(ids) <- Map.get(config || %{}, "skill_ids", []),
         true <- Enum.all?(ids, &valid_id?/1) and ids == Enum.uniq(ids),
         true <- length(ids) <= @max_candidates do
      bindings =
        Enum.flat_map(ids, fn id ->
          case Skills.get(id) do
            nil ->
              []

            skill ->
              if Skills.runtime_available?(skill) do
                [entry] = SkillCatalog.snapshot([skill])
                [%{record_id: id, entry: entry, fingerprint: fingerprint(skill, entry)}]
              else
                []
              end
          end
        end)

      {:ok, %{agent_id: agent_id, assignment_ids: ids, bindings: bindings}}
    else
      false ->
        case AgentConfigs.get(agent_id) do
          %{config: %{"skill_ids" => ids}} when is_list(ids) and length(ids) > @max_candidates ->
            {:error, :candidate_limit}

          _ ->
            {:error, :unavailable}
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp current(%{schema: 2} = snapshot), do: SkillDiscovery.assigned_current(snapshot)

  defp current(snapshot) do
    case capture(agent_id(snapshot)) do
      {:ok, fresh} when fresh === snapshot -> :ok
      _ -> {:error, :stale_snapshot}
    end
  end

  defp fingerprint(skill, %Entry{authority: :backplane, source_id: source_id}) do
    case Store.get(:backplane, source_id) do
      {:ok, source} ->
        provider =
          case value(source, :provider_id) do
            nil -> nil
            id -> provider_state(Store.get(:provider, id))
          end

        hash({skill, source_state(source), provider})

      _ ->
        hash({skill, :unavailable})
    end
  end

  defp fingerprint(skill, _entry), do: hash(skill)

  # Connection/ProviderSource route by these identities and endpoint fields.
  # Credentials are deliberately resolved live by the loader: rotating their
  # contents or updating a mutation timestamp must not invalidate this binding.
  defp provider_state({:ok, provider}),
    do: projection(provider, [:id, :type, :preset, :base_url, :credential_id, :enabled])

  defp provider_state(_), do: :unavailable

  defp source_state(source) do
    source
    |> projection([:id, :provider_id, :endpoint, :base_url, :enabled, :source_revision])
    |> Map.put(
      :metadata,
      source
      |> source_metadata()
      |> projection([:runtime_blocked_surfaces, :provider_migration_error])
    )
  end

  defp source_metadata(map) do
    case value(map, :metadata) do
      embedded when is_map(embedded) ->
        embedded

      _ ->
        case Jason.decode(value(map, :metadata_json) || "{}") do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> %{}
        end
    end
  end

  defp projection(map, fields), do: Map.new(fields, &{&1, value(map, &1)})
  defp value(map, field), do: Map.get(map, Atom.to_string(field), Map.get(map, field))

  defp hash(term),
    do:
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic])),
        case: :lower
      )

  defp digest(content),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp eligible?(entry),
    do: explicit_eligible?(entry) and entry.prompt_visible

  defp explicit_eligible?(entry),
    do:
      entry.enabled and
        (entry.authority != :backplane or (is_binary(entry.revision) and entry.revision != ""))

  defp explicit_input(input) when is_map(input) do
    valid_fields =
      Enum.all?(input, fn {key, value} ->
        key in ["locator", "name"] and is_binary(value) and String.valid?(value) and
          byte_size(value) <= 4096
      end)

    if valid_fields and Enum.any?(Map.values(input), &(&1 != "")),
      do: :ok,
      else: {:error, :invalid_input}
  end

  defp explicit_input(_), do: {:error, :invalid_input}

  defp public(%{entry: entry} = binding) do
    fields = %{
      source_authority: Atom.to_string(entry.authority),
      source_id: entry.source_id,
      skill_id: entry.skill_id,
      revision: entry.revision,
      artifact_digest: entry.artifact_digest,
      name: entry.name,
      description: entry.description,
      locator: entry.locator
    }

    case binding do
      %{record_id: record_id} -> Map.put(fields, :record_id, record_id)
      %{kind: :workshop} -> fields
    end
  end

  defp native_load(%Entry{loader: %{type: :local, root: root}} = entry, _context) do
    with true <- is_binary(root) and Path.type(root) == :absolute and Path.expand(root) == root,
         true <-
           is_binary(entry.skill_id) and Path.type(entry.skill_id) == :relative and
             not String.contains?(entry.skill_id, ["\\", "\0"]) and
             Enum.all?(String.split(entry.skill_id, "/"), &(&1 not in ["", ".", ".."])),
         {:ok, content} <- local_content(root, entry.skill_id, instruction_limit(entry)) do
      {:ok, content}
    else
      false -> {:error, :unsafe_path}
      error -> error
    end
  end

  defp native_load(%Entry{loader: %{type: :workshop}} = entry, context) do
    execution = %{deadline: context.deadline, assert_live: fn -> body_alive(context) end}

    with :ok <- body_alive(context),
         {:ok, %{content: content}} <-
           SkillWorkshop.read_catalog_entry(context.workshop_scope, entry, execution),
         :ok <- body_alive(context),
         do: {:ok, content}
  end

  defp native_load(entry, context) do
    case load(
           entry,
           Map.put(context, :skill_loader, Application.get_env(:synapsis_core, :skill_loader))
         ) do
      {:ok, content} when is_binary(content) -> {:ok, content}
      _ -> {:error, :unavailable}
    end
  end

  defp local_content(root, skill_id, limit) do
    case read_file(Path.join([root, skill_id, "SKILL.md"]), limit) do
      {:error, :not_found} ->
        with {:ok, content} <- read_file(Path.join(root, "SKILL.md"), limit),
             {:ok, document} <- Parser.parse(content),
             true <- document.name == skill_id do
          {:ok, content}
        else
          false -> {:error, :not_found}
          {:error, reason} when is_atom(reason) -> {:error, reason}
          _ -> {:error, :invalid_document}
        end

      result ->
        result
    end
  end

  defp native_validate(%Entry{loader: %{type: :inline, canonical?: false}}, content, _trigger),
    do: {:ok, content}

  # The workshop's pinned source contract accepts metadata beyond the protocol
  # parser's canonical subset. Its owner already verified the complete selected
  # tree and exact document; do not reinterpret those authored bytes here.
  defp native_validate(%Entry{loader: %{type: :workshop}}, content, _trigger),
    do: {:ok, content}

  # Legacy explicit reads validate the document but do not apply automatic or
  # user-invocation eligibility. Keep that contract separate from auto reads.
  defp native_validate(entry, content, :explicit) do
    case validate_content(entry, content) do
      {:ok, content} -> {:ok, content}
      _ -> {:error, :invalid_document}
    end
  end

  defp native_validate(entry, content, :automatic) do
    with {:ok, content} <- validate_content(entry, content),
         {:ok, document} <- Parser.parse(content),
         {:ok, :eligible} <- Eligibility.evaluate(document, :automatic, %{enabled: true}) do
      {:ok, content}
    else
      _ -> {:error, :invalid_document}
    end
  end

  defp local_digest(%Entry{authority: :local, artifact_digest: digest}, content)
       when is_binary(digest) do
    if digest == digest(content), do: :ok, else: {:error, :digest_mismatch}
  end

  defp local_digest(_, _), do: :ok

  defp instruction_limit(%Entry{prompt_visible: false}), do: @non_prompt_instruction_bytes
  defp instruction_limit(_), do: @max_document

  defp instruction_size(%Entry{prompt_visible: false}, content)
       when is_binary(content) and byte_size(content) > @non_prompt_instruction_bytes,
       do: {:error, :file_limit}

  defp instruction_size(_entry, content), do: content_size(content)

  defp content_size(content) when is_binary(content) and byte_size(content) <= @max_document do
    if String.valid?(content), do: :ok, else: {:error, :invalid_document}
  end

  defp content_size(_), do: {:error, :file_limit}

  defp read_file(path, limit) do
    with {:ok, ancestors} <- ancestry(Path.dirname(path)),
         {:ok, stat} <- leaf(path, limit),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, info} <- :file.read_file_info(io, time: :posix),
             true <- same_file?(stat, File.Stat.from_record(info)),
             {:ok, content} <- file_content(io, limit),
             :ok <- content_size(content),
             {:ok, after_info} <- :file.read_file_info(io, time: :posix),
             true <- same_file?(stat, File.Stat.from_record(after_info)),
             {:ok, ^ancestors} <- ancestry(Path.dirname(path)),
             {:ok, final} <- leaf(path, limit),
             true <- same_file?(stat, final) do
          {:ok, content}
        else
          false -> {:error, :unsafe_path}
          {:ok, _} -> {:error, :unsafe_path}
          error -> error
        end
      after
        File.close(io)
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  defp file_content(io, limit) do
    case :file.read(io, limit + 1) do
      :eof -> {:ok, ""}
      {:ok, content} when byte_size(content) > limit -> {:error, :file_limit}
      result -> result
    end
  end

  defp ancestry(path) do
    path
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, acc} ->
      case File.lstat(component, time: :posix) do
        {:ok, %{type: :directory} = stat} -> {:cont, {:ok, [{component, identity(stat)} | acc]}}
        {:ok, _} -> {:halt, {:error, :unsafe_path}}
        {:error, :enoent} -> {:halt, {:error, :not_found}}
        _ -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp leaf(path, limit) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular, links: 1, size: size} = stat} when size <= limit -> {:ok, stat}
      {:ok, %{type: :regular, links: 1}} -> {:error, :file_limit}
      {:ok, _} -> {:error, :unsafe_path}
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  defp identity(stat), do: {stat.type, stat.major_device, stat.minor_device, stat.inode}

  defp same_file?(a, b),
    do:
      identity(a) == identity(b) and a.links == b.links and a.size == b.size and
        a.mtime == b.mtime and a.ctime == b.ctime

  defp options(opts, allowed) do
    if Keyword.keyword?(opts) and Enum.all?(opts, fn {key, _} -> key in allowed end) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: {:error, :invalid_input}
  end

  defp valid_id?(id), do: is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id))

  defp output(public), do: {:ok, public}

  defp bounded(opts, fun, join_cleanup? \\ false) do
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + @timeout)

    if is_integer(deadline) do
      deadline = min(deadline, now + @timeout)

      if deadline <= now do
        {:error, :timeout}
      else
        owner = self()
        ref = make_ref()

        {guardian, monitor} =
          spawn_monitor(fn -> guard(owner, ref, deadline, fun, join_cleanup?) end)

        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            result

          {:DOWN, ^monitor, :process, ^guardian, _} ->
            {:error, :worker_limit}
        end
      end
    else
      {:error, :invalid_input}
    end
  end

  defp guard(owner, ref, deadline, fun, join_cleanup?) do
    owner_monitor = Process.monitor(owner)
    guardian = self()
    token = make_ref()

    context = %{
      deadline: deadline,
      cancelled?: fn ->
        not Process.alive?(owner) or System.monotonic_time(:millisecond) >= deadline
      end
    }

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              fun.(context)
            rescue
              _ -> {:error, :unavailable}
            catch
              _, _ -> {:error, :unavailable}
            end

          send(guardian, {token, result})
        end,
        [:monitor, {:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false}}]
      )

    receive do
      {^token, result} -> send(owner, {ref, result})
      {:DOWN, ^monitor, :process, ^worker, _} -> send(owner, {ref, {:error, :worker_limit}})
      {:DOWN, ^owner_monitor, :process, ^owner, _} -> unwind(worker, monitor)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        if join_cleanup? do
          unwind(worker, monitor)
          send(owner, {ref, {:error, :timeout}})
        else
          send(owner, {ref, {:error, :timeout}})
          unwind(worker, monitor)
        end
    end
  end

  # Let the protocol's cancellation checks unwind its try/after blocks. This
  # grace period is bounded; forced termination cannot promise artifact cleanup.
  defp unwind(worker, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^worker, _} -> :ok
    after
      11_000 ->
        Process.exit(worker, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^worker, _} -> :ok)
    end
  end

  @doc false
  def load(%Entry{loader: %{type: :inline}, body: body}, _context) when is_binary(body),
    do: {:ok, body}

  def load(%Entry{loader: %{type: :local, root: root}} = entry, _context) when is_binary(root) do
    with {:ok, descriptors} <-
           Local.discover([%{source_id: entry.source_id, path: root, precedence: 0}]),
         descriptor when not is_nil(descriptor) <-
           Enum.find(descriptors, fn descriptor ->
             descriptor.ref.source_id == entry.source_id and
               descriptor.ref.skill_id == entry.skill_id
           end),
         {:ok, content} <- File.read(descriptor.path) do
      {:ok, content}
    else
      nil -> {:error, "Assigned local Skill is no longer available"}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def load(%Entry{loader: %{type: :backplane}} = entry, context) do
    case context[:skill_loader] do
      loader when is_function(loader, 2) -> loader.(entry, context)
      _ -> {:error, "Backplane Skill source is unavailable"}
    end
  end

  def load(_entry, _context), do: {:error, "Skill source is unavailable"}

  @doc false
  def validate_content(%Entry{loader: %{type: :inline, canonical?: false}}, content),
    do: {:ok, content}

  def validate_content(_entry, content) do
    with {:ok, document} <- Parser.parse(content),
         {:ok, document} <- Validator.validate(document, profile: :legacy) do
      {:ok, document.raw}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason)
end
