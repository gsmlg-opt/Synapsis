defmodule Synapsis.Workflow.Segment do
  @moduledoc """
  Pure inline workflow aggregate over the existing Machine and Value heap.

  The outer revision follows the data-owned continuation CAS. The nested v1
  effect journal remains empty in v1. Opt-in v2 retains native effect occurrences;
  v3 retains tagged native/state operations and their consumed prefix beside the
  actual waiting Machine. These transitions
  perform no IO; the trusted caller must acknowledge each complete snapshot
  before continuing. Runtime bindings, helper caches and host tokens are not state.
  """

  alias Synapsis.Workflow.{JSON, Journal, Machine, Pipeline, Value}

  @doc "Creates an inline segment with empty iterator input and rendering disabled."
  def new(pipeline), do: new(pipeline, [])

  @doc "Creates an inline aggregate with frozen source scopes and opt-in version 2 or 3."
  def new(pipeline, options) do
    with {:ok, version, source} <- source_options(pipeline, options),
         {:ok, program} <- Pipeline.parse(pipeline),
         {:ok, machine} <-
           Machine.new(program, %{"kind" => "iterator_items", "items" => []}, Value.new(), %{
             "render_output" => false
           }) do
      snapshot = %{
        "kind" => "workflow_segment",
        "version" => version,
        "revision" => 1,
        "source" => source,
        "machine" => machine,
        "journal" => if(version == 3, do: Journal.new_operations(), else: Journal.new())
      }

      snapshot =
        case version do
          2 -> Map.put(snapshot, "consumed_effects", 0)
          3 -> Map.put(snapshot, "consumed_operations", 0)
          _ -> snapshot
        end

      {:ok, snapshot}
    end
  end

  defp source_options(pipeline, options) do
    with true <- Keyword.keyword?(options),
         keys = Keyword.keys(options),
         true <-
           keys -- [:version, :file_scope, :state_scope] == [] and
             length(keys) == length(Enum.uniq(keys)),
         true <- not Keyword.has_key?(options, :version) or options[:version] in [2, 3],
         true <-
           not Keyword.has_key?(options, :state_scope) or
             (options[:version] === 3 and valid_state_scope?(options[:state_scope])),
         true <-
           not Keyword.has_key?(options, :file_scope) or valid_file_scope?(options[:file_scope]),
         source = %{"kind" => "inline", "pipeline" => pipeline},
         source =
           if(Keyword.has_key?(options, :file_scope),
             do: Map.put(source, "file_scope", options[:file_scope]),
             else: source
           ),
         source =
           if(Keyword.has_key?(options, :state_scope),
             do: Map.put(source, "state_scope", options[:state_scope]),
             else: source
           ) do
      {:ok, Keyword.get(options, :version, 1), source}
    else
      _ -> {:error, :invalid_segment_options}
    end
  end

  @doc "Validates a complete v2/v3 aggregate and exposes its versioned journal and cursor."
  def inspect_snapshot(
        %{
          "kind" => "workflow_segment",
          "version" => 3,
          "revision" => revision,
          "source" => source,
          "machine" => %{"version" => 1, "heap" => heap} = machine,
          "journal" => journal,
          "consumed_operations" => consumed
        } = snapshot
      )
      when map_size(snapshot) == 7 and is_integer(revision) and revision > 0 and
             is_map(heap) and is_integer(consumed) and consumed >= 0 do
    with true <- valid_operation_source?(source),
         {:ok, entries} <- Journal.inspect_operations(journal),
         true <- consumed <= length(entries) and length(entries) <= consumed + 1,
         true <- Enum.all?(Enum.take(entries, consumed), &(&1["state"] == "settled")),
         true <-
           Enum.all?(entries, fn entry ->
             entry["type"] != "state_operation" or
               entry["request"]["scope"] === source["state_scope"]
           end),
         true <- revision >= latest_revision(entries),
         true <-
           entries == [] or consumed < length(entries) or revision > latest_revision(entries),
         :ok <- outstanding_operation(machine, source, Enum.drop(entries, consumed), revision) do
      {:ok, %{journal: journal, consumed_operations: consumed}}
    else
      _ -> {:error, :invalid_segment_snapshot}
    end
  end

  def inspect_snapshot(
        %{
          "kind" => "workflow_segment",
          "version" => 2,
          "revision" => revision,
          "source" => %{"kind" => "inline", "pipeline" => pipeline} = source,
          "machine" => %{"version" => 1, "heap" => heap} = machine,
          "journal" => journal,
          "consumed_effects" => consumed
        } = snapshot
      )
      when map_size(snapshot) == 7 and is_integer(revision) and
             revision > 0 and is_binary(pipeline) and is_map(heap) and is_integer(consumed) and
             consumed >= 0 do
    with true <- valid_source?(source),
         {:ok, entries} <- Journal.inspect_snapshot(journal),
         true <- consumed <= length(entries) and length(entries) <= consumed + 1,
         true <- Enum.all?(Enum.take(entries, consumed), &(&1["state"] == "settled")),
         true <- revision >= latest_revision(entries),
         true <-
           entries == [] or consumed < length(entries) or revision > latest_revision(entries),
         :ok <- outstanding(machine, Enum.drop(entries, consumed), revision) do
      {:ok, %{journal: journal, consumed_effects: consumed}}
    else
      _ -> {:error, :invalid_segment_snapshot}
    end
  end

  def inspect_snapshot(_snapshot), do: {:error, :invalid_segment_snapshot}

  def prepare_operation(snapshot, next_revision, type, encoded_request, origin) do
    with {:ok, %{journal: journal, consumed_operations: consumed}} <- inspect_snapshot(snapshot),
         true <- consumed == length(journal["operations"]),
         true <- next_revision === snapshot["revision"] + 1,
         :ok <- bind_operation(snapshot["machine"], snapshot["source"], type, encoded_request),
         {:ok, journal} <-
           Journal.prepare_operation(journal, next_revision, type, encoded_request, origin) do
      update_effect(snapshot, journal, next_revision)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_segment_transition}
    end
  end

  def settle_operation(snapshot, pending_revision, next_revision, reference) do
    with {:ok, %{journal: journal, consumed_operations: _}} <- inspect_snapshot(snapshot),
         true <- pending_revision === snapshot["revision"],
         {:ok, journal} <-
           Journal.settle_operation(journal, pending_revision, next_revision, reference) do
      update_effect(snapshot, journal, next_revision)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_segment_transition}
    end
  end

  def consume_operation_observed(snapshot, next_revision, ack) do
    with {:ok, %{journal: journal, consumed_operations: consumed}} <- inspect_snapshot(snapshot),
         [%{"state" => "settled", "request" => request}] <-
           Enum.drop(journal["operations"], consumed),
         true <- is_map(ack) and ack["id"] === request["correlation"]["request_id"],
         true <- next_revision === snapshot["revision"] + 1,
         {{:continue, machine}, observations} <-
           Machine.advance_observed(snapshot["machine"], ack),
         next =
           Map.merge(snapshot, %{
             "revision" => next_revision,
             "machine" => machine,
             "consumed_operations" => consumed + 1
           }),
         {:ok, _} <- inspect_snapshot(next) do
      {{:ok, next}, observations}
    else
      {{:error, reason, _}, observations} -> {{:error, reason}, observations}
      {:error, reason} -> {{:error, reason}, []}
      _ -> {{:error, :invalid_segment_transition}, []}
    end
  end

  def advance_observed(snapshot, event \\ nil) do
    with :ok <- validate(snapshot) do
      {transition, observations} = Machine.advance_observed(snapshot["machine"], event)
      {replace(snapshot, transition), observations}
    else
      {:error, reason} -> {{:error, reason, snapshot}, []}
    end
  end

  def resume_observed(snapshot, response_json) do
    with :ok <- validate(snapshot),
         :ok <- consumed_boundary(snapshot),
         {:ok, response, heap} <- Value.decode_json(response_json, snapshot["machine"]["heap"]) do
      case Machine.resume_observed(Map.put(snapshot["machine"], "heap", heap), response) do
        {{:ok, machine}, observations} ->
          {{:ok, Map.put(snapshot, "machine", machine)}, observations}

        {error, observations} ->
          {error, observations}
      end
    else
      error -> {error, []}
    end
  end

  @doc "Binds an actual pending invoke to an explicitly supplied native file request."
  def prepare_effect(snapshot, next_revision, encoded_request, origin) do
    with {:ok, %{journal: journal, consumed_effects: consumed}} <- inspect_snapshot(snapshot),
         true <- consumed == length(journal["effects"]),
         true <- next_revision === snapshot["revision"] + 1,
         {:ok, request} <- Journal.decode_request(encoded_request),
         :ok <- bind_request(snapshot["machine"], request),
         {:ok, journal} <- Journal.prepare(journal, next_revision, encoded_request, origin) do
      update_effect(snapshot, journal, next_revision)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_segment_transition}
    end
  end

  @doc "Retains the waiting Machine while settling its one outstanding occurrence."
  def settle_effect(snapshot, pending_revision, next_revision, reference) do
    with {:ok, %{journal: journal}} <- inspect_snapshot(snapshot),
         true <- pending_revision === snapshot["revision"],
         {:ok, journal} <- Journal.settle(journal, pending_revision, next_revision, reference) do
      update_effect(snapshot, journal, next_revision)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_segment_transition}
    end
  end

  @doc "Imports raw ordered JSON and advances Machine plus the consumed cursor together."
  def consume_effect(snapshot, next_revision, request_id, response_json) do
    with {:ok, %{journal: journal, consumed_effects: consumed}} <- inspect_snapshot(snapshot),
         [%{"state" => "settled", "request" => request}] <-
           Enum.drop(journal["effects"], consumed),
         true <- request["correlation"]["request_id"] === request_id,
         true <- next_revision === snapshot["revision"] + 1,
         {:continue, machine} <-
           Machine.advance(snapshot["machine"], %{
             "id" => request_id,
             "response_json" => response_json
           }),
         next =
           Map.merge(snapshot, %{
             "revision" => next_revision,
             "machine" => machine,
             "consumed_effects" => consumed + 1
           }),
         {:ok, _} <- inspect_snapshot(next) do
      {:ok, next}
    else
      {:error, reason, _machine} -> {:error, reason}
      {:error, _} = error -> error
      _ -> {:error, :invalid_segment_transition}
    end
  end

  @doc "Advances one pure transition, retaining the complete aggregate in the final position."
  def advance(snapshot) do
    with :ok <- validate(snapshot) do
      replace(snapshot, Machine.advance(snapshot["machine"]))
    else
      {:error, reason} -> {:error, reason, snapshot}
    end
  end

  @doc "Imports a submitted JSON response into the retained heap before semantic resume."
  def resume(snapshot, response_json) do
    with :ok <- validate(snapshot),
         :ok <- consumed_boundary(snapshot),
         {:ok, response, heap} <- Value.decode_json(response_json, snapshot["machine"]["heap"]),
         {:ok, machine} <- Machine.resume(Map.put(snapshot["machine"], "heap", heap), response) do
      {:ok, Map.put(snapshot, "machine", machine)}
    end
  end

  @doc "True only after resumed saved-schema/response validation, before the first constructor."
  def resume_ready?(%{
        "kind" => "workflow_segment",
        "version" => 1,
        "machine" => %{
          "phase" => "construct",
          "segment" => segment,
          "frames" => [],
          "stack" => [%{"op" => "construct"}]
        }
      })
      when is_integer(segment) and segment > 0,
      do: true

  def resume_ready?(%{"version" => version} = snapshot) when version in [2, 3] do
    with :ok <- validate(snapshot),
         :ok <- consumed_boundary(snapshot) do
      resume_ready?(Map.put(snapshot, "version", 1))
    else
      _ -> false
    end
  end

  def resume_ready?(_snapshot), do: false

  @doc "Projects the normalized public envelope without internal checkpoint or heap data."
  def envelope(snapshot, token) do
    with {:ok, %{envelope: envelope}} <- render_envelope(snapshot, token) do
      {:ok, envelope}
    end
  end

  @doc "Renders the normalized envelope as ordered two-space public JSON and its decoded value."
  def render_envelope(snapshot, token) do
    with :ok <- validate(snapshot),
         :ok <- consumed_boundary(snapshot),
         {:ok, value, heap} <- project(snapshot["machine"], token),
         {:ok, text} <- JSON.pretty(value, heap),
         {:ok, envelope} <- Jason.decode(text) do
      {:ok, %{text: text, envelope: envelope}}
    end
  end

  defp project(%{"phase" => "checkpoint", "checkpoint" => checkpoint, "heap" => heap}, token)
       when is_binary(token) and byte_size(token) > 0 do
    request = checkpoint["request"]

    entries =
      ~w(prompt responseSchema defaults subject)
      |> Enum.map(&{&1, Value.object_get(request, &1, heap)})
      |> Enum.reject(fn {_key, value} -> value == Value.undefined() end)

    {public_request, heap} =
      Value.object(
        entries ++ [{"resumeToken", string(token)}, {"type", string("input_request")}],
        heap
      )

    {output, heap} = Value.array([], heap)
    normalized("needs_input", output, [{"requiresInput", public_request}], heap)
  end

  defp project(%{"phase" => "completed", "items" => items, "heap" => heap}, _token) do
    {output, heap} = Value.array(items, heap)

    normalized("ok", output, [], heap)
  end

  defp project(_machine, _token), do: {:error, :not_at_segment_boundary}

  defp normalized(status, output, extra, heap) do
    {envelope, heap} =
      Value.object(
        [
          {"ok", %{"type" => "boolean", "value" => true}},
          {"status", string(status)},
          {"output", output},
          {"requiresApproval", %{"type" => "null"}}
        ] ++ extra,
        heap
      )

    {:ok, envelope, heap}
  end

  defp string(value), do: %{"type" => "string", "value" => value}

  defp replace(snapshot, {:continue, machine}),
    do: {:continue, Map.put(snapshot, "machine", machine)}

  defp replace(snapshot, {kind, value, machine})
       when kind in [:request, :checkpoint, :complete, :error],
       do: {kind, value, Map.put(snapshot, "machine", machine)}

  defp update_effect(snapshot, journal, revision) do
    next = Map.merge(snapshot, %{"journal" => journal, "revision" => revision})
    with {:ok, _} <- inspect_snapshot(next), do: {:ok, next}
  end

  defp bind_request(
         %{
           "phase" => "request",
           "segment" => segment,
           "pending_request" => %{
             "kind" => "invoke",
             "id" => id,
             "segment" => segment,
             "body" => body
           }
         },
         request
       ) do
    # This internal binding chooses no action, session or transport mapping.
    # The admitted caller supplies the exact native tool name and arguments.
    with true <-
           request.correlation.request_id === id and request.correlation.segment === segment,
         {:ok, %{"tool" => tool, "args" => arguments}} <- Jason.decode(body),
         true <- tool === request.target.tool_name and arguments === request.target.arguments do
      :ok
    else
      _ -> {:error, :invalid_segment_effect_request}
    end
  end

  defp bind_request(_machine, _request), do: {:error, :invalid_segment_effect_request}

  defp outstanding(_machine, [], _revision), do: :ok

  defp outstanding(machine, [entry], revision) do
    with {:ok, request} <- Journal.decode_request(entry["request"]),
         true <- revision === (entry["settled_revision"] || entry["pending_revision"]),
         :ok <- bind_request(machine, request) do
      :ok
    else
      _ -> {:error, :invalid_segment_snapshot}
    end
  end

  defp outstanding_operation(_machine, _source, [], _revision), do: :ok

  defp outstanding_operation(machine, source, [entry], revision) do
    type =
      case entry["type"] do
        "native_effect" -> :native_effect
        "state_operation" -> :state_operation
      end

    with true <- revision === (entry["settled_revision"] || entry["pending_revision"]),
         :ok <- bind_operation(machine, source, type, entry["request"]),
         do: :ok
  end

  defp bind_operation(machine, _source, :native_effect, encoded) do
    with {:ok, request} <- Journal.decode_request(encoded), do: bind_request(machine, request)
  end

  defp bind_operation(
         %{"phase" => "request", "segment" => segment, "pending_request" => semantic},
         source,
         :state_operation,
         encoded
       ) do
    with {:ok, request} <- Journal.decode_state_request(encoded),
         true <- request.semantic === semantic and request.scope === source["state_scope"],
         true <-
           request.correlation.segment === segment and
             request.correlation.request_id === semantic["id"] do
      :ok
    else
      _ -> {:error, :invalid_segment_state_request}
    end
  end

  defp bind_operation(_, _, _, _), do: {:error, :invalid_segment_operation_request}

  defp latest_revision([]), do: 1

  defp latest_revision(entries),
    do: List.last(entries)["settled_revision"] || List.last(entries)["pending_revision"]

  defp consumed_boundary(%{"version" => 1}), do: :ok

  defp consumed_boundary(%{
         "version" => 3,
         "journal" => journal,
         "consumed_operations" => consumed
       }) do
    if consumed == length(journal["operations"]),
      do: :ok,
      else: {:error, :unconsumed_segment_operation}
  end

  defp consumed_boundary(%{"version" => 2, "journal" => journal, "consumed_effects" => consumed}) do
    if consumed == length(journal["effects"]), do: :ok, else: {:error, :unconsumed_segment_effect}
  end

  defp validate(%{"version" => version} = snapshot) when version in [2, 3] do
    with {:ok, _} <- inspect_snapshot(snapshot), do: :ok
  end

  defp validate(
         %{
           "kind" => "workflow_segment",
           "version" => 1,
           "revision" => revision,
           "source" => %{"kind" => "inline", "pipeline" => pipeline} = source,
           "machine" => %{"version" => 1, "heap" => heap},
           "journal" => journal
         } = snapshot
       )
       when map_size(snapshot) == 6 and is_integer(revision) and
              revision > 0 and is_binary(pipeline) and is_map(heap) do
    cond do
      not valid_source?(source) -> {:error, :invalid_segment_snapshot}
      journal != Journal.new() -> {:error, :invalid_segment_journal}
      true -> :ok
    end
  end

  defp validate(_snapshot), do: {:error, :invalid_segment_snapshot}

  defp valid_source?(%{"kind" => "inline", "pipeline" => pipeline} = source)
       when is_binary(pipeline) do
    case map_size(source) do
      2 -> true
      3 -> Map.has_key?(source, "file_scope") and valid_file_scope?(source["file_scope"])
      _ -> false
    end
  end

  defp valid_source?(_source), do: false

  defp valid_operation_source?(%{"kind" => "inline", "pipeline" => pipeline} = source) do
    is_binary(pipeline) and Map.keys(source) -- ~w(kind pipeline file_scope state_scope) == [] and
      (not Map.has_key?(source, "file_scope") or valid_file_scope?(source["file_scope"])) and
      (not Map.has_key?(source, "state_scope") or valid_state_scope?(source["state_scope"]))
  end

  defp valid_operation_source?(_), do: false

  defp valid_state_scope?(
         %{
           "kind" => "trusted_internal",
           "project_root" => root,
           "state_dir" => dir,
           "process_cwd" => cwd
         } = scope
       )
       when map_size(scope) == 4 and is_binary(root) and is_binary(dir) and is_binary(cwd) do
    Enum.all?([root, dir, cwd], fn path ->
      path != "" and String.valid?(path) and not String.contains?(path, <<0>>)
    end) and
      Path.type(root) == :absolute and Path.expand(root) == root and Path.type(cwd) == :absolute and
      Path.expand(cwd) == cwd
  end

  defp valid_state_scope?(_), do: false

  defp valid_file_scope?(%{"project_root" => root, "cwd" => cwd} = scope)
       when map_size(scope) == 2 and is_binary(root) and is_binary(cwd) do
    clean_path?(root) and clean_path?(cwd) and Path.type(root) == :absolute and
      Path.expand(root) == root and Path.type(cwd) == :relative and
      Path.relative_to(Path.expand(cwd, root), root) == cwd
  end

  defp valid_file_scope?(_scope), do: false

  defp clean_path?(path),
    do:
      path != "" and String.valid?(path) and not String.contains?(path, ["\\", <<0>>]) and
        ".." not in Path.split(path)
end
