defmodule Synapsis.Provider.Decision.OpenAI do
  @moduledoc """
  Explicit native OpenAI `/decisions` transport with caller-owned evidence.

  A normalized `Synapsis.Provider.Decision` batch and atom-keyed configuration
  supply the required model, API key, effective versioned API prefix and absolute
  monotonic-millisecond deadline. No model default, config lookup, chat fallback,
  ambient conversation, file lookup or retry occurs here.

  Invoke from a supervised effect task. One linked HTTP task owns pool checkout,
  request and bounded response consumption. The remaining whole-operation budget
  is capped at 30 seconds; timeout shutdown waits for the linked task to exit.
  Successful provider decisions and estimates are translated, never recomputed.
  """

  alias Synapsis.Provider.Decision

  @max_response_bytes 1_048_576
  @timeout 30_000

  def build_request(batch, config) when is_map(batch) and is_map(config) do
    with :ok <- validate_config(config),
         {:ok, normalized} <- Decision.normalize(Map.put(batch, "contractVersion", 2)),
         true <- supports_batch?(normalized),
         true <- Map.get(config, :params, %{}) == %{},
         entries = ordered_entries(normalized["questions"]),
         body = %{
           "model" => config.model,
           "input" => input(normalized["state"]),
           "questions" => Enum.map(entries, &question/1)
         },
         remaining when remaining > 0 <- remaining(config.deadline) do
      {:ok,
       %{
         url: String.trim_trailing(config.base_url, "/") <> "/decisions",
         body: body,
         entries: entries,
         deadline: config.deadline,
         timeout_ms: min(remaining, @timeout),
         max_response_bytes: @max_response_bytes
       }}
    else
      false -> {:error, :unsupported_input}
      remaining when is_integer(remaining) -> {:error, :timeout}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def build_request(_batch, _config), do: {:error, :invalid_request}

  def evaluate(batch, config) do
    with {:ok, built} <- build_request(batch, config),
         deadline = min(built.deadline, now() + built.timeout_ms),
         timeout when timeout > 0 <- remaining(deadline) do
      built = %{built | deadline: deadline, timeout_ms: timeout}
      task = Task.async(fn -> perform(built, config) end)

      case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          if remaining(deadline) > 0, do: result, else: {:error, :timeout}

        nil ->
          {:error, :timeout}

        {:exit, _} ->
          {:error, :transport}
      end
    else
      {:error, :unsupported_input} -> unavailable("unsupported-input")
      timeout when is_integer(timeout) -> {:error, :timeout}
      {:error, _} = error -> error
    end
  end

  defp validate_config(config) do
    with true <-
           is_binary(config[:model]) and String.valid?(config.model) and
             String.trim(config.model) != "",
         true <-
           is_binary(config[:api_key]) and String.valid?(config.api_key) and config.api_key != "",
         true <- is_binary(config[:base_url]) and String.valid?(config.base_url),
         {:ok, %URI{scheme: scheme, host: host}} <- URI.new(config.base_url),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         true <- is_integer(config[:deadline]),
         headers = Map.get(config, :headers, %{}),
         true <-
           is_map(headers) and
             Enum.all?(headers, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      :ok
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp supports_batch?(batch) do
    batch["state"]["type"] in ~w(text json image) and map_size(batch["questions"]) <= 400 and
      Enum.all?(batch["questions"], fn {_id, question} ->
        question["type"] in ~w(boolean choice score) and
          (question["type"] != "choice" or map_size(question["criteria"]) <= 255)
      end)
  end

  defp ordered_entries(value) do
    value
    |> Decision.canonical_json()
    |> Jason.decode!(objects: :ordered_objects)
    |> Enum.map(fn {key, _} -> {key, Map.fetch!(value, key)} end)
  end

  defp input(%{"type" => "text", "text" => text}), do: text
  defp input(%{"type" => "json", "value" => value}), do: Decision.canonical_json(value)

  defp input(%{"type" => "image", "dataUri" => uri} = state) do
    content =
      case state["text"] do
        text when is_binary(text) and text != "" -> [%{"type" => "input_text", "text" => text}]
        _ -> []
      end

    [
      %{
        "role" => "user",
        "content" => content ++ [%{"type" => "input_image", "image_url" => uri}]
      }
    ]
  end

  defp question({name, %{"type" => "boolean"} = question}) do
    instructions = text_entry(question, "instructions")

    instructions =
      case question["criteria"] do
        criteria when is_map(criteria) ->
          instructions <>
            "\nTrue criterion: " <>
            text_entry(criteria, "true") <>
            "\nFalse criterion: " <> text_entry(criteria, "false")

        _ ->
          instructions
      end

    %{"type" => "predicate", "name" => name, "instructions" => instructions}
  end

  defp question({name, %{"type" => "choice"} = question}) do
    %{
      "type" => "choice",
      "name" => name,
      "instructions" => text_entry(question, "instructions"),
      "choices" =>
        Enum.map(ordered_entries(question["criteria"]), fn {value, description} ->
          %{"value" => value, "description" => text(description)}
        end)
    }
  end

  defp question({name, %{"type" => "score"} = question}) do
    %{
      "type" => "score",
      "name" => name,
      "instructions" => text_entry(question, "instructions"),
      "levels" =>
        question["criteria"]
        |> Enum.with_index()
        |> Enum.map(fn {description, index} ->
          %{"label" => Integer.to_string(index), "description" => text(description)}
        end)
    }
  end

  defp text_entry(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> text(value)
      :error -> ""
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(value), do: Decision.canonical_json(value)

  defp perform(built, config) do
    timeout = remaining(built.deadline)

    if timeout > 0 do
      headers =
        Map.merge(
          %{
            "authorization" => "Bearer " <> config.api_key,
            "content-type" => "application/json",
            "accept" => "application/json"
          },
          Map.new(Map.get(config, :headers, %{}), fn {key, value} ->
            {String.downcase(key), value}
          end)
        )

      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        method: :post,
        url: built.url,
        headers: headers,
        body: Jason.encode!(built.body),
        raw: true,
        compressed: false,
        into: fn event, pair -> collect(event, pair) end,
        retry: false,
        redirect: false,
        receive_timeout: timeout,
        request_timeout: timeout,
        finch: [pool_timeout: timeout]
      )
      |> Req.request()
      |> response(built.entries, config.api_key)
    else
      {:error, :timeout}
    end
  rescue
    _ -> {:error, :transport}
  catch
    :exit, _ -> {:error, :transport}
  end

  defp collect({:data, data}, {request, response}) do
    {size, chunks} = Req.Response.get_private(response, :decision_body, {0, []})

    if size + byte_size(data) <= @max_response_bytes do
      {:cont,
       {request,
        Req.Response.put_private(
          response,
          :decision_body,
          {size + byte_size(data), [data | chunks]}
        )}}
    else
      {:halt, {request, Req.Response.put_private(response, :decision_limit, true)}}
    end
  end

  defp response({:ok, response}, entries, api_key) do
    cond do
      Req.Response.get_private(response, :decision_limit, false) ->
        unavailable("invalid-response")

      response.status not in 200..299 ->
        unavailable(http_reason(response.status))

      true ->
        {_size, chunks} = Req.Response.get_private(response, :decision_body, {0, []})
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

        body =
          case body do
            <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
            _ -> body
          end

        with false <- String.contains?(body, api_key),
             {:ok, payload} when is_map(payload) <- Jason.decode(body),
             {:ok, result} <- parse_result(entries, payload) do
          {:ok, %{"status" => "ok", "result" => result}}
        else
          _ -> unavailable("invalid-response")
        end
    end
  end

  defp response({:error, _}, _entries, _api_key), do: {:error, :transport}

  defp parse_result(entries, payload) do
    with model when is_binary(model) and model != "" <- payload["model"],
         true <- utf16_length(model) <= 256,
         answers when is_list(answers) <- payload["answers"],
         true <- length(answers) == length(entries),
         {:ok, answers} <- parse_answers(Enum.zip(entries, answers)),
         %{"input_tokens" => input, "output_tokens" => output} <- payload["usage"],
         true <- nonnegative_integer?(input) and nonnegative_integer?(output) do
      {:ok,
       %{
         "model" => model,
         "answers" => answers,
         "usage" => %{"inputTokens" => input, "outputTokens" => output}
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_answers(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {{name, question}, answer}, {:ok, parsed} ->
      case parse_answer(name, question, answer) do
        {:ok, value} -> {:cont, {:ok, Map.put(parsed, name, value)}}
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp parse_answer(name, _question, %{"name" => name, "type" => "refusal"}),
    do: {:ok, %{"type" => "error", "code" => "provider-error", "providerCode" => "refusal"}}

  defp parse_answer(name, %{"type" => "boolean"}, %{
         "name" => name,
         "type" => "predicate",
         "probability" => value
       }) do
    if probability?(value),
      do: {:ok, %{"type" => "boolean", "probabilityTrue" => value}},
      else: {:error, :invalid_response}
  end

  defp parse_answer(
         name,
         %{"type" => type} = question,
         %{
           "name" => name,
           "type" => type,
           "confidence" => confidence,
           "probabilities" => probabilities
         } = answer
       )
       when type in ["choice", "score"] do
    labels =
      if type == "choice",
        do: Map.keys(question["criteria"]),
        else: Enum.map(0..(length(question["criteria"]) - 1), &Integer.to_string/1)

    with true <- finite?(confidence),
         {:ok, distribution} <- distribution(probabilities, labels, type) do
      case type do
        "choice" ->
          choice = answer["choice"]

          if is_binary(choice) and Map.has_key?(distribution, choice),
            do:
              {:ok,
               %{
                 "type" => "choice",
                 "choice" => choice,
                 "confidence" => confidence,
                 "probabilities" => distribution
               }},
            else: {:error, :invalid_response}

        "score" ->
          score = answer["score"]

          if finite?(score) and score >= 0 and score <= length(labels) - 1,
            do:
              {:ok,
               %{
                 "type" => "score",
                 "score" => score,
                 "confidence" => confidence,
                 "probabilities" => Enum.map(labels, &Map.fetch!(distribution, &1))
               }},
            else: {:error, :invalid_response}
      end
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_answer(_name, _question, _answer), do: {:error, :invalid_response}

  defp distribution(probabilities, labels, type) when is_list(probabilities) do
    key = if type == "choice", do: "value", else: "label"

    result =
      Enum.reduce_while(probabilities, {:ok, %{}}, fn item, {:ok, values} ->
        with true <- is_map(item),
             label when is_binary(label) <- item[key],
             true <- label in labels and not Map.has_key?(values, label),
             true <- probability?(item["probability"]),
             true <- type == "choice" or item["value"] == String.to_integer(label) do
          {:cont, {:ok, Map.put(values, label, item["probability"])}}
        else
          _ -> {:halt, {:error, :invalid_response}}
        end
      end)

    with {:ok, values} <- result,
         true <- map_size(values) == length(labels) and Enum.any?(Map.values(values), &(&1 > 0)) do
      {:ok, values}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp distribution(_probabilities, _labels, _type), do: {:error, :invalid_response}
  defp nonnegative_integer?(value), do: finite?(value) and value >= 0 and trunc(value) == value
  defp probability?(value), do: finite?(value) and value >= 0 and value <= 1
  defp finite?(value) when is_integer(value), do: abs(value) <= 1.7976931348623157e308

  defp finite?(value) when is_float(value),
    do: value == value and abs(value) <= 1.7976931348623157e308

  defp finite?(_value), do: false

  defp utf16_length(value),
    do: div(byte_size(:unicode.characters_to_binary(value, :utf8, {:utf16, :big})), 2)

  defp http_reason(status) when status in [401, 403], do: "authentication"
  defp http_reason(429), do: "rate-limited"
  defp http_reason(status) when status in [400, 413, 422], do: "unsupported-input"
  defp http_reason(_status), do: "transport"
  defp unavailable(reason), do: {:ok, %{"status" => "unavailable", "reason" => reason}}
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
