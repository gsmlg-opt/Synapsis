defmodule Synapsis.SkillWorkshop do
  @moduledoc """
  Private, versioned learned-skill authoring for one persisted Agent.

  Files participate in one complete private-root filesystem lease. Content
  validation uses the pinned source contract. A file mutation and its Concord
  change are separate commits: only an acknowledged change is broadcast, and an
  unknown ledger outcome is never retried or treated as a reason to undo files.

  This Core API does not register a model tool or modify assigned global skills.
  """

  alias Synapsis.Filesystem.Local
  alias Synapsis.SkillWorkshop.{Changes, Contract, Discovery, Files, Scope}

  @actions ~w(list view create patch write_file remove_file archive restore)
  @mutations ~w(create patch write_file remove_file archive restore)
  @support_roots ~w(assets examples references scripts templates)
  @version_pattern ~r/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(\d{3})Z-(create|patch|write_file|remove_file|archive|restore)$/

  defdelegate capture(agent_id), to: Scope

  @doc "Capture immutable metadata and complete content evidence for live private skills."
  def catalog_entries(%Scope{} = scope, execution) when is_map(execution) do
    with {:ok, execution} <- execution(execution), do: Discovery.catalog_entries(scope, execution)
  end

  def catalog_entries(_, _), do: {:error, :invalid_input}

  @doc "Acquire the exact selected learned document at its captured content-tree revision."
  def read_catalog_entry(%Scope{} = scope, entry, execution) when is_map(execution) do
    with {:ok, execution} <- execution(execution),
         do: Discovery.read_catalog_entry(scope, entry, execution)
  end

  def read_catalog_entry(_, _, _), do: {:error, :invalid_input}

  def run(%Scope{} = scope, params, execution) when is_map(params) and is_map(execution) do
    with {:ok, execution} <- execution(execution),
         {:ok, action} <- string(params, "action", true),
         true <- action in @actions do
      Local.with_paths(
        scope.config_root,
        [scope.relative_root],
        [deadline: execution.deadline],
        fn opts ->
          ctx = %{
            scope: scope,
            opts: opts,
            assert_live: execution.assert_live,
            execution: execution
          }

          with :ok <- Files.check(ctx), do: dispatch(ctx, action, params)
        end
      )
    else
      false -> {:error, :invalid_action}
      error -> error
    end
  end

  def run(_, _, _), do: {:error, :invalid_input}

  defp execution(value) do
    now = System.monotonic_time(:millisecond)
    live = Map.get(value, :assert_live, fn -> :ok end)
    actor = Map.get(value, :actor, "agent")

    if is_integer(value[:deadline]) and is_function(live, 0) and
         actor in ~w(agent review curator user) and
         Enum.all?([:session_key, :run_id], fn key ->
           not Map.has_key?(value, key) or (is_binary(value[key]) and value[key] != "")
         end) do
      {:ok,
       Map.merge(value, %{
         deadline: min(value.deadline, now + 5_000),
         assert_live: live,
         actor: actor
       })}
    else
      {:error, :invalid_execution}
    end
  end

  defp dispatch(ctx, "list", _params) do
    with {:ok, skills} <- list_skills(ctx),
         {:ok, archived} <- list_archive(ctx) do
      lines = Enum.map(skills, &("- " <> &1["name"] <> ": " <> &1["description"]))

      lines =
        if archived == [],
          do: lines,
          else:
            lines ++
              [
                "Archived (restore with action=restore):"
                | Enum.map(archived, &("- " <> &1["name"]))
              ]

      text =
        if lines == [],
          do: "No learned skills yet. Add one with action=create.",
          else: Enum.join(lines, "\n")

      {:ok, result(text, %{"skills" => skills, "archived" => archived})}
    end
  end

  defp dispatch(ctx, "view", params) do
    with {:ok, name} <- name(params),
         {:ok, file} <- file(params),
         {:ok, version} <- string(params, "version"),
         {:ok, base} <- view_base(ctx, name, version),
         {:ok, facts} <- Files.metadata(ctx, base),
         {:ok, content} <- Files.read(ctx, Path.join(base, file), read_limit(file)) do
      others = List.delete(facts["files"], file)

      text =
        if others == [],
          do: content,
          else: content <> "\n\n[Other files: " <> Enum.join(others, ", ") <> "]"

      details = %{"name" => name, "filePath" => file, "files" => facts["files"]}
      details = if version, do: Map.put(details, "version", version), else: details
      {:ok, result(text, details)}
    end
  end

  defp dispatch(ctx, action, params) when action in @mutations do
    with {:ok, name} <- name(params),
         {:ok, reason} <- string(params, "reason"),
         {:ok, mutation} <- apply_mutation(ctx, action, name, reason, params),
         :ok <- prune(ctx, name),
         :ok <- Files.check(ctx),
         {:ok, change} <-
           Changes.append(change(ctx, action, name, mutation), ctx.execution.deadline) do
      # The acknowledged row is the event payload; no speculative discovery event
      # precedes persistence, and no retries straddle the file/ledger boundary.
      Phoenix.PubSub.broadcast(
        Synapsis.PubSub,
        "skill_workshop:" <> ctx.scope.agent_id,
        {:skill_workshop_changed, change}
      )

      with {:ok, suffix} <- guidance(ctx, action, name, mutation) do
        verb =
          case action do
            "create" -> "Created"
            "patch" -> "Patched"
            "archive" -> "Archived"
            "restore" -> "Restored"
            _ -> "Updated"
          end

        undo =
          if change["versionId"],
            do: "Saved previous version; undo with action=restore name=#{name}.",
            else: "Undo with action=archive name=#{name}."

        text = "#{verb} \"#{name}\" (#{change["summary"]}). #{undo}"
        {:ok, result(Enum.join([text | suffix], "\n"), %{"change" => change})}
      end
    end
  end

  defp apply_mutation(ctx, "create", name, reason, params) do
    with true <- Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,62}$/, name),
         {:ok, false} <- Files.exists(ctx, name),
         {:ok, content} <- string(params, "content", true, false),
         {:ok, analysis} <- analyze(ctx, name, "SKILL.md", content, "") do
      case Files.write(ctx, Path.join(name, "SKILL.md"), content) do
        :ok ->
          {:ok,
           %{
             summary: reason || "created: " <> analysis["description"],
             version: nil,
             advisories: analysis["advisories"]
           }}

        error ->
          Files.cleanup(ctx, name)
          error
      end
    else
      true -> {:error, :invalid_name}
      false -> {:error, :invalid_name}
      {:ok, true} -> {:error, :already_exists}
      error -> error
    end
  end

  defp apply_mutation(ctx, action, name, reason, params) when action in ["patch", "write_file"] do
    with :ok <- require_live(ctx, name),
         {:ok, file} <- file(params, action == "write_file"),
         {:ok, before} <- current_content(ctx, Path.join(name, file), file, action),
         {:ok, content} <- next_content(params, action, before),
         true <- before != content,
         {:ok, analysis} <- analyze(ctx, name, file, content, before || ""),
         {:ok, version} <- snapshot(ctx, name, action),
         :ok <- Files.write(ctx, Path.join(name, file), content) do
      summary =
        case {action, file} do
          {"patch", _} -> "patched " <> file
          {"write_file", "SKILL.md"} -> "rewrote SKILL.md"
          _ -> "wrote " <> file
        end

      {:ok, %{summary: reason || summary, version: version, advisories: analysis["advisories"]}}
    else
      false -> {:error, :unchanged}
      error -> error
    end
  end

  defp apply_mutation(ctx, "remove_file", name, reason, params) do
    with :ok <- require_live(ctx, name),
         {:ok, file} <- file(params, true),
         true <- file != "SKILL.md",
         {:ok, facts} <- Files.metadata(ctx, name),
         true <- file in facts["files"],
         {:ok, version} <- snapshot(ctx, name, "remove_file"),
         :ok <- Files.remove(ctx, Path.join(name, file)) do
      {:ok, %{summary: reason || "removed " <> file, version: version, advisories: []}}
    else
      false -> {:error, :invalid_file}
      error -> error
    end
  end

  defp apply_mutation(ctx, "archive", name, reason, params) do
    with :ok <- require_live(ctx, name),
         {:ok, target} <- string(params, "absorbed_into"),
         :ok <- absorbed_target(ctx, name, target),
         {:ok, version} <- snapshot(ctx, name, "archive"),
         detached = Path.join(".archive", ".archiving-" <> Ecto.UUID.generate()),
         :ok <- Files.rename(ctx, name, detached),
         :ok <- Files.remove_tree(ctx, detached) do
      parts = Enum.reject([if(target, do: "merged into " <> target), reason], &is_nil/1)
      summary = if parts == [], do: "archived", else: "archived: " <> Enum.join(parts, "; ")
      {:ok, %{summary: summary, version: version, advisories: []}}
    end
  end

  defp apply_mutation(ctx, "restore", name, reason, params) do
    with {:ok, wanted} <- string(params, "version"),
         {:ok, versions} <- versions(ctx, name),
         target when is_map(target) <-
           if(wanted, do: Enum.find(versions, &(&1["id"] == wanted)), else: List.first(versions)),
         {:ok, files} <- restorable(ctx, name, target["id"]) do
      restore(ctx, name, target, files, wanted, reason)
    else
      nil -> {:error, :version_not_found}
      error -> error
    end
  end

  defp restore(ctx, name, target, files, wanted, reason) do
    staging = Path.join(".archive", ".restore-" <> Ecto.UUID.generate())
    previous = Path.join(".archive", ".restore-previous-" <> Ecto.UUID.generate())

    try do
      with {:ok, _} <-
             reduce(files, nil, fn {file, bytes}, _ ->
               with :ok <- Files.write(ctx, Path.join(staging, file), bytes), do: {:ok, nil}
             end),
           {:ok, version} <- snapshot(ctx, name, "restore"),
           {:ok, had_live} <- Files.exists(ctx, name),
           :ok <- detach_previous(ctx, name, previous, had_live),
           :ok <- publish_restore(ctx, staging, name, previous, had_live),
           :ok <- Files.remove_tree(ctx, previous) do
        summary =
          cond do
            reason -> reason
            target["action"] == "archive" -> "restored from archive"
            wanted -> "restored version " <> target["id"]
            true -> "undid " <> String.replace(target["action"], "_", " ", global: false)
          end

        {:ok, %{summary: summary, version: version, advisories: []}}
      end
    after
      Files.cleanup(ctx, staging)
    end
  end

  defp detach_previous(_ctx, _name, _previous, false), do: :ok
  defp detach_previous(ctx, name, previous, true), do: Files.rename(ctx, name, previous)

  defp publish_restore(ctx, staging, name, previous, had_live) do
    case Files.rename(ctx, staging, name) do
      :ok ->
        :ok

      error ->
        if had_live do
          case Files.rename(ctx, previous, name) do
            :ok -> error
            rollback_error -> {:error, {:restore_rollback, error, rollback_error}}
          end
        else
          error
        end
    end
  end

  defp restorable(ctx, name, id) do
    base = Path.join([".archive", name, id])

    with {:ok, %{type: :directory}} <- Files.stat(ctx, base),
         {:ok, paths} <- Files.visible(ctx, base, :restore),
         true <- "SKILL.md" in paths do
      reduce(paths, [], fn path, acc ->
        with {:ok, ^path} <- normalize_file(path),
             maximum =
               if(path == "SKILL.md", do: ctx.scope.max_skill_bytes, else: read_limit(path)),
             {:ok, bytes} <- Files.read(ctx, Path.join(base, path), maximum),
             {:ok, _} <- analyze(ctx, name, path, bytes, "") do
          {:ok, [{path, bytes} | acc]}
        end
      end)
    else
      false -> {:error, :missing_skill_file}
      {:ok, _} -> {:error, :not_directory}
      error -> error
    end
  end

  defp snapshot(ctx, name, action) do
    with {:ok, live} <- Files.exists(ctx, Path.join(name, "SKILL.md")) do
      if live do
        with {:ok, versions} <- versions(ctx, name),
             newest =
               (case versions do
                  [first | _] -> first["createdAtMs"]
                  [] -> 0
                end),
             created = max(System.system_time(:millisecond), newest + 1),
             id = version_id(created, action),
             directory = Path.join(".archive", name),
             :ok <- Files.mkdir(ctx, directory) do
          staging = Path.join(directory, ".snapshot-" <> Ecto.UUID.generate())

          try do
            with :ok <- Files.copy_tree(ctx, name, staging),
                 :ok <- Files.rename(ctx, staging, Path.join(directory, id)),
                 do: {:ok, id}
          after
            Files.cleanup(ctx, staging)
          end
        end
      else
        {:ok, nil}
      end
    end
  end

  defp versions(ctx, name) do
    with {:ok, entries} <- Files.entries(ctx, Path.join(".archive", name)) do
      values =
        for {id, %{type: :directory}} <- entries,
            version = parse_version(id),
            version != nil,
            do: version

      {:ok, Enum.sort_by(values, & &1["id"], :desc)}
    end
  end

  defp parse_version(id) do
    with [year, month, day, hour, minute, second, ms, action] <-
           Regex.run(@version_pattern, id, capture: :all_but_first),
         {:ok, datetime, 0} <-
           DateTime.from_iso8601("#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}.#{ms}Z") do
      %{"id" => id, "action" => action, "createdAtMs" => DateTime.to_unix(datetime, :millisecond)}
    else
      _ -> nil
    end
  end

  defp version_id(created, action) do
    datetime = DateTime.from_unix!(created, :millisecond)

    Calendar.strftime(datetime, "%Y%m%dT%H%M%S") <>
      (created |> rem(1_000) |> Integer.to_string() |> String.pad_leading(3, "0")) <>
      "Z-" <> action
  end

  defp prune(ctx, name) do
    with {:ok, versions} <- versions(ctx, name),
         {:ok, _} <-
           reduce(Enum.drop(versions, 10), nil, fn version, _ ->
             with :ok <- Files.remove_tree(ctx, Path.join([".archive", name, version["id"]])),
                  do: {:ok, nil}
           end),
         do: :ok
  end

  defp list_skills(ctx) do
    with {:ok, entries} <- Files.entries(ctx, "."),
         {:ok, rows} <-
           reduce(entries, [], fn {name, stat}, acc ->
             if stat.type == :directory and valid_name?(name) do
               case Files.read(ctx, Path.join(name, "SKILL.md"), read_limit("SKILL.md")) do
                 {:ok, content} ->
                   with {:ok, frontmatter, _} <-
                          Contract.run(
                            %{"operation" => "frontmatter", "content" => content},
                            ctx.execution.deadline
                          ),
                        {:ok, facts} <- Files.metadata(ctx, name) do
                     row =
                       Map.merge(facts, %{
                         "name" => name,
                         "description" => String.trim(frontmatter["description"] || "")
                       })

                     {:ok, [row | acc]}
                   end

                 {:error, :enoent} ->
                   {:ok, acc}

                 error ->
                   error
               end
             else
               {:ok, acc}
             end
           end),
         {:ok, order} <- Files.sort_names(ctx, Enum.map(rows, & &1["name"])) do
      indexed = Map.new(rows, &{&1["name"], &1})
      {:ok, Enum.map(order, &Map.fetch!(indexed, &1))}
    end
  end

  defp list_archive(ctx) do
    with {:ok, entries} <- Files.entries(ctx, ".archive") do
      entries
      |> Enum.filter(fn {name, stat} -> stat.type == :directory and valid_name?(name) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> reduce([], fn {name, _}, acc ->
        with {:ok, versions} <- versions(ctx, name),
             {:ok, live} <- Files.exists(ctx, Path.join(name, "SKILL.md")) do
          if versions != [] and not live,
            do: {:ok, acc ++ [%{"name" => name, "live" => false, "versions" => versions}]},
            else: {:ok, acc}
        end
      end)
    end
  end

  defp view_base(ctx, name, nil) do
    with :ok <- require_live(ctx, name), do: {:ok, name}
  end

  defp view_base(ctx, name, id) do
    with {:ok, versions} <- versions(ctx, name),
         true <- Enum.any?(versions, &(&1["id"] == id)) do
      {:ok, Path.join([".archive", name, id])}
    else
      false -> {:error, :version_not_found}
      error -> error
    end
  end

  defp require_live(ctx, name) do
    with {:ok, true} <- Files.exists(ctx, Path.join(name, "SKILL.md")) do
      :ok
    else
      {:ok, false} -> {:error, :not_live}
      error -> error
    end
  end

  defp absorbed_target(_ctx, _name, nil), do: :ok

  defp absorbed_target(ctx, name, target) do
    if name != target and valid_name?(target),
      do: require_live(ctx, target),
      else: {:error, :invalid_target}
  end

  defp current_content(ctx, relative, file, action) do
    case Files.read(ctx, relative, read_limit(file)) do
      {:error, :enoent} when action == "write_file" -> {:ok, nil}
      result -> result
    end
  end

  defp next_content(params, "write_file", _before), do: string(params, "content", true, false)

  defp next_content(params, "patch", before) do
    with {:ok, old} <- string(params, "old_text", true, false),
         {:ok, new} <- string(params, "new_text", false, false, true),
         new = new || "",
         true <- old != new,
         [position] <- match_positions(before, old, 0, []) do
      size = byte_size(old)
      <<prefix::binary-size(position), _::binary-size(size), suffix::binary>> = before
      {:ok, prefix <> new <> suffix}
    else
      false -> {:error, :unchanged}
      positions when is_list(positions) -> {:error, :non_unique_patch}
      error -> error
    end
  end

  defp match_positions(content, old, offset, acc) when offset < byte_size(content) do
    case :binary.match(content, old, scope: {offset, byte_size(content) - offset}) do
      :nomatch -> acc
      {position, _} -> match_positions(content, old, position + 1, [position | acc])
    end
  end

  defp match_positions(_content, _old, _offset, acc), do: acc

  defp analyze(ctx, name, file, content, before) do
    with :ok <- Files.check(ctx),
         {:ok, analysis, _receipt} <-
           Contract.run(
             %{
               "operation" => "analyze",
               "name" => name,
               "filePath" => file,
               "content" => content,
               "before" => before,
               "maxSkillBytes" => ctx.scope.max_skill_bytes
             },
             ctx.execution.deadline
           ),
         :ok <- Files.check(ctx),
         do: {:ok, analysis}
  end

  defp guidance(ctx, action, name, mutation) do
    if action == "create" do
      with {:ok, skills} <- list_skills(ctx) do
        others = Enum.reject(skills, &(&1["name"] == name))

        siblings =
          if others == [],
            do: [],
            else: [
              "Other learned skills; if one covers the same class of task, merge (patch the broader one, archive the other with absorbed_into):"
              | Enum.map(others, &("- " <> &1["name"] <> ": " <> &1["description"]))
            ]

        {:ok, mutation.advisories ++ siblings}
      end
    else
      {:ok, mutation.advisories}
    end
  end

  defp change(ctx, action, name, mutation) do
    row = %{
      "id" => Ecto.UUID.generate(),
      "agentId" => ctx.scope.agent_id,
      "skillName" => name,
      "action" => action,
      "actor" => ctx.execution.actor,
      "summary" => mutation.summary,
      "createdAtMs" => System.system_time(:millisecond)
    }

    row = if mutation.version, do: Map.put(row, "versionId", mutation.version), else: row

    Enum.reduce([session_key: "sessionKey", run_id: "runId"], row, fn {key, label}, acc ->
      if ctx.execution[key], do: Map.put(acc, label, ctx.execution[key]), else: acc
    end)
  end

  defp name(params) do
    with {:ok, name} <- string(params, "name", true),
         true <- valid_name?(name) do
      {:ok, name}
    else
      false -> {:error, :invalid_name}
      error -> error
    end
  end

  defp valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/^[a-z0-9][a-z0-9-]{0,254}$/, name)

  defp file(params, required \\ false) do
    with {:ok, path} <- string(params, "file_path", required),
         do: normalize_file(path || "SKILL.md")
  end

  defp normalize_file("SKILL.md"), do: {:ok, "SKILL.md"}

  defp normalize_file(path) do
    parts = String.split(path, "/")

    if path != "" and Path.type(path) == :relative and not String.contains?(path, ["\\", "\0"]) and
         hd(parts) in @support_roots and
         Enum.all?(parts, &(&1 != "" and not String.starts_with?(&1, "."))) do
      {:ok, path}
    else
      {:error, :invalid_file}
    end
  end

  defp string(params, key, required \\ false, trim \\ true, allow_empty \\ false) do
    case Map.get(params, key) do
      nil when not required ->
        {:ok, nil}

      text when is_binary(text) ->
        text = if trim, do: String.trim(text), else: text

        cond do
          not String.valid?(text) -> {:error, :invalid_input}
          text != "" or allow_empty -> {:ok, text}
          required -> {:error, :invalid_input}
          true -> {:ok, nil}
        end

      _ ->
        {:error, :invalid_input}
    end
  end

  defp read_limit("SKILL.md"), do: 1_024 * 1_024
  defp read_limit(_), do: 256 * 1_024

  defp result(text, details),
    do: %{"content" => [%{"type" => "text", "text" => text}], "details" => details}

  defp reduce(items, initial, fun) do
    Enum.reduce_while(items, {:ok, initial}, fn item, {:ok, acc} ->
      case fun.(item, acc) do
        {:ok, value} -> {:cont, {:ok, value}}
        error -> {:halt, error}
      end
    end)
  end
end
