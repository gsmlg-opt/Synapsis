defmodule Synapsis.Agent.Tools.LLMTask.Request do
  @moduledoc """
  Prepares one task from task data and explicitly resolved host inputs.

  Only prompt, input and schema are interpreted from the string-keyed task map.
  Provider context, normalized request options and finite limits must already be
  resolved by the admitted caller. This module selects no model, credential,
  alias, default or thinking policy and performs no configuration reads.

  The reference envelope uses newline separators around native
  two-space pretty JSON. Original nonblank prompt bytes and native JSON values
  are preserved. Native object ordering, integer precision and number spelling
  follow Jason rather than JavaScript JSON.stringify; no byte equivalence is
  claimed. The schema remains separate from the prompt.
  """

  alias Backplane.AgentRuntime.Error

  @whitespace ~S(\x{0009}-\x{000D}\x{0020}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF})
  @blank Regex.compile!("\\A[#{@whitespace}]*\\z", "u")

  @spec prepare(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def prepare(task, resolved) when is_map(task) and is_map(resolved) do
    input = Map.get(task, "input")

    with %{"prompt" => prompt} <- task,
         true <- is_binary(prompt) and String.valid?(prompt),
         false <- Regex.match?(@blank, prompt),
         %{
           provider_context: %{provider_config: config, request_options: options} = provider,
           timeout_ms: timeout,
           output_limit: limit
         } <- resolved,
         true <- is_map(config) and is_map(options),
         true <- is_binary(options[:model]) and options[:model] != "",
         true <- is_integer(timeout) and timeout in 1..3_600_000,
         true <- is_integer(limit) and limit > 0,
         {:ok, input_json} <- Jason.encode(input, pretty: true),
         {:ok, ^input} <- Jason.decode(input_json) do
      {:ok,
       %{
         prompt: "TASK:\n#{prompt}\n\nINPUT_JSON:\n#{input_json}\n",
         schema: active_schema(task["schema"]),
         provider_context: provider,
         timeout_ms: timeout,
         output_limit: limit
       }}
    else
      _ -> invalid()
    end
  end

  def prepare(_, _), do: invalid()

  defp active_schema(schema) when is_map(schema) and not is_struct(schema), do: schema
  defp active_schema(_schema), do: nil

  defp invalid,
    do:
      {:error,
       Error.new(
         :validation,
         "LLM task requires a nonblank prompt, JSON input and resolved host inputs"
       )}
end
