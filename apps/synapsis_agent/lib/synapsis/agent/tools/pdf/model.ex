defmodule Synapsis.Agent.Tools.PDF.Model do
  @moduledoc "Ordered configured and automatic PDF candidates, bound to the complete selection generation."

  alias Backplane.AgentRuntime.Error
  alias Synapsis.{Models, Providers}
  alias Synapsis.Provider.{Adapter, ModelRegistry}

  @doc "Resolve the complete current selection and its admitted input generation."
  def prepare(config, model_context \\ %{}) do
    with {:ok, snapshot} <- Providers.document_model_snapshot(),
         {:ok, models} <- selection(config, model_context, snapshot) do
      {:ok,
       %{
         models: models,
         fingerprint: digest({config, model_context, snapshot, models})
       }}
    end
  end

  def resolve(config, override), do: resolve(config, override, %{})

  def resolve(config, override, model_context) do
    with {:ok, prepared} <- prepare(config, model_context),
         {:ok, references} <- override(Enum.map(prepared.models, & &1.reference), override) do
      {:ok,
       Enum.map(references, fn reference ->
         Enum.find(prepared.models, &(&1.reference == reference))
       end)}
    end
  end

  def runtime(candidate) do
    with {:ok, snapshot} <- Providers.document_model_snapshot(),
         {:ok, current} <-
           materialize(
             candidate.reference,
             snapshot,
             candidate[:selection_mode] || :explicit,
             candidate.model_id
           ),
         true <- current === candidate and current.available,
         {:ok, runtime} <- Providers.runtime_config(candidate.provider),
         :ok <- Providers.ensure_model_runtime_available(runtime, candidate.model) do
      {:ok, runtime}
    else
      _ -> unavailable()
    end
  end

  defp selection(config, context, snapshot) do
    case references(config) do
      {:ok, references} ->
        Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, models} ->
          case materialize(reference, snapshot, :explicit) do
            {:ok, model} -> {:cont, {:ok, models ++ [model]}}
            error -> {:halt, error}
          end
        end)

      :absent ->
        automatic(snapshot, context)

      error ->
        error
    end
  end

  defp references(config) do
    case configured(config["pdfModel"]) do
      :absent -> configured(config["imageModel"])
      result -> result
    end
  end

  # The lanes intentionally follow the pinned algorithm rather than a combined
  # score. In particular a primary text-extraction hint changes fallback order.
  defp automatic(snapshot, context) do
    entries = snapshot.providers
    primary = identity_entry(entries, context[:configured_default])
    active = context[:active_model]
    auto = auto_providers(entries)
    image = Enum.flat_map(auto, &image_candidate(&1, snapshot))
    native = Enum.filter(image, & &1.native)

    text =
      ([primary] ++ auto)
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&text_candidate(&1, primary, context[:configured_default], snapshot))
      |> unique()

    configured_images =
      Enum.flat_map(entries, fn entry ->
        case {document_hint(entry, "image"), first_input(entry, "image")} do
          {false, _} ->
            []

          {_, nil} ->
            []

          {_, model} ->
            automatic_candidate(
              entry,
              model,
              snapshot,
              :automatic,
              entry.provider.name <> "/" <> model
            )
        end
      end)

    generic = unique(image ++ configured_images)
    prefer_text = primary != nil and Enum.any?(text, &(&1.provider_id == primary.provider.id))
    fallbacks = if prefer_text, do: native ++ text ++ generic, else: native ++ generic ++ text

    preferred =
      if primary && native?(primary) do
        model = vision(primary) || default_image(primary)
        if model, do: List.first(automatic_candidate(primary, model, snapshot))
      end

    preferred = preferred || List.first(fallbacks) || active_candidate(entries, active, snapshot)

    if preferred,
      do: {:ok, unique([preferred | fallbacks])},
      else: unavailable()
  end

  defp auto_providers(entries) do
    prioritized =
      entries
      |> Enum.filter(fn entry ->
        priority = image_priority(entry)
        "image" in List.wrap(entry.metadata.capabilities) and is_number(priority)
      end)
      |> Enum.sort_by(fn entry ->
        {image_priority(entry), source_name_key(entry.provider.name)}
      end)

    configured = Enum.filter(entries, &(first_input(&1, "image") != nil))
    {aliases, ordinary} = Enum.split_with(configured, &execution_alias?/1)
    alias_ids = MapSet.new(aliases, & &1.provider.id)
    prioritized = Enum.reject(prioritized, &MapSet.member?(alias_ids, &1.provider.id))

    aliases
    |> Enum.reduce(prioritized, fn entry, merged ->
      canonical = entry.metadata.profile
      index = Enum.find_index(merged, &(&1.provider.name == canonical)) || 0
      List.insert_at(merged, index, entry)
    end)
    |> Kernel.++(ordinary)
    |> Enum.uniq_by(& &1.provider.id)
  end

  # Saved provider names are validated lowercase ASCII. Preserve the source's
  # punctuation ordering for that supported alphabet; arbitrary Unicode/case
  # locale collation is outside this host identity contract.
  defp source_name_key(name) do
    for <<char <- name>>, do: if(char == ?_, do: 0, else: if(char == ?-, do: 1, else: char))
  end

  defp execution_alias?(entry),
    do: entry.provider.name in ["minimax-cn", "minimax-portal-cn"]

  defp image_priority(entry), do: Map.get(entry.metadata.auto_priority || %{}, "image")

  defp image_candidate(entry, snapshot) do
    case document_hint(entry, "image") do
      false ->
        []

      hint ->
        # Source takes split("/")[1] from a configured vision reference in this
        # lane. Preserve that choice; materialization still demands an exact saved
        # model identity, so arbitrary vendor slashes never rebind another row.
        configured = vision(entry)

        local =
          if configured,
            do: format_ref(entry.provider.name, configured) |> String.split("/") |> Enum.at(1)

        model = hint || local || default_image(entry)
        if model, do: automatic_candidate(entry, model, snapshot), else: []
    end
  end

  defp text_candidate(entry, primary, configured_default, snapshot) do
    hint = document_hint(entry, "textExtraction")

    if is_binary(hint) and hint != "" do
      preferred =
        if primary && entry.provider.id == primary.provider.id,
          do: configured_default[:model],
          else: first_input(entry, "text")

      local = if preferred, do: local_model(entry.provider.name, preferred)
      image_hint = document_hint(entry, "image")
      image_local = if is_binary(image_hint), do: local_model(entry.provider.name, image_hint)
      is_image = local != nil and local in [image_local, default_image(entry)]
      selected = if preferred && not is_image, do: preferred, else: hint
      automatic_candidate(entry, selected, snapshot)
    else
      []
    end
  end

  defp active_candidate(entries, %{supports_images: true, model: model} = active, snapshot) do
    entry = identity_entry(entries, active)

    if entry && document_hint(entry, "image") != false,
      do: List.first(automatic_candidate(entry, model, snapshot, :active)),
      else: nil
  end

  defp active_candidate(_entries, _active, _snapshot), do: nil

  defp identity_entry(entries, %{provider: provider}),
    do: Enum.find(entries, &(&1.provider.name == provider))

  defp identity_entry(_entries, _identity), do: nil

  defp first_input(entry, modality) do
    Enum.find_value(entry.models, fn %{record: model, available: available} ->
      if available and modality in List.wrap(model.input), do: model.model
    end)
  end

  defp vision(entry) do
    if entry.metadata.profile in ["minimax", "minimax-portal"],
      do: nil,
      else: first_input(entry, "image")
  end

  defp default_image(entry), do: Map.get(entry.metadata.default_models || %{}, "image")

  defp document_hint(entry, mode) do
    case get_in(entry.metadata.document_models || %{}, ["pdf", mode]) do
      false -> false
      value when is_binary(value) -> if String.trim(value) != "", do: String.trim(value)
      _ -> nil
    end
  end

  defp native?(entry) do
    protocol = Adapter.resolve_transport_type(entry.provider.type)

    "pdf" in List.wrap(entry.metadata.native_document_inputs) and
      protocol in [:anthropic, :google]
  end

  defp automatic_candidate(entry, model, snapshot, mode \\ :automatic, reference \\ nil) do
    # First preserve a raw saved ID, including provider-like slashes. Only a
    # redundant prefix matching this exact saved instance may be removed.
    reference = reference || format_ref(entry.provider.name, model)

    record =
      Enum.find(entry.models, &(&1.record.model == model)) ||
        Enum.find(entry.models, &(&1.record.model == local_model(entry.provider.name, model))) ||
        Enum.find(entry.models, &(&1.record.model == reference))

    if entry.available and record != nil and record.available do
      case materialize(reference, snapshot, mode, record.record.id) do
        {:ok, candidate} -> [candidate]
        _ -> []
      end
    else
      []
    end
  end

  defp format_ref(provider, model) do
    if String.starts_with?(model, provider <> "/"), do: model, else: provider <> "/" <> model
  end

  defp local_model(provider, model),
    do: String.trim(String.replace_prefix(model, provider <> "/", ""))

  defp unique(models), do: Enum.uniq_by(models, & &1.reference)
  defp digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  defp configured(nil), do: :absent

  defp configured(value) when is_binary(value) do
    if String.trim(value) == "", do: :absent, else: configured(%{"primary" => value})
  end

  defp configured(config) when is_map(config) do
    primary = Map.get(config, "primary")
    primary = if is_binary(primary), do: String.trim(primary), else: primary
    fallbacks = Map.get(config, "fallbacks", [])

    values =
      if is_nil(primary) or primary == "", do: fallbacks, else: [primary | List.wrap(fallbacks)]

    cond do
      primary in [nil, ""] and fallbacks == [] and
          Map.keys(config) -- ["primary", "fallbacks"] == [] ->
        :absent

      is_list(fallbacks) and length(values) in 1..10 and Enum.all?(values, &valid_reference?/1) ->
        {:ok, Enum.map(values, &String.trim/1) |> Enum.uniq()}

      true ->
        unavailable()
    end
  end

  defp configured(_), do: unavailable()

  defp override(references, nil), do: {:ok, references}

  defp override(references, value) when is_binary(value) do
    if String.trim(value) in references, do: {:ok, [String.trim(value)]}, else: unavailable()
  end

  defp override(_, _), do: unavailable()

  defp valid_reference?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 3..1152 and
        match?([_, _], String.split(String.trim(value), "/", parts: 2))

  defp materialize(reference, snapshot, mode, expected_id \\ nil) do
    with [provider, model] when provider != "" and model != "" <-
           String.split(reference, "/", parts: 2) do
      persisted =
        case Providers.get_by_name(provider) do
          {:ok, value} -> value
          _ -> nil
        end

      record =
        cond do
          persisted && expected_id ->
            Enum.find(snapshot.models, fn record ->
              record.id == expected_id and record.provider_id == persisted.id and
                reference in [provider <> "/" <> record.model, format_ref(provider, record.model)]
            end)

          persisted ->
            case Models.get_by_identity(persisted.id, model) do
              {:ok, value} -> value
              _ -> nil
            end

          true ->
            nil
        end

      # Automatic source refs can omit a self-prefix already present in a saved
      # raw ID. Keep the exact saved execution model and UUID in either spelling.
      model = if record, do: record.model, else: model

      runtime =
        if persisted && record && record.enabled,
          do: Providers.runtime_config(provider),
          else: {:error, :model_unavailable}

      available =
        case runtime do
          {:ok, config} -> Providers.ensure_model_runtime_available(config, model) == :ok
          _ -> false
        end

      entry = Enum.find(snapshot.providers, &(&1.provider.id == (persisted && persisted.id)))
      protocol = if persisted, do: Adapter.resolve_transport_type(persisted.type)
      family = if protocol == :openai_responses, do: :openai, else: protocol
      metadata = Enum.find(ModelRegistry.list(family), &(&1.id == model))
      output = if metadata, do: metadata.max_output_tokens, else: 4096

      {:ok,
       %{
         reference: reference,
         provider: provider,
         provider_id: if(persisted, do: persisted.id),
         model: model,
         model_id: if(record, do: record.id),
         protocol: if(protocol, do: Atom.to_string(protocol)),
         available: available,
         native:
           if(mode == :explicit,
             do: protocol in [:anthropic, :google],
             else: entry != nil and native?(entry)
           ),
         supports_images:
           if(mode == :active,
             do: true,
             else:
               if(record && not is_nil(record.input),
                 do: "image" in record.input,
                 else: metadata != nil and metadata.supports_images
               )
           ),
         selection_mode: mode,
         max_tokens: min(4096, output),
         fingerprint:
           :crypto.hash(
             :sha256,
             :erlang.term_to_binary(
               {persisted, runtime, record, mode, if(entry, do: entry.metadata),
                snapshot.revision},
               [:deterministic]
             )
           )
       }}
    else
      _ -> unavailable()
    end
  end

  defp unavailable,
    do:
      {:error,
       Error.new(
         :unsupported_capability,
         "PDF requires explicitly configured available analysis models"
       )}
end
