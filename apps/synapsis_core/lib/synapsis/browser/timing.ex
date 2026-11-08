defmodule Synapsis.Browser.Timing do
  @moduledoc """
  Pure Browser watchdog arithmetic from pinned OpenClaw act-policy.

  Model-local defaults are shallow. The exact source arithmetic is exposed
  separately from conservative allowances for existing host-only action phases.
  Runtime deadlines and callbacks are not part of this value.
  """

  alias Backplane.AgentRuntime.Error

  @maximum 2_147_000_000
  @initialize 10_000
  @settlement 13_000
  @local_defaults ~w(click type hover scrollIntoView drag select fill wait evaluate)
  @existing_timeout ~w(click clickCoords wait evaluate)

  def maximum_timeout_ms, do: @maximum
  def settlement_timeout_ms, do: @settlement

  def plan(config, arguments) when is_map(config) and is_map(arguments) do
    profiles = config["profiles"]
    all? = arguments["action"] == "profiles"
    selected = Map.get(arguments, "profile", config["default_profile"])
    args = Map.get(arguments, "args", %{})
    request = Map.get(args, "request") || args

    with true <- is_map(profiles),
         true <- all? or is_map(profiles[selected]),
         true <- arguments["action"] != "act" or bounded_request?(request) do
      outer =
        case Map.fetch(arguments, "timeout_ms") do
          {:ok, timeout} ->
            timeout

          :error when all? ->
            Enum.reduce(profiles, 0, fn {_, profile}, sum -> add(sum, profile["timeout_ms"]) end)

          :error ->
            if arguments["action"] == "act" do
              request
              |> prepare_request()
              |> host_request_timeout_ms()
            else
              profiles[selected]["timeout_ms"]
            end
        end

      count = if all?, do: map_size(profiles), else: 1

      if is_integer(outer) and outer in 1..@maximum and count in 1..8 do
        {:ok,
         %{
           outer_timeout_ms: outer,
           initialize_count: count,
           native_timeout_ms: outer + count * @initialize + @settlement
         }}
      else
        invalid_plan()
      end
    else
      _ -> invalid_plan()
    end
  end

  def plan(_, _), do: invalid_plan()

  def prepare_request(request) when is_map(request) do
    if request["kind"] in @local_defaults and not Map.has_key?(request, "timeoutMs"),
      do: Map.put(request, "timeoutMs", 60_000),
      else: request
  end

  def request_timeout_ms(request) when is_map(request), do: watchdog(request, false)
  def host_request_timeout_ms(request) when is_map(request), do: watchdog(request, true)

  defp watchdog(request, host?) do
    execution = execution_budget(request, host?)

    execution =
      cond do
        request["kind"] == "wait" ->
          execution

        request["kind"] == "batch" or is_nil(positive(request["timeoutMs"])) ->
          max(60_000, execution)

        true ->
          execution
      end

    existing = if request["kind"] == "batch", do: 0, else: existing_budget(request)
    add(max(execution, existing), 5_000)
  end

  defp existing_budget(request) do
    raw = if request["kind"] in @existing_timeout, do: integer(request["timeoutMs"])
    timeout = min(2_147_483_647, max(1, raw || 60_000))

    action =
      if request["kind"] == "wait" do
        time = nonnegative(request["timeMs"])

        conditions =
          Enum.any?(~w(text textGone selector url loadState fn), &nonblank?(request[&1]))

        if conditions, do: add(time, max(250, timeout)), else: max(time, timeout)
      else
        timeout
      end

    verification = if request["kind"] in ~w(resize close), do: 0, else: add(timeout, 1_250)
    add(action, verification)
  end

  defp execution_budget(%{"kind" => "batch"} = request, host?) do
    request
    |> Map.get("actions", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(0, fn child, total -> add(total, execution_budget(child, host?)) end)
  end

  defp execution_budget(%{"kind" => "wait"} = request, host?) do
    conditions = [
      truthy?(request["text"]),
      truthy?(request["textGone"]),
      nonblank?(request["selector"]),
      nonblank?(request["url"]),
      truthy?(request["loadState"]),
      nonblank?(request["fn"])
    ]

    count =
      Enum.count(conditions, & &1) +
        if(host? and not nonblank?(request["selector"]) and nonblank?(request["ref"]),
          do: 1,
          else: 0
        )

    add(nonnegative(request["timeMs"]), multiply(wait_timeout(request), count))
  end

  defp execution_budget(request, host?) do
    interaction = interaction_timeout(request)

    case request["kind"] do
      "click" ->
        delay = min(5_000, nonnegative(request["delayMs"]))
        grace(if(delay > 0, do: add(interaction * 2, delay), else: interaction))

      "clickCoords" ->
        delay = min(5_000, nonnegative(request["delayMs"]))

        grace(
          add(
            positive(request["timeoutMs"]) || 0,
            multiply(delay, if(truthy?(request["doubleClick"]), do: 3, else: 1))
          )
        )

      "type" ->
        phases =
          if(truthy?(request["slowly"]), do: 2, else: 1) +
            if(truthy?(request["submit"]), do: 1, else: 0)

        excess =
          if host? and truthy?(request["slowly"]) and is_binary(request["text"]) do
            # Existing host extension permits an explicit per-character delay.
            units =
              div(
                byte_size(
                  :unicode.characters_to_binary(request["text"], :utf8, {:utf16, :little})
                ),
                2
              )

            multiply(units, max(0, nonnegative(request["delayMs"]) - 75))
          else
            0
          end

        grace(add(multiply(interaction, phases), excess))

      "press" ->
        target = host? and (nonblank?(request["ref"]) or nonblank?(request["selector"]))
        grace(add(nonnegative(request["delayMs"]), if(target, do: interaction, else: 0)))

      "insertText" ->
        grace(0)

      "fill" ->
        fields = request |> Map.get("fields", []) |> List.wrap()

        count =
          Enum.count(fields, fn field ->
            is_map(field) and
              (nonblank?(field["ref"]) or (host? and nonblank?(field["selector"])))
          end)

        grace(multiply(interaction, count), count)

      kind when kind in ~w(evaluate scrollIntoView) ->
        grace(wait_timeout(request))

      "drag" ->
        grace(multiply(interaction, if(host?, do: 2, else: 1)))

      kind when kind in ~w(hover select) ->
        grace(interaction)

      _ ->
        0
    end
  end

  defp interaction_timeout(request), do: clamp(integer(request["timeoutMs"]), 8_000, 500, 60_000)
  defp wait_timeout(request), do: clamp(integer(request["timeoutMs"]), 20_000, 500, 120_000)
  defp clamp(value, fallback, lower, upper), do: min(upper, max(lower, value || fallback))
  defp grace(value, count \\ 1), do: add(value, multiply(250, count))
  defp add(left, right), do: min(@maximum, left + right)
  defp multiply(value, count), do: min(@maximum, value * count)

  defp positive(value) do
    case integer(value) do
      number when is_integer(number) and number > 0 -> min(number, @maximum)
      _ -> nil
    end
  end

  defp nonnegative(value), do: min(@maximum, max(0, integer(value) || 0))
  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: floor(value)

  defp integer(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/^[+-]?\d+$/, value) do
      {number, ""} = Integer.parse(value)
      if abs(number) <= 9_007_199_254_740_991, do: number
    end
  end

  defp integer(_), do: nil
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp truthy?(value), do: value not in [nil, false, "", 0, 0.0]

  # Match the existing helper's valid 100-descendant/depth-5 tree before doing
  # arithmetic in the bounded native admission hook. Leaf validation stays there.
  defp bounded_request?(request), do: match?({:ok, _}, scan_request(request, 0, 0))

  defp scan_request(%{"kind" => "batch", "actions" => [_ | _] = children}, depth, count)
       when depth <= 5,
       do: scan_children(children, depth, count)

  defp scan_request(%{"kind" => "batch"}, _, _), do: :error
  defp scan_request(request, _, count) when is_map(request), do: {:ok, count}
  defp scan_request(_, _, _), do: :error
  defp scan_children([], _, count), do: {:ok, count}

  defp scan_children([child | rest], depth, count) when count < 100 do
    with {:ok, count} <- scan_request(child, depth + 1, count + 1),
         do: scan_children(rest, depth, count)
  end

  defp scan_children(_, _, _), do: :error

  defp invalid_plan,
    do: {:error, Error.new(:validation, "Browser timing configuration is unavailable")}
end
