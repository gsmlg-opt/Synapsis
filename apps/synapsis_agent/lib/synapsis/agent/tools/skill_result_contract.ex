defmodule Synapsis.Agent.Tools.SkillResultContract do
  @moduledoc """
  Trusted native result allowances for the Skills consumer, selected pre-dispatch.

  Reader acquisition permits canonical documents up to the protocol's 2 MiB;
  workshop view permits 1 MiB main documents and 256 KiB support documents. Both
  adapters retain text twice (model text and structured source), and JSON may
  escape each input byte into six bytes. Actual issued reader metadata contributes
  to the allowance. A separate 1 MiB envelope reserve covers ordinary workshop
  metadata and source text. It is a finite native admission allowance, not a new
  source file/count cap or a universal bound for unbounded list/version arrays.

  Runtime persists this selection on the invocation and carries it through nested
  Code Mode. Provider accounting, outer Code Mode output and host display/Part
  validation remain independent consumers of the complete result.
  """

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.Tools.{ExplicitSkill, Skills, SkillWorkshop}
  alias Synapsis.SkillReader

  @reader_bytes 2 * 1_024 * 1_024
  @workshop_bytes 1_024 * 1_024
  @envelope_bytes 1_024 * 1_024
  @read_names ["synapsis::skills_search", "synapsis::skills_read"]

  def select(%{backend: Skills, tool_name: name, tool_revision: 2} = descriptor, identity)
      when name in @read_names,
      do: selected(descriptor, identity, :reader)

  def select(
        %{backend: ExplicitSkill, tool_name: "synapsis::skill", tool_revision: 2} = descriptor,
        identity
      ),
      do: selected(descriptor, identity, :reader)

  def select(
        %{backend: SkillWorkshop, tool_name: "synapsis::skill_workshop", tool_revision: 1} =
          descriptor,
        identity
      ),
      do: selected(descriptor, identity, :workshop)

  def select(_, _), do: :default

  @doc "Pinned formatSkillInstructions model text, retaining the complete inert body."
  def format_instructions(%{content: content, citation: citation} = result) do
    location = Map.get(result, :location, citation)
    note = Map.get(result, :locationNote) || Map.get(result, :location_note)

    [
      "Skill location: #{location}",
      "Resolve relative resource paths from the directory containing this SKILL.md."
    ]
    |> then(fn context ->
      if is_binary(note) and note != "", do: context ++ [note], else: context
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n\n" <> content)
  end

  defp selected(%{backend: backend, backend_context: context} = descriptor, identity, kind)
       when is_map(context) and is_map(identity) do
    with {:ok, issued} <- backend.descriptors(context),
         true <- Enum.any?(issued, &same_binding?(&1, descriptor)),
         true <- identity[:tool_name] === descriptor.tool_name,
         true <- identity[:tool_revision] === descriptor.tool_revision,
         true <-
           identity[:run_id] === context.run_id and identity[:incarnation] === context.incarnation,
         true <-
           is_integer(identity[:catalog_revision]) and
             identity.catalog_revision >= context.catalog_revision do
      bytes = payload_bytes(kind, context)
      {:ok, %{output_limit: bytes + @envelope_bytes, json_limit: 6 * bytes + @envelope_bytes}}
    else
      _ -> {:error, Error.new(:validation, "Invalid Skills result contract binding")}
    end
  end

  defp selected(_, _, _),
    do: {:error, Error.new(:validation, "Invalid Skills result contract identity")}

  defp same_binding?(issued, descriptor),
    do:
      Map.take(issued, [:backend, :backend_context, :tool_name, :tool_revision, :schema, :safety]) ===
        Map.take(descriptor, [
          :backend,
          :backend_context,
          :tool_name,
          :tool_revision,
          :schema,
          :safety
        ])

  defp payload_bytes(:reader, %{snapshot: snapshot}) do
    metadata =
      snapshot
      |> SkillReader.bindings()
      |> Enum.map(fn binding ->
        entry = binding.entry

        fields = [
          entry.name,
          entry.description,
          entry.locator,
          entry.source_id,
          entry.skill_id,
          entry.revision,
          entry.artifact_digest,
          Map.get(binding, :record_id)
        ]

        Enum.reduce(fields, 1_024, fn value, total ->
          if is_binary(value), do: total + byte_size(value), else: total
        end)
      end)

    # Search returns at most twenty rows in both text and structured metadata.
    # Reserving those rows also covers the selected single read's provenance.
    metadata = metadata |> Enum.sort(:desc) |> Enum.take(20) |> Enum.sum()
    2 * (@reader_bytes + metadata)
  end

  defp payload_bytes(:workshop, _context), do: 2 * @workshop_bytes + @envelope_bytes
end
