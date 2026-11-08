defmodule Synapsis.Provider.Decision do
  @moduledoc """
  Bounded caller-supplied evidence and results for native Decisions.

  The generic V2 contract supports boolean, choice, score, tags, box and sort
  questions with tagged text/JSON/image/list evidence. Each native provider
  separately admits the subset its explicit route supports. Legacy arguments
  retain the three original question kinds with text/JSON evidence.

  Native tool arguments are semantic maps. Object keys receive a deterministic
  order before wire arrays and JSON text are produced; original JSON insertion
  order is unavailable. Arrays and literal text remain unchanged. JSON numbers
  use Jason's finite Elixir encoding; this is not a general ECMAScript stringify
  compatibility implementation.
  """

  @json_bytes 1_048_576
  @image_bytes 4 * @json_bytes
  @envelope_bytes 4 * div(@image_bytes + 2, 3) + @json_bytes + 256

  def schema do
    entry = %{
      "anyOf" => [
        %{"type" => "string"},
        %{"type" => "object", "additionalProperties" => true},
        %{"type" => "array", "items" => %{}},
        %{"type" => "null"}
      ]
    }

    questions = [
      question_schema(
        "boolean",
        %{
          "anyOf" => [
            %{"type" => "null"},
            %{
              "type" => "object",
              "properties" => %{"true" => entry, "false" => entry},
              "additionalProperties" => false
            }
          ]
        },
        entry
      ),
      question_schema(
        "choice",
        %{
          "type" => "object",
          "minProperties" => 2,
          "additionalProperties" => entry
        },
        entry
      ),
      question_schema("score", %{"type" => "array", "minItems" => 2, "items" => entry}, entry),
      question_schema(
        "tags",
        %{"type" => "object", "minProperties" => 1, "additionalProperties" => entry},
        entry
      ),
      %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["type", "instructions"],
        "properties" => %{
          "type" => %{"const" => "box"},
          "instructions" => %{"anyOf" => Enum.reject(entry["anyOf"], &(&1["type"] == "null"))}
        }
      },
      %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["type"],
        "properties" => %{"type" => %{"const" => "sort"}, "instructions" => entry}
      }
    ]

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["state", "questions"],
      "properties" => %{
        "contractVersion" => %{"type" => "integer", "const" => 2},
        "state" =>
          Map.put(
            entry,
            "description",
            "Omit contractVersion for legacy text/JSON. With contractVersion 2 supply {type: text, text}, {type: json, value}, {type: image, dataUri, text?}, or {type: list, items: [{id, content}]}. Inline PNG/JPEG/WebP only, at most 4 MiB decoded."
          ),
        "questions" => %{
          "type" => "object",
          "minProperties" => 1,
          "maxProperties" => 400,
          "additionalProperties" => %{"anyOf" => questions}
        }
      }
    }
  end

  def normalize(arguments) when is_map(arguments) and not is_struct(arguments) do
    with true <- fields?(arguments, ~w(contractVersion state questions)),
         true <- Map.has_key?(arguments, "state") and Map.has_key?(arguments, "questions"),
         {:ok, batch, limit} <- versioned(arguments),
         true <- finite_json?(batch, @envelope_bytes, 20_002, 33),
         true <- valid_state?(batch["state"]),
         true <- valid_questions?(batch["questions"], limit),
         true <- compatible_questions?(batch, Map.get(arguments, "contractVersion")),
         true <- finite_json?(json_envelope(batch), @json_bytes, 20_000, 32) do
      {:ok, batch}
    else
      _ -> {:error, :unsupported_input}
    end
  rescue
    _ -> {:error, :unsupported_input}
  end

  def normalize(_arguments), do: {:error, :unsupported_input}

  def rubric_version(%{"questions" => questions}) do
    digest = :crypto.hash(:sha256, canonical_json(questions)) |> Base.encode16(case: :lower)
    "synapsis-decision-v1-" <> binary_part(digest, 0, 24)
  end

  def canonical_json(value), do: value |> ordered() |> Jason.encode!()

  defp question_schema(type, criteria, entry) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => if(type == "boolean", do: ["type"], else: ["type", "criteria"]),
      "properties" => %{
        "type" => %{"const" => type},
        "instructions" => entry,
        "criteria" => criteria
      }
    }
  end

  defp versioned(%{"contractVersion" => 2} = arguments),
    do: {:ok, Map.take(arguments, ~w(state questions)), 400}

  defp versioned(%{"contractVersion" => _}), do: {:error, :unsupported_input}

  defp versioned(arguments) do
    state = arguments["state"]

    if entry?(state) and finite_json?(arguments, @json_bytes, 20_000, 32) do
      tagged =
        if is_binary(state),
          do: %{"type" => "text", "text" => state},
          else: %{"type" => "json", "value" => state}

      {:ok, %{arguments | "state" => tagged}, 256}
    else
      {:error, :unsupported_input}
    end
  end

  defp valid_state?(%{"type" => "text", "text" => text} = state),
    do: fields?(state, ~w(type text)) and is_binary(text)

  defp valid_state?(%{"type" => "json", "value" => _value} = state),
    do: fields?(state, ~w(type value))

  defp valid_state?(%{"type" => "image", "dataUri" => uri} = state) when is_binary(uri) do
    fields?(state, ~w(type dataUri text)) and
      (not Map.has_key?(state, "text") or is_binary(state["text"])) and image?(uri)
  end

  defp valid_state?(%{"type" => "list", "items" => items} = state) when is_list(items) do
    fields?(state, ~w(type items)) and length(items) <= 120 and
      Enum.all?(items, fn item ->
        fields?(item, ~w(id content)) and is_binary(item["id"]) and item["id"] != "" and
          Map.has_key?(item, "content") and entry?(item["content"])
      end) and length(Enum.uniq_by(items, & &1["id"])) == length(items)
  end

  defp valid_state?(_state), do: false

  defp image?(uri) do
    with [_, encoded] <- Regex.run(~r/\Adata:image\/(?:png|jpeg|webp);base64,(.+)\z/s, uri),
         true <- byte_size(encoded) <= 4 * div(@image_bytes + 2, 3),
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) > 0 and byte_size(bytes) <= @image_bytes do
      Base.encode64(bytes) == encoded
    else
      _ -> false
    end
  end

  defp json_envelope(%{"state" => %{"type" => "text", "text" => text}} = batch),
    do: %{batch | "state" => text}

  defp json_envelope(%{"state" => %{"type" => "json", "value" => value}} = batch),
    do: %{batch | "state" => value}

  defp json_envelope(%{"state" => %{"type" => "image"} = state} = batch),
    do: %{batch | "state" => %{state | "dataUri" => ""}}

  defp json_envelope(batch), do: batch

  defp valid_questions?(questions, limit) when is_map(questions) and not is_struct(questions) do
    map_size(questions) in 1..limit and
      Enum.all?(questions, fn {id, question} ->
        is_binary(id) and id != "" and valid_question?(question)
      end)
  end

  defp valid_questions?(_questions, _limit), do: false

  defp valid_question?(%{"type" => type} = question) do
    fields?(
      question,
      if(type in ["box", "sort"], do: ~w(type instructions), else: ~w(type instructions criteria))
    ) and
      (not Map.has_key?(question, "instructions") or entry?(question["instructions"])) and
      valid_criteria?(type, question)
  end

  defp valid_question?(_question), do: false

  defp valid_criteria?("boolean", question) do
    case question["criteria"] do
      nil ->
        true

      criteria when is_map(criteria) and not is_struct(criteria) ->
        fields?(criteria, ~w(true false)) and
          Enum.all?(criteria, fn {_key, value} -> entry?(value) end)

      _ ->
        false
    end
  end

  defp valid_criteria?(type, %{"criteria" => criteria})
       when type in ["choice", "tags"] and is_map(criteria) and not is_struct(criteria) do
    map_size(criteria) >= if(type == "choice", do: 2, else: 1) and
      Enum.all?(criteria, fn {label, value} ->
        is_binary(label) and label != "" and entry?(value)
      end)
  end

  defp valid_criteria?("score", %{"criteria" => criteria}) when is_list(criteria),
    do: length(criteria) >= 2 and Enum.all?(criteria, &entry?/1)

  defp valid_criteria?("box", question), do: not is_nil(question["instructions"])
  defp valid_criteria?("sort", _question), do: true
  defp valid_criteria?(_type, _question), do: false

  defp compatible_questions?(batch, version) do
    Enum.all?(batch["questions"], fn {_id, question} ->
      (version == 2 or question["type"] in ~w(boolean choice score)) and
        case question["type"] do
          "box" -> batch["state"]["type"] == "image"
          "sort" -> batch["state"]["type"] == "list"
          _ -> true
        end
    end)
  end

  @doc "Validate provider-neutral V2 results without changing any supplied answer or estimate."
  def validate_result(batch, result, capabilities \\ nil) do
    with {:ok, normalized} <- normalize(Map.put(batch, "contractVersion", 2)),
         true <- finite_json?(result, @json_bytes, 20_000, 32),
         true <- fields?(result, ~w(model answers usage metadata)),
         model when is_binary(model) and model != "" <- result["model"],
         true <-
           div(byte_size(:unicode.characters_to_binary(model, :utf8, {:utf16, :big})), 2) <= 256,
         true <- exact_keys?(normalized["questions"], result["answers"]),
         true <- optional?(result, "metadata", &record?/1),
         true <- optional?(result, "usage", &valid_usage?/1) do
      Enum.all?(normalized["questions"], fn {id, question} ->
        valid_answer?(normalized, question, result["answers"][id], capabilities)
      end)
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_usage?(usage) do
    fields?(usage, ~w(inputTokens outputTokens costUsd units raw)) and
      Enum.all?(
        ~w(inputTokens outputTokens costUsd),
        &optional?(usage, &1, fn n -> finite?(n) and n >= 0 end)
      ) and
      optional?(usage, "units", fn units ->
        fields?(units, ~w(unit amount)) and units["unit"] in ~w(decision-units requests) and
          finite?(units["amount"]) and units["amount"] >= 0
      end)
  end

  defp valid_answer?(_batch, _question, %{"type" => "error"} = answer, _capabilities) do
    fields?(answer, ~w(type code providerCode)) and
      answer["code"] in ~w(unsupported-input invalid-input provider-error) and
      optional?(answer, "providerCode", fn code ->
        is_binary(code) and utf16_length(code) <= 128
      end)
  end

  defp valid_answer?(batch, question, answer, capabilities)
       when is_map(answer) and not is_struct(answer) do
    type = question["type"]

    answer["type"] == type and optional?(answer, "metadata", &record?/1) and
      valid_capabilities?(type, answer, capabilities) and
      answer_shape?(type, batch, question, answer)
  end

  defp valid_answer?(_, _, _, _), do: false

  defp answer_shape?("boolean", _batch, _question, answer) do
    fields?(answer, ~w(type probabilityTrue answer metadata)) and
      (Map.has_key?(answer, "answer") or Map.has_key?(answer, "probabilityTrue")) and
      optional?(answer, "probabilityTrue", &probability?/1) and
      optional?(answer, "answer", &(&1 in [nil, true, false]))
  end

  defp answer_shape?("choice", _batch, question, answer) do
    fields?(answer, ~w(type choice probabilities probability confidence metadata)) and
      Map.has_key?(answer, "choice") and
      (is_nil(answer["choice"]) or
         (is_binary(answer["choice"]) and Map.has_key?(question["criteria"], answer["choice"]))) and
      optional?(answer, "probabilities", fn values ->
        exact_keys?(question["criteria"], values) and
          Enum.all?(Map.values(values), &probability?/1)
      end) and
      optional?(answer, "probability", &(is_nil(&1) or probability?(&1))) and confidence?(answer)
  end

  defp answer_shape?("score", _batch, question, answer) do
    fields?(answer, ~w(type score probabilities confidence metadata)) and
      finite?(answer["score"]) and answer["score"] >= 0 and
      answer["score"] <= length(question["criteria"]) - 1 and
      optional?(answer, "probabilities", fn values ->
        is_list(values) and length(values) == length(question["criteria"]) and
          Enum.all?(values, &probability?/1)
      end) and confidence?(answer)
  end

  defp answer_shape?("box", _batch, _question, answer) do
    box = answer["box"]

    fields?(answer, ~w(type box confidence metadata)) and
      exact_keys?(%{"top" => 0, "bottom" => 0, "left" => 0, "right" => 0}, box) and
      Enum.all?(Map.values(box), &probability?/1) and box["top"] < box["bottom"] and
      box["left"] < box["right"] and confidence?(answer)
  end

  defp answer_shape?("sort", batch, _question, answer) do
    order = answer["order"]
    ids = Enum.map(batch["state"]["items"], & &1["id"])

    fields?(answer, ~w(type order confidence metadata)) and is_list(order) and
      Enum.sort(order) == Enum.sort(ids) and confidence?(answer)
  end

  defp answer_shape?("tags", _batch, question, answer) do
    tags = answer["tags"]

    fields?(answer, ~w(type tags metadata)) and is_list(tags) and
      Enum.all?(tags, fn tag ->
        fields?(tag, ~w(id probability applies)) and is_binary(tag["id"]) and
          Map.has_key?(tag, "applies") and tag["applies"] in [nil, true, false] and
          optional?(tag, "probability", &probability?/1)
      end) and Enum.sort(Enum.map(tags, & &1["id"])) == Enum.sort(Map.keys(question["criteria"]))
  end

  defp valid_capabilities?(_type, _answer, nil), do: true

  defp valid_capabilities?(type, answer, capabilities) when is_map(capabilities) do
    declared = get_in(capabilities, ["questions", type])

    (capabilities["confidence"] != "none" or not Map.has_key?(answer, "confidence")) and
      (not Map.has_key?(capabilities, "questions") or is_map(declared)) and
      (is_nil(declared) or declared_answer?(type, answer, declared))
  end

  defp valid_capabilities?(_, _, _), do: false

  defp declared_answer?(type, answer, declared) do
    abstention = declared["abstention"] == true

    abstention_valid =
      abstention or
        case type do
          "boolean" ->
            not (Map.has_key?(answer, "answer") and is_nil(answer["answer"]))

          "choice" ->
            not is_nil(answer["choice"])

          "tags" ->
            declared["abstention"] != false or
              Enum.all?(answer["tags"] || [], &(not is_nil(&1["applies"])))

          _ ->
            true
        end

    estimates = if type == "boolean", do: "probabilityTrue", else: "probabilities"
    probabilities = declared["probabilities"]

    estimates_valid =
      cond do
        type == "tags" ->
          Enum.all?(answer["tags"] || [], fn tag ->
            Map.has_key?(tag, "probability") != (probabilities == "none")
          end)

        type not in ~w(boolean choice score) ->
          true

        probabilities == "none" ->
          not Map.has_key?(answer, estimates) and
            (type != "choice" or not Map.has_key?(answer, "probability"))

        probabilities == "categorical" ->
          values = answer[estimates]
          values = if is_map(values), do: Map.values(values), else: values

          Map.has_key?(answer, estimates) and
            (not is_list(values) or Enum.any?(values, &(is_number(&1) and &1 > 0)))

        true ->
          Map.has_key?(answer, estimates)
      end

    abstention_valid and estimates_valid
  end

  defp exact_keys?(left, right),
    do:
      record?(left) and record?(right) and Enum.sort(Map.keys(left)) == Enum.sort(Map.keys(right))

  defp optional?(map, key, predicate), do: not Map.has_key?(map, key) or predicate.(map[key])
  defp confidence?(answer), do: optional?(answer, "confidence", &(is_nil(&1) or finite?(&1)))
  defp record?(value), do: is_map(value) and not is_struct(value)
  defp probability?(value), do: finite?(value) and value >= 0 and value <= 1

  defp utf16_length(value),
    do: div(byte_size(:unicode.characters_to_binary(value, :utf8, {:utf16, :big})), 2)

  defp entry?(value),
    do:
      is_nil(value) or is_binary(value) or is_list(value) or
        (is_map(value) and not is_struct(value))

  defp fields?(map, allowed) when is_map(map) and not is_struct(map),
    do: Enum.all?(Map.keys(map), &(&1 in allowed))

  defp fields?(_map, _allowed), do: false

  defp finite_json?(value, bytes, nodes, depth) do
    case measure(value, 0, {0, 0}, {bytes, nodes, depth}) do
      {:ok, _} -> byte_size(canonical_json(value)) <= bytes
      :error -> false
    end
  end

  defp measure(_value, depth, {count, size}, {bytes, nodes, max_depth})
       when depth > max_depth or count >= nodes or size > bytes,
       do: :error

  defp measure(value, depth, {count, size}, limits) do
    current = {count + 1, size}

    cond do
      value in [nil, true, false] ->
        {:ok, current}

      is_integer(value) ->
        if finite?(value), do: {:ok, current}, else: :error

      is_float(value) ->
        if finite?(value), do: {:ok, current}, else: :error

      is_binary(value) ->
        if String.valid?(value),
          do: bounded({count + 1, size + byte_size(value)}, limits),
          else: :error

      is_list(value) ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, current}, fn {item, index}, {:ok, {n, b}} ->
          reduce_measure(item, depth + 1, {n, b + byte_size(Integer.to_string(index))}, limits)
        end)

      is_map(value) and not is_struct(value) ->
        Enum.reduce_while(value, {:ok, current}, fn {key, item}, {:ok, {n, b}} ->
          if is_binary(key) and String.valid?(key),
            do: reduce_measure(item, depth + 1, {n, b + byte_size(key)}, limits),
            else: {:halt, :error}
        end)

      true ->
        :error
    end
  end

  defp reduce_measure(value, depth, current, limits) do
    case measure(value, depth, current, limits) do
      {:ok, next} -> {:cont, {:ok, next}}
      :error -> {:halt, :error}
    end
  end

  defp bounded({count, size} = current, {bytes, nodes, _}),
    do: if(count <= nodes and size <= bytes, do: {:ok, current}, else: :error)

  defp finite?(value) when is_number(value),
    do: value == value and abs(value) <= 1.7976931348623157e308

  defp finite?(_value), do: false

  defp ordered(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.sort_by(fn {key, _} -> utf16(key) end)
    |> Enum.map(fn {key, entry} -> {key, ordered(entry)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp utf16(key), do: :unicode.characters_to_binary(key, :utf8, {:utf16, :big})
end
