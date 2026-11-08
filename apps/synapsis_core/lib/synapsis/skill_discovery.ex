defmodule Synapsis.SkillDiscovery do
  @moduledoc """
  Immutable metadata discovery for assigned and Agent-private learned skills.

  The assigned section is the exact existing SkillReader snapshot. Learned
  bindings have their own source identity and content-tree evidence; they never
  acquire global record UUIDs. Resolver captures the prompt catalog and native
  reader snapshot together; the Agent adapter owns native issuance and publication.

  Pure snapshot validity is not issuance authority or a live-content claim.
  Assigned freshness recaptures only assigned configuration and the trusted
  Agent scope. Selected learned content is checked by the workshop read owner.
  """

  alias Synapsis.{SkillReader, SkillWorkshop}
  alias Synapsis.SkillWorkshop.Discovery

  def capture(agent_id, execution) when is_map(execution) do
    with {:ok, execution} <- execution(execution),
         :ok <- current_execution(execution),
         {:ok, scope} <- SkillWorkshop.capture(agent_id),
         :ok <- current_execution(execution),
         {:ok, assigned} <- SkillReader.snapshot(agent_id),
         :ok <- current_execution(execution),
         {:ok, learned} <- SkillWorkshop.catalog_entries(scope, execution),
         snapshot = %{
           schema: 2,
           assigned: assigned,
           learned: learned,
           generation: generation(assigned, learned)
         },
         true <- valid_snapshot?(snapshot),
         :ok <- current_execution(execution),
         :ok <- assigned_current(snapshot),
         :ok <- current_execution(execution) do
      {:ok, snapshot}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  def capture(_, _), do: {:error, :invalid_input}

  def valid_snapshot?(
        %{schema: 2, assigned: assigned, learned: learned, generation: value} = snapshot
      ) do
    exact_keys?(snapshot, [:schema, :assigned, :learned, :generation]) and
      SkillReader.valid_snapshot?(assigned) and
      unique?(Enum.map(assigned.bindings, & &1.record_id)) and
      Discovery.valid_projection?(learned, assigned.agent_id) and
      value == generation(assigned, learned)
  rescue
    _ -> false
  end

  def valid_snapshot?(_), do: false

  @doc "Assigned bindings first, followed by the captured learned-name order."
  def bindings(snapshot) do
    if valid_snapshot?(snapshot),
      do: snapshot.assigned.bindings ++ snapshot.learned.bindings,
      else: {:error, :invalid_snapshot}
  end

  def entries(snapshot) do
    case bindings(snapshot) do
      bindings when is_list(bindings) -> Enum.map(bindings, & &1.entry)
      error -> error
    end
  end

  def binding_key(%{record_id: id, entry: _, fingerprint: _} = binding)
      when map_size(binding) == 3,
      do: {:assigned, id}

  def binding_key(
        %{kind: :workshop, owner_id: owner, entry: %{skill_id: name}, fingerprint: _} = binding
      )
      when map_size(binding) == 4,
      do: {:workshop, owner, name}

  def binding_key(_), do: {:error, :invalid_binding}

  @doc "Check assigned configuration and trusted scope without scanning learned files."
  def assigned_current(snapshot) do
    with true <- valid_snapshot?(snapshot),
         {:ok, scope} <- SkillWorkshop.capture(snapshot.assigned.agent_id),
         true <- scope === snapshot.learned.scope,
         {:ok, fresh} <- SkillReader.snapshot(snapshot.assigned.agent_id),
         true <- fresh === snapshot.assigned,
         {:ok, after_scope} <- SkillWorkshop.capture(snapshot.assigned.agent_id),
         true <- after_scope === scope do
      :ok
    else
      false -> {:error, :stale_snapshot}
      error -> error
    end
  end

  defp generation(assigned, learned) do
    bytes = :erlang.term_to_binary({:skill_discovery_v2, assigned, learned}, [:deterministic])
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end

  defp execution(value) do
    live = Map.get(value, :assert_live, fn -> :ok end)

    if is_integer(value[:deadline]) and is_function(live, 0) do
      {:ok,
       Map.merge(value, %{
         deadline: min(value.deadline, System.monotonic_time(:millisecond) + 5_000),
         assert_live: live
       })}
    else
      {:error, :invalid_execution}
    end
  end

  defp current_execution(execution) do
    if System.monotonic_time(:millisecond) < execution.deadline,
      do: execution.assert_live.(),
      else: {:error, :timeout}
  end

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp unique?(values), do: values == Enum.uniq(values)
end
