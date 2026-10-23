defmodule Synapsis.Agent.Tools.ResultProjection do
  @moduledoc """
  Projects public native tool results into durable, display-only host parts.

  The v1 projection is `%{"version" => 1, "result" => portable_native_map}`.
  Native fields and ordered content are retained without defining a backend
  result protocol. `content` on the part remains a legacy text view; media and
  structured values are available only in `projection`. Retaining a media block
  does not establish provider, resource-resolution or client-rendering support.

  Callers must provide public result data, never an execution context. Explicit
  auth/context keys and nonportable runtime values are rejected recursively;
  this cannot identify secrets embedded in arbitrary public strings. Runtime
  container keys are excluded even when their values are plain maps. Atom values
  are accepted only for supported `type`/`status` enums, plus nil and booleans;
  opaque metadata otherwise requires JSON values. Native payload budgets apply
  before JSON encoding. Runtime errors retain their class and portable details,
  use the existing safe display
  message, and omit their cause. Rejection proofs are checked by the native
  boundary and never persisted. No function dispatches or reconstructs a call.

  This is an opt-in projection for `Part.dump/load` and `Message.encode` turn
  persistence. It does not install a production runtime, provider or UI consumer.
  """

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AiProtocol.{Serialization, Validation}
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Part.ToolResult

  @denied_keys ~w(authorization proxyauthorization apikey accesstoken refreshtoken
    clientsecret password secret cookie setcookie backendcontext executioncontext providercontext
    authority operation resourceregistry workersupervisor)
  @limits Validation.default_limits()
  @enum_atoms %{
    "type" => ~w(text image reasoning tool_call refusal provider_state tool_result tool_error)a,
    "status" =>
      ~w(success error running completed incomplete failed cancelled interrupted shutdown yielded
        terminated created pending accepted reserved never_started active in_progress requested
        delivered cancel_requested granted denied updated applied confirmed retained published
        discovered revoked duplicate no_matches complete partial unknown paused blocked
        budget_limited usage_limited uncertain released done timed_out unknown_outcome
        deadline_exceeded output_limit_exceeded)a
  }

  @spec to_part(String.t(), term(), keyword()) :: {:ok, ToolResult.t()} | {:error, Error.t()}
  def to_part(tool_use_id, result, opts \\ [])

  def to_part(tool_use_id, result, opts)
      when is_binary(tool_use_id) and tool_use_id != "" and is_list(opts) do
    with true <- valid_opts?(opts),
         {:ok, native} <- native_result(result, tool_use_id, opts),
         {:ok, native} <- string_keys(native),
         native = Map.put_new(native, "is_error", false),
         true <- is_boolean(native["is_error"]),
         {:ok, native} <- public_error(native),
         {:ok, projection} <- portable(%{"version" => 1, "result" => native}),
         {:ok, content} <- legacy_text(projection["result"]) do
      {:ok,
       %ToolResult{
         tool_use_id: tool_use_id,
         content: content,
         is_error: native["is_error"],
         projection: projection
       }}
    else
      _ -> invalid()
    end
  end

  def to_part(_, _, _), do: invalid()

  @doc "Reads a checked display projection; legacy strings are projected without rewriting the part."
  @spec from_part(ToolResult.t()) :: {:ok, map()} | {:error, Error.t()}
  def from_part(%ToolResult{content: content, is_error: is_error, projection: nil})
      when is_binary(content) and is_boolean(is_error) do
    portable(%{
      "version" => 1,
      "result" => %{"content" => content, "is_error" => is_error}
    })
  end

  def from_part(%ToolResult{content: content, is_error: is_error, projection: projection})
      when is_binary(content) and is_boolean(is_error) and is_map(projection) and
             map_size(projection) == 2 do
    with true <- Map.keys(projection) |> Enum.sort() == ["result", "version"],
         %{"version" => 1, "result" => result} when is_map(result) <- projection,
         true <- result["is_error"] === is_error,
         {:ok, checked} <- portable(projection),
         {:ok, _text} <- legacy_text(checked["result"]) do
      {:ok, checked}
    else
      _ -> invalid()
    end
  end

  def from_part(_), do: invalid()

  defp native_result({:ok, result}, _, _) when is_map(result) and not is_struct(result),
    do: {:ok, result}

  defp native_result({:error, %Error{} = error}, _, _),
    do: {:ok, %{is_error: true, error: error}}

  defp native_result({:rejected, rejection}, tool_use_id, opts) do
    with operation when is_map(operation) <- Keyword.get(opts, :operation),
         true <- operation[:tool_call_id] === tool_use_id,
         {:ok, result} <- ToolEffects.validate_rejection(rejection, operation) do
      {:ok, result}
    else
      _ -> invalid()
    end
  end

  defp native_result(result, _, _) when is_map(result) and not is_struct(result),
    do: {:ok, result}

  defp native_result(_, _, _), do: invalid()

  defp valid_opts?([]), do: true

  defp valid_opts?([{:operation, operation}]) when is_map(operation) and not is_struct(operation),
    do: true

  defp valid_opts?(_), do: false

  defp public_error(%{"is_error" => true, "error" => %Error{} = error} = result) do
    with %Error{} <- Error.new(error.class),
         true <- is_map(error.details) and not is_struct(error.details),
         {:ok, message} <- ProviderMessages.tool_result_text(%{is_error: true, error: error}) do
      {:ok,
       Map.put(result, "error", %{
         "class" => Atom.to_string(error.class),
         "message" => message,
         "details" => error.details
       })}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp public_error(result), do: {:ok, result}

  defp legacy_text(%{"content" => content}) when is_binary(content), do: {:ok, content}

  defp legacy_text(%{"content" => content}) when is_list(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, texts} when is_binary(text) ->
        {:cont, {:ok, [text | texts]}}

      %{"type" => "text"}, _ ->
        {:halt, invalid()}

      _block, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp legacy_text(%{"is_error" => true, "error" => %{"message" => message}})
       when message in [
              "Tool denied by capability policy",
              "Tool registration changed",
              "Tool denied: tool is not in this run catalog"
            ],
       do: {:ok, message}

  defp legacy_text(%{"is_error" => true}), do: {:ok, "Tool execution failed"}
  defp legacy_text(_), do: {:ok, ""}

  # Bound and normalize before allocating JSON. Native validation remains the
  # final portable-value check; JSON is never used as a display fallback.
  defp portable(value) do
    with {:ok, portable, _budget} <- bounded_value(value, nil, 1, {0, 0}),
         :ok <- Validation.term(portable),
         {:ok, json} <- Serialization.to_json(portable),
         {:ok, portable} <- Serialization.from_json(json) do
      {:ok, portable}
    else
      _ -> invalid()
    end
  end

  defp bounded_value(value, field, depth, {nodes, bytes})
       when nodes < @limits.max_nodes do
    normalize_value(value, field, depth, {nodes + 1, bytes})
  end

  defp bounded_value(_, _, _, _), do: invalid()
  defp normalize_value(value, _, _, _) when is_struct(value), do: invalid()

  defp normalize_value(value, _, depth, budget)
       when is_map(value) and map_size(value) <= @limits.max_map_entries and
              depth <= @limits.max_depth do
    Enum.reduce_while(value, {:ok, %{}, budget}, fn {key, value}, {:ok, acc, budget} ->
      with true <- is_atom(key) or is_binary(key),
           key = to_string(key),
           {:ok, budget} <- bounded_string(key, budget),
           false <- denied_key?(key) or Map.has_key?(acc, key),
           {:ok, normalized, budget} <- bounded_value(value, key, depth + 1, budget) do
        {:cont, {:ok, Map.put(acc, key, normalized), budget}}
      else
        _ -> {:halt, invalid()}
      end
    end)
  end

  defp normalize_value(value, _, depth, budget)
       when is_list(value) and depth <= @limits.max_depth,
       do: bounded_list(value, depth, budget, 0, [])

  defp normalize_value(value, _, _, budget) when is_binary(value) do
    with {:ok, budget} <- bounded_string(value, budget), do: {:ok, value, budget}
  end

  defp normalize_value(value, _, _, budget) when is_number(value) or value in [nil, true, false],
    do: {:ok, value, budget}

  defp normalize_value(value, field, _, budget) when is_atom(value) do
    if value in Map.get(@enum_atoms, field, []) do
      value = Atom.to_string(value)
      with {:ok, budget} <- bounded_string(value, budget), do: {:ok, value, budget}
    else
      invalid()
    end
  end

  defp normalize_value(_, _, _, _), do: invalid()

  defp bounded_list([], _, budget, _, acc), do: {:ok, Enum.reverse(acc), budget}

  defp bounded_list([value | rest], depth, budget, count, acc)
       when count < @limits.max_list_length do
    with {:ok, normalized, budget} <- bounded_value(value, nil, depth + 1, budget) do
      bounded_list(rest, depth, budget, count + 1, [normalized | acc])
    end
  end

  defp bounded_list(_, _, _, _, _), do: invalid()

  defp bounded_string(value, {nodes, bytes})
       when byte_size(value) <= @limits.max_string_bytes and
              bytes + byte_size(value) <= @limits.max_bytes do
    if String.valid?(value), do: {:ok, {nodes, bytes + byte_size(value)}}, else: invalid()
  end

  defp bounded_string(_, _), do: invalid()

  defp string_keys(value)
       when is_map(value) and not is_struct(value) and map_size(value) <= @limits.max_map_entries do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(acc, key),
          do: {:halt, invalid()},
          else: {:cont, {:ok, Map.put(acc, key, value)}}

      _, _ ->
        {:halt, invalid()}
    end)
  end

  defp string_keys(_), do: invalid()

  defp denied_key?(key) do
    key |> String.downcase() |> String.replace(["-", "_", " "], "") |> then(&(&1 in @denied_keys))
  end

  defp invalid, do: {:error, Error.new(:malformed_result, "Tool result cannot be projected")}
end
