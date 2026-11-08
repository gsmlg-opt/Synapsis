defmodule Synapsis.Workflow.Journal do
  @moduledoc """
  Pure workflow journal transitions with an opt-in ordered operation union.

  Entries preserve exact JSON requests and origin scalars. A settled entry holds
  a reference to native evidence; neither that reference nor a pending entry is
  authority to execute an effect. Machine state and result consumption are not
  part of journal v1. Journal v2 tags native effects and state operations in one
  ordered list; the enclosing Segment owns their consumed prefix.
  """

  @limits ~w(timeout_ms effect_timeout_ms commit_timeout_ms cleanup_timeout_ms output_limit work)a
  @targets ~w(synapsis::read synapsis::write synapsis::edit synapsis::ls)
  @origin_strings ~w(namespace parent_run_id parent_invocation_id caller resource_owner_id)
  @origin_integers ~w(store_incarnation parent_incarnation resource_incarnation)

  alias Synapsis.Workflow.Value

  def new, do: %{"kind" => "workflow", "version" => 1, "effects" => []}

  def new_operations, do: %{"kind" => "workflow", "version" => 2, "operations" => []}

  def encode_state_request(request) do
    with true <- keys?(request, [:correlation, :semantic, :scope, :target]),
         c = request.correlation,
         true <- keys?(c, [:workflow_id, :request_id, :segment]),
         true <- uuid?(c.workflow_id) and nonempty?(c.request_id),
         true <- is_integer(c.segment) and c.segment >= 0,
         true <- state_semantic?(request.semantic),
         true <- request.semantic["id"] === c.request_id,
         true <- state_scope?(request.scope),
         target = request.target,
         true <- keys?(target, [:lexical_path, :absolute_path, :relative_path]),
         true <- Enum.all?(Map.values(target), &nonempty?/1),
         true <- Path.type(target.absolute_path) == :absolute,
         true <- Path.expand(target.absolute_path) == target.absolute_path,
         true <- Path.type(target.relative_path) == :relative do
      {:ok,
       %{
         "correlation" => %{
           "workflow_id" => c.workflow_id,
           "request_id" => c.request_id,
           "segment" => c.segment
         },
         "semantic" => request.semantic,
         "scope" => request.scope,
         "target" => %{
           "lexical_path" => target.lexical_path,
           "absolute_path" => target.absolute_path,
           "relative_path" => target.relative_path
         }
       }}
    else
      _ -> {:error, :invalid_state_request}
    end
  end

  def decode_state_request(request) do
    with true <- keys?(request, ~w(correlation semantic scope target)),
         c = request["correlation"],
         true <- keys?(c, ~w(workflow_id request_id segment)),
         t = request["target"],
         true <- keys?(t, ~w(lexical_path absolute_path relative_path)),
         decoded = %{
           correlation: %{
             workflow_id: c["workflow_id"],
             request_id: c["request_id"],
             segment: c["segment"]
           },
           semantic: request["semantic"],
           scope: request["scope"],
           target: %{
             lexical_path: t["lexical_path"],
             absolute_path: t["absolute_path"],
             relative_path: t["relative_path"]
           }
         },
         {:ok, ^request} <- encode_state_request(decoded) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_state_request}
    end
  end

  def prepare_operation(journal, revision, type, encoded, origin) do
    with {:ok, entries} <- inspect_operations(journal),
         true <- type in [:native_effect, :state_operation],
         {:ok, _} <- operation_request(Atom.to_string(type), encoded),
         entry = %{
           "type" => Atom.to_string(type),
           "state" => "pending",
           "pending_revision" => revision,
           "request" => encoded,
           "origin" => origin
         },
         next = %{journal | "operations" => entries ++ [entry]},
         {:ok, _} <- inspect_operations(next) do
      {:ok, next}
    else
      _ -> {:error, :invalid_journal_transition}
    end
  end

  def settle_operation(journal, pending_revision, revision, reference) do
    with {:ok, entries} <- inspect_operations(journal),
         %{"state" => "pending", "pending_revision" => ^pending_revision} = entry <-
           List.last(entries),
         true <- revision === pending_revision + 1,
         settled =
           Map.merge(entry, %{
             "state" => "settled",
             "settled_revision" => revision,
             "receipt" => reference
           }),
         next = %{journal | "operations" => Enum.drop(entries, -1) ++ [settled]},
         {:ok, _} <- inspect_operations(next) do
      {:ok, next}
    else
      _ -> {:error, :invalid_journal_transition}
    end
  end

  def inspect_operations(journal) do
    with true <- keys?(journal, ~w(kind version operations)),
         %{"kind" => "workflow", "version" => 2, "operations" => entries} <- journal,
         true <- is_list(entries),
         :ok <- inspect_operations(entries, 1, MapSet.new(), nil) do
      {:ok, entries}
    else
      _ -> {:error, :invalid_journal_snapshot}
    end
  end

  defp inspect_operations([], _revision, _seen, _workflow), do: :ok

  defp inspect_operations([entry | rest], previous, seen, workflow) do
    with true <- is_map(entry) and not is_struct(entry),
         {:ok, request} <- operation_request(entry["type"], entry["request"]),
         true <- is_nil(workflow) or workflow === request.correlation.workflow_id,
         key = occurrence(request),
         false <- MapSet.member?(seen, key),
         true <- origin?(entry["origin"]),
         true <- positive?(entry["pending_revision"]) and entry["pending_revision"] > previous,
         {:ok, revision} <- operation_revision(entry, request, rest) do
      inspect_operations(rest, revision, MapSet.put(seen, key), request.correlation.workflow_id)
    else
      _ -> {:error, :invalid_journal_snapshot}
    end
  end

  defp inspect_operations(_, _, _, _), do: {:error, :invalid_journal_snapshot}

  defp operation_request("native_effect", request), do: decode_request(request)
  defp operation_request("state_operation", request), do: decode_state_request(request)
  defp operation_request(_, _), do: {:error, :invalid_operation_type}

  defp operation_revision(%{"type" => "native_effect"} = entry, request, rest),
    do: entry_revision(Map.delete(entry, "type"), request, rest)

  defp operation_revision(%{"state" => "pending"} = entry, _request, []) do
    if keys?(entry, ~w(type state pending_revision request origin)),
      do: {:ok, entry["pending_revision"]},
      else: {:error, :invalid_journal_snapshot}
  end

  defp operation_revision(%{"state" => "settled"} = entry, request, _rest) do
    reference = entry["receipt"]

    expected = %{
      "kind" => "workflow_state_receipt",
      "version" => 1,
      "fact_id" =>
        request.correlation.workflow_id <>
          ":state:" <> Integer.to_string(entry["pending_revision"]),
      "namespace" => entry["origin"]["namespace"],
      "incarnation" => entry["origin"]["store_incarnation"]
    }

    if keys?(entry, ~w(type state pending_revision request origin settled_revision receipt)) and
         entry["settled_revision"] === entry["pending_revision"] + 1 and reference === expected,
       do: {:ok, entry["settled_revision"]},
       else: {:error, :invalid_journal_snapshot}
  end

  defp operation_revision(_, _, _), do: {:error, :invalid_journal_snapshot}

  defp state_semantic?(
         %{"id" => id, "kind" => kind, "key" => key, "stage_index" => index} = semantic
       ) do
    fields =
      if kind == "state_get",
        do: ~w(id kind key stage_index),
        else: ~w(id kind key stage_index value text)

    keys?(semantic, fields) and kind in ["state_get", "state_set", "state_diff"] and nonempty?(id) and
      is_integer(index) and index >= 0 and state_key?(key) and json?(semantic) and
      (kind == "state_get" or is_binary(semantic["text"]))
  end

  defp state_semantic?(_), do: false

  defp state_key?(%{"type" => "string", "value" => value} = key),
    do: map_size(key) == 2 and is_binary(value) and String.valid?(value)

  defp state_key?(%{"type" => "string", "utf16le" => encoded} = key)
       when map_size(key) == 2 and is_binary(encoded) do
    with {:ok, raw} <- Base.decode64(encoded),
         true <- Base.encode64(raw) === encoded and rem(byte_size(raw), 2) == 0 do
      Value.from_utf16le(raw) === key
    else
      _ -> false
    end
  end

  defp state_key?(key), do: (is_binary(key) or is_boolean(key) or is_number(key)) and json?(key)

  defp state_scope?(
         %{
           "kind" => "trusted_internal",
           "project_root" => root,
           "state_dir" => dir,
           "process_cwd" => cwd
         } = scope
       ) do
    keys?(scope, ~w(kind project_root state_dir process_cwd)) and
      Enum.all?([root, dir, cwd], &nonempty?/1) and
      Path.type(root) == :absolute and Path.expand(root) == root and
      Path.type(cwd) == :absolute and Path.expand(cwd) == cwd
  end

  defp state_scope?(_), do: false

  def encode_request(request) do
    with true <- keys?(request, [:correlation, :target, :limits]),
         correlation = request.correlation,
         true <- keys?(correlation, [:workflow_id, :request_id, :segment]),
         true <- uuid?(correlation.workflow_id) and nonempty?(correlation.request_id),
         true <- is_integer(correlation.segment) and correlation.segment >= 0,
         target = request.target,
         true <- keys?(target, [:tool_name, :tool_revision, :arguments]),
         true <- target.tool_name in @targets and positive?(target.tool_revision),
         true <- is_map(target.arguments) and not is_struct(target.arguments),
         true <- json?(target.arguments),
         limits = request.limits,
         true <- keys?(limits, @limits),
         true <- Enum.all?(@limits, &positive?(limits[&1])),
         true <-
           Enum.all?(
             ~w(timeout_ms effect_timeout_ms commit_timeout_ms)a,
             &(limits[&1] <= 3_600_000)
           ),
         true <- limits.cleanup_timeout_ms <= 60_000 do
      {:ok,
       %{
         "correlation" => %{
           "workflow_id" => correlation.workflow_id,
           "request_id" => correlation.request_id,
           "segment" => correlation.segment
         },
         "target" => %{
           "tool_name" => target.tool_name,
           "tool_revision" => target.tool_revision,
           "arguments" => target.arguments
         },
         "limits" => %{
           "timeout_ms" => limits.timeout_ms,
           "effect_timeout_ms" => limits.effect_timeout_ms,
           "commit_timeout_ms" => limits.commit_timeout_ms,
           "cleanup_timeout_ms" => limits.cleanup_timeout_ms,
           "output_limit" => limits.output_limit,
           "work" => limits.work
         }
       }}
    else
      _ -> {:error, :invalid_effect_request}
    end
  end

  def decode_request(request) do
    with true <- keys?(request, ~w(correlation target limits)),
         correlation = request["correlation"],
         true <- keys?(correlation, ~w(workflow_id request_id segment)),
         target = request["target"],
         true <- keys?(target, ~w(tool_name tool_revision arguments)),
         limits = request["limits"],
         true <- keys?(limits, Enum.map(@limits, &Atom.to_string/1)),
         decoded = %{
           correlation: %{
             workflow_id: correlation["workflow_id"],
             request_id: correlation["request_id"],
             segment: correlation["segment"]
           },
           target: %{
             tool_name: target["tool_name"],
             tool_revision: target["tool_revision"],
             arguments: target["arguments"]
           },
           limits: %{
             timeout_ms: limits["timeout_ms"],
             effect_timeout_ms: limits["effect_timeout_ms"],
             commit_timeout_ms: limits["commit_timeout_ms"],
             cleanup_timeout_ms: limits["cleanup_timeout_ms"],
             output_limit: limits["output_limit"],
             work: limits["work"]
           }
         },
         {:ok, ^request} <- encode_request(decoded) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_effect_request}
    end
  end

  def prepare(snapshot, next_revision, request, origin) do
    with {:ok, entries} <- inspect_snapshot(snapshot),
         {:ok, decoded} <- decode_request(request),
         true <- origin?(origin),
         true <- positive?(next_revision) and next_revision > latest_revision(entries),
         true <- Enum.all?(entries, &(&1["state"] == "settled")),
         true <-
           Enum.all?(
             entries,
             &(&1["request"]["correlation"]["workflow_id"] === decoded.correlation.workflow_id)
           ),
         key = occurrence(decoded),
         true <- Enum.all?(entries, &(entry_occurrence(&1) !== key)) do
      entry = %{
        "state" => "pending",
        "pending_revision" => next_revision,
        "request" => request,
        "origin" => origin
      }

      {:ok, %{snapshot | "effects" => entries ++ [entry]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_journal_transition}
    end
  end

  def settle(snapshot, pending_revision, next_revision, reference) do
    with {:ok, entries} <- inspect_snapshot(snapshot),
         %{"state" => "pending", "pending_revision" => ^pending_revision} = pending <-
           List.last(entries),
         true <- next_revision === pending_revision + 1,
         true <- reference?(reference),
         {:ok, request} <- decode_request(pending["request"]),
         true <-
           reference["fact_id"] ===
             request.correlation.workflow_id <> ":" <> Integer.to_string(pending_revision),
         true <- reference["namespace"] === pending["origin"]["namespace"],
         true <- reference["incarnation"] === pending["origin"]["store_incarnation"] do
      settled =
        Map.merge(pending, %{
          "state" => "settled",
          "settled_revision" => next_revision,
          "receipt" => reference
        })

      {:ok, %{snapshot | "effects" => Enum.drop(entries, -1) ++ [settled]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_journal_transition}
    end
  end

  def inspect_snapshot(snapshot) do
    with true <- keys?(snapshot, ~w(kind version effects)),
         %{"kind" => "workflow", "version" => 1, "effects" => entries} <- snapshot,
         true <- is_list(entries),
         {:ok, _, _, _} <- inspect_entries(entries, 1, MapSet.new(), nil) do
      {:ok, entries}
    else
      _ -> {:error, :invalid_journal_snapshot}
    end
  end

  defp inspect_entries([], revision, seen, workflow), do: {:ok, revision, seen, workflow}

  defp inspect_entries([entry | rest], previous, seen, workflow) do
    with true <- is_map(entry) and not is_struct(entry),
         {:ok, request} <- decode_request(entry["request"]),
         true <- is_nil(workflow) or workflow === request.correlation.workflow_id,
         key = occurrence(request),
         false <- MapSet.member?(seen, key),
         true <- origin?(entry["origin"]),
         pending = entry["pending_revision"],
         true <- positive?(pending) and pending > previous,
         {:ok, revision} <- entry_revision(entry, request, rest) do
      inspect_entries(rest, revision, MapSet.put(seen, key), request.correlation.workflow_id)
    else
      _ -> {:error, :invalid_journal_snapshot}
    end
  end

  defp inspect_entries(_, _, _, _), do: {:error, :invalid_journal_snapshot}

  defp entry_revision(%{"state" => "pending"} = entry, _request, []) do
    if keys?(entry, ~w(state pending_revision request origin)),
      do: {:ok, entry["pending_revision"]},
      else: {:error, :invalid_journal_snapshot}
  end

  defp entry_revision(%{"state" => "settled"} = entry, request, _rest) do
    reference = entry["receipt"]

    if keys?(entry, ~w(state pending_revision request origin settled_revision receipt)) and
         entry["settled_revision"] === entry["pending_revision"] + 1 and reference?(reference) and
         reference["fact_id"] ===
           request.correlation.workflow_id <> ":" <> Integer.to_string(entry["pending_revision"]) and
         reference["namespace"] === entry["origin"]["namespace"] and
         reference["incarnation"] === entry["origin"]["store_incarnation"],
       do: {:ok, entry["settled_revision"]},
       else: {:error, :invalid_journal_snapshot}
  end

  defp entry_revision(_, _, _), do: {:error, :invalid_journal_snapshot}

  defp origin?(origin),
    do:
      keys?(origin, @origin_strings ++ @origin_integers) and
        Enum.all?(@origin_strings, &nonempty?(origin[&1])) and
        Enum.all?(@origin_integers, &positive?(origin[&1]))

  defp reference?(reference),
    do:
      keys?(reference, ~w(kind fact_id namespace run_id incarnation final_revision)) and
        reference["kind"] === "workflow_effect_receipt" and
        Enum.all?(~w(fact_id namespace run_id), &nonempty?(reference[&1])) and
        positive?(reference["incarnation"]) and positive?(reference["final_revision"])

  defp latest_revision([]), do: 1

  defp latest_revision(entries),
    do: List.last(entries)["settled_revision"] || List.last(entries)["pending_revision"]

  defp occurrence(request), do: {request.correlation.segment, request.correlation.request_id}

  defp entry_occurrence(entry) do
    correlation = entry["request"]["correlation"]
    {correlation["segment"], correlation["request_id"]}
  end

  defp keys?(value, keys),
    do: is_map(value) and not is_struct(value) and Enum.sort(Map.keys(value)) === Enum.sort(keys)

  defp positive?(value), do: is_integer(value) and value > 0

  defp nonempty?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp uuid?(value), do: is_binary(value) and match?({:ok, ^value}, Ecto.UUID.cast(value))

  defp json?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)

  defp json?([]), do: true
  defp json?([head | tail]), do: json?(head) and json_list?(tail)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_integer(value) or is_boolean(value) or is_nil(value), do: true

  defp json?(value) when is_float(value),
    do: value >= -1.7976931348623157e308 and value <= 1.7976931348623157e308

  defp json?(_), do: false
  defp json_list?([]), do: true
  defp json_list?([head | tail]), do: json?(head) and json_list?(tail)
  defp json_list?(_), do: false
end
