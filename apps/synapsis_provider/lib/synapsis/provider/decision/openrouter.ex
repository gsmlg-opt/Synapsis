defmodule Synapsis.Provider.Decision.OpenRouter do
  @moduledoc """
  Native OpenRouter `/systemone` decisions for explicit Jev models and evidence.

  The host supplies a normalized batch, effective API prefix, private headers,
  optional merged provider preferences and absolute monotonic deadline. Invoke
  from a supervised effect task. The linked HTTP task consumes at most one MiB
  within the whole-operation budget and never retries or falls back to chat.
  Native answers, fractional scores, box coordinates and billed usage are retained.
  """

  alias Synapsis.Provider.Decision

  @models ~w(typesafe/jev-1.13 typesafe/jev-1.14 ~typesafe/jev-latest)
  @max_response_bytes 1_048_576
  @timeout 30_000
  @capabilities %{
    "questions" => %{
      "boolean" => %{"probabilities" => "boolean", "abstention" => false},
      "choice" => %{"probabilities" => "categorical", "abstention" => false},
      "score" => %{"probabilities" => "categorical", "abstention" => false},
      "box" => %{"probabilities" => "none", "abstention" => false}
    }
  }

  def build_request(batch, config) when is_map(batch) and is_map(config) do
    with :ok <- validate_config(config),
         {:ok, normalized} <- Decision.normalize(Map.put(batch, "contractVersion", 2)),
         true <- config.model in @models and supports_batch?(normalized, config.model),
         params = Map.get(config, :params, %{}),
         true <-
           is_map(params) and not is_struct(params) and
             Enum.all?(Map.keys(params), &(&1 == "provider")),
         remaining when remaining > 0 <- remaining(config.deadline) do
      questions =
        Map.new(normalized["questions"], fn {id, question} ->
          {id,
           if(question["type"] == "boolean", do: %{question | "type" => "noul"}, else: question)}
        end)

      body =
        Map.merge(
          %{
            "model" => config.model,
            "state" => state(normalized["state"]),
            "questions" => questions
          },
          params
        )

      {:ok,
       %{
         url: String.trim_trailing(config.base_url, "/") <> "/systemone",
         body: body,
         batch: normalized,
         deadline: config.deadline,
         timeout_ms: min(remaining, @timeout),
         max_response_bytes: @max_response_bytes
       }}
    else
      false -> {:error, :unsupported_input}
      remaining when is_integer(remaining) -> {:error, :timeout}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def build_request(_, _), do: {:error, :invalid_request}

  def evaluate(batch, config) do
    with {:ok, built} <- build_request(batch, config),
         deadline = min(built.deadline, now() + built.timeout_ms),
         timeout when timeout > 0 <- remaining(deadline) do
      built = %{built | deadline: deadline, timeout_ms: timeout}
      task = Task.async(fn -> perform(built, config) end)

      case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> if remaining(deadline) > 0, do: result, else: {:error, :timeout}
        nil -> {:error, :timeout}
        {:exit, _} -> {:error, :transport}
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

  defp supports_batch?(batch, model) do
    state = batch["state"]

    state_supported =
      case state do
        %{"type" => "text"} ->
          true

        %{"type" => "json", "value" => value} ->
          is_binary(value) or is_list(value) or (is_map(value) and not is_struct(value))

        %{"type" => "image", "dataUri" => uri} ->
          String.starts_with?(uri, ["data:image/png;base64,", "data:image/jpeg;base64,"])

        _ ->
          false
      end

    state_supported and
      Enum.all?(batch["questions"], fn {_id, question} ->
        not is_nil(question["instructions"]) and
          case question["type"] do
            "box" ->
              model != "typesafe/jev-1.13"

            "choice" ->
              map_size(question["criteria"]) <= 255

            "score" ->
              length(question["criteria"]) <= 10 and
                Enum.all?(question["criteria"], &(not is_nil(&1)))

            "boolean" ->
              not Map.has_key?(question, "criteria") or
                (is_map(question["criteria"]) and not is_nil(question["criteria"]["true"]) and
                   not is_nil(question["criteria"]["false"]))

            _ ->
              false
          end
      end)
  end

  defp state(%{"type" => "text", "text" => text}), do: text
  defp state(%{"type" => "json", "value" => value}), do: value

  defp state(%{"type" => "image", "dataUri" => uri} = image) do
    if(Map.has_key?(image, "text"), do: [image["text"]], else: []) ++
      [%{"type" => "image_url", "image_url" => %{"url" => uri}}]
  end

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
      |> response(built, config.api_key)
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

  defp response({:ok, response}, built, api_key) do
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
             {:ok, result} <- parse_result(built.batch, payload) do
          {:ok, %{"status" => "ok", "result" => result}}
        else
          _ -> unavailable("invalid-response")
        end
    end
  end

  defp response({:error, _}, _built, _api_key), do: {:error, :transport}

  defp parse_result(batch, payload) do
    usage = payload["usage"]

    with true <-
           is_map(usage) and safe_integer?(usage["input_tokens"]) and
             safe_integer?(usage["output_tokens"]),
         true <- not Map.has_key?(payload, "provider") or is_binary(payload["provider"]),
         answers when is_map(answers) <- payload["answers"],
         {:ok, answers} <- parse_answers(batch, answers) do
      converted_usage = %{
        "inputTokens" => usage["input_tokens"],
        "outputTokens" => usage["output_tokens"]
      }

      converted_usage =
        if Map.has_key?(usage, "cost"),
          do: Map.put(converted_usage, "costUsd", usage["cost"]),
          else: converted_usage

      converted_usage =
        if Enum.any?(Map.keys(usage), &(&1 not in ~w(input_tokens output_tokens cost))),
          do: Map.put(converted_usage, "raw", usage),
          else: converted_usage

      result = %{"model" => payload["model"], "answers" => answers, "usage" => converted_usage}

      result =
        if Map.has_key?(payload, "provider"),
          do: Map.put(result, "metadata", %{"provider" => payload["provider"]}),
          else: result

      if Decision.validate_result(batch, result, @capabilities),
        do: {:ok, result},
        else: {:error, :invalid_response}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp parse_answers(batch, answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, answer}, {:ok, parsed} ->
      case parse_answer(batch["questions"][id], answer) do
        {:ok, converted} -> {:cont, {:ok, Map.put(parsed, id, converted)}}
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
  end

  defp parse_answer(_question, %{"type" => "noul", "noul" => value}),
    do: {:ok, %{"type" => "boolean", "probabilityTrue" => value}}

  defp parse_answer(question, %{"type" => type, "confidence" => confidence} = answer)
       when type in ~w(choice score box) do
    if probability?(confidence) do
      case type do
        "choice" ->
          {:ok, Map.take(answer, ~w(type choice probabilities confidence))}

        "box" ->
          {:ok, Map.take(answer, ~w(type box confidence))}

        "score" ->
          probabilities = answer["probabilities"]

          if is_map(question) and question["type"] == "score" and is_map(probabilities) and
               Enum.sort(Map.keys(probabilities)) ==
                 Enum.sort(Enum.map(0..(length(question["criteria"]) - 1), &Integer.to_string/1)) do
            {:ok,
             %{
               "type" => "score",
               "score" => answer["score"],
               "confidence" => confidence,
               "probabilities" =>
                 Enum.map(
                   0..(length(question["criteria"]) - 1),
                   &Map.fetch!(probabilities, Integer.to_string(&1))
                 )
             }}
          else
            {:error, :invalid_response}
          end
      end
    else
      {:error, :invalid_response}
    end
  end

  defp parse_answer(_, _), do: {:error, :invalid_response}

  defp safe_integer?(value),
    do:
      is_number(value) and value >= 0 and value <= 9_007_199_254_740_991 and trunc(value) == value

  defp probability?(value), do: is_number(value) and value == value and value >= 0 and value <= 1
  defp http_reason(status) when status in [401, 403], do: "authentication"
  defp http_reason(status) when status in [429, 529], do: "rate-limited"
  defp http_reason(status) when status in [400, 413, 422], do: "unsupported-input"
  defp http_reason(_), do: "transport"
  defp unavailable(reason), do: {:ok, %{"status" => "unavailable", "reason" => reason}}
  defp now, do: System.monotonic_time(:millisecond)
  defp remaining(deadline), do: max(deadline - now(), 0)
end
