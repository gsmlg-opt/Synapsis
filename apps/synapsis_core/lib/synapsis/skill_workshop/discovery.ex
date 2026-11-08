defmodule Synapsis.SkillWorkshop.Discovery do
  @moduledoc false

  alias Synapsis.Filesystem.Local
  alias Synapsis.SkillCatalog
  alias Synapsis.SkillCatalog.Entry
  alias Synapsis.SkillWorkshop.{Contract, Files, Scope}

  @scope_keys Enum.sort([
                :__struct__,
                :agent_id,
                :config_root,
                :relative_root,
                :root,
                :max_skill_bytes
              ])
  @name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,254}\z/
  @digest_pattern ~r/\Asha256:[a-f0-9]{64}\z/

  def catalog_entries(%Scope{} = scope, execution) do
    with_scope(scope, execution, fn ctx ->
      with {:ok, names} <- live_names(ctx),
           {:ok, bindings} <- capture_bindings(ctx, names),
           {:ok, ^names} <- live_names(ctx),
           :ok <- current_scope(ctx) do
        {:ok, %{scope: scope, bindings: bindings}}
      else
        {:ok, _} -> {:error, :conflict}
        error -> error
      end
    end)
  end

  def read_catalog_entry(%Scope{} = scope, %Entry{} = entry, execution) do
    if valid_entry?(scope, entry) do
      with_scope(scope, execution, fn ctx ->
        with {:ok, tree} <- Files.content_tree(ctx, entry.skill_id),
             true <-
               tree.revision == entry.revision and tree.document_digest == entry.artifact_digest,
             :ok <- current_scope(ctx) do
          {:ok, tree}
        else
          false -> {:error, :stale_snapshot}
          error -> error
        end
      end)
    else
      {:error, :invalid_entry}
    end
  end

  def read_catalog_entry(_, _, _), do: {:error, :invalid_entry}

  defp with_scope(scope, execution, fun) do
    with true <- valid_scope?(scope),
         :ok <- execution_current(execution),
         {:ok, ^scope} <- Scope.capture(scope.agent_id) do
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

          with :ok <- current_scope(ctx), do: fun.(ctx)
        end
      )
    else
      false -> {:error, :invalid_scope}
      {:ok, _} -> {:error, :stale_scope}
      error -> error
    end
  end

  defp current_scope(ctx) do
    with :ok <- Files.check(ctx),
         {:ok, scope} <- Scope.capture(ctx.scope.agent_id),
         true <- scope === ctx.scope,
         :ok <- Files.check(ctx) do
      :ok
    else
      false -> {:error, :stale_scope}
      error -> error
    end
  end

  defp execution_current(execution) do
    if System.monotonic_time(:millisecond) < execution.deadline,
      do: execution.assert_live.(),
      else: {:error, :timeout}
  end

  defp live_names(ctx) do
    with {:ok, children} <- Files.entries(ctx, ".") do
      children
      |> Enum.filter(fn {name, stat} -> stat.type == :directory and valid_name?(name) end)
      |> Enum.reduce_while({:ok, []}, fn {name, _stat}, {:ok, names} ->
        case Files.stat(ctx, Path.join(name, "SKILL.md")) do
          {:ok, %{type: :regular, links: 1}} -> {:cont, {:ok, [name | names]}}
          {:error, :enoent} -> {:cont, {:ok, names}}
          {:ok, _} -> {:halt, {:error, :not_regular}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, names} -> {:ok, Enum.sort(names)}
        error -> error
      end
    end
  end

  defp capture_bindings(ctx, names) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, bindings} ->
      with {:ok, tree} <- Files.content_tree(ctx, name),
           :ok <- Files.check(ctx),
           {:ok, frontmatter, _receipt} <-
             Contract.run(
               %{"operation" => "frontmatter", "content" => tree.content},
               ctx.execution.deadline
             ),
           :ok <- Files.check(ctx) do
        facts = %{
          name: name,
          description: String.trim(frontmatter["description"] || ""),
          revision: tree.revision,
          document_digest: tree.document_digest,
          prompt_visible: not disabled?(frontmatter["disable-model-invocation"])
        }

        entry = SkillCatalog.from_workshop(ctx.scope, facts)
        {:cont, {:ok, [binding(ctx.scope.agent_id, entry) | bindings]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bindings} -> {:ok, Enum.reverse(bindings)}
      error -> error
    end
  end

  # The source's parseFrontmatterBool accepts these case-insensitive strings;
  # missing or unrecognized values retain its false default for this field.
  defp disabled?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ~w(true 1 yes on)

  defp disabled?(_), do: false

  def binding(owner_id, %Entry{} = entry) do
    %{
      kind: :workshop,
      owner_id: owner_id,
      entry: entry,
      fingerprint: fingerprint(owner_id, entry)
    }
  end

  defp fingerprint(owner_id, entry) do
    {:workshop_binding_v1, owner_id, entry}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Pure DTO checks are deliberately separate from live scope/content checks.
  # They do not grant native issuance authority or claim that a file is current.
  def valid_projection?(%{scope: %Scope{} = scope, bindings: bindings} = projection, owner_id) do
    exact_keys?(projection, [:scope, :bindings]) and valid_scope?(scope) and
      scope.agent_id == owner_id and is_list(bindings) and
      Enum.all?(bindings, &valid_binding?(scope, &1)) and
      bindings == Enum.sort_by(bindings, & &1.entry.skill_id) and
      unique?(Enum.map(bindings, & &1.entry.skill_id))
  end

  def valid_projection?(_, _), do: false

  defp valid_binding?(
         scope,
         %{kind: :workshop, owner_id: owner_id, entry: %Entry{} = entry, fingerprint: value} =
           binding
       ) do
    exact_keys?(binding, [:kind, :owner_id, :entry, :fingerprint]) and
      owner_id == scope.agent_id and valid_entry?(scope, entry) and
      value == fingerprint(owner_id, entry)
  end

  defp valid_binding?(_, _), do: false

  def valid_entry?(%Scope{} = scope, %Entry{} = entry) do
    valid_scope?(scope) and valid_name?(entry.skill_id) and
      is_binary(entry.description) and String.valid?(entry.description) and
      valid_digest?(entry.revision) and valid_digest?(entry.artifact_digest) and
      is_boolean(entry.prompt_visible) and
      entry ===
        SkillCatalog.from_workshop(scope, %{
          name: entry.skill_id,
          description: entry.description,
          revision: entry.revision,
          document_digest: entry.artifact_digest,
          prompt_visible: entry.prompt_visible
        })
  end

  def valid_entry?(_, _), do: false

  def valid_scope?(%Scope{} = scope) do
    Enum.sort(Map.keys(scope)) == @scope_keys and canonical_id?(scope.agent_id) and
      is_binary(scope.config_root) and String.valid?(scope.config_root) and
      Path.type(scope.config_root) == :absolute and
      Path.expand(scope.config_root) == scope.config_root and
      scope.relative_root == Path.join(["agents", scope.agent_id, "workshop-skills"]) and
      scope.root == Path.join(scope.config_root, scope.relative_root) and
      is_integer(scope.max_skill_bytes) and scope.max_skill_bytes in 1_024..200_000
  end

  def valid_scope?(_), do: false

  defp valid_name?(name), do: is_binary(name) and Regex.match?(@name_pattern, name)
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@digest_pattern, value)
  defp canonical_id?(id), do: is_binary(id) and match?({:ok, ^id}, Ecto.UUID.cast(id))
  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp unique?(values), do: values == Enum.uniq(values)
end
