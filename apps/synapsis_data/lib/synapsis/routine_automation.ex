defmodule Synapsis.RoutineAutomation do
  @moduledoc "Presence-aware configuration normalization for version-one automations."

  @optional_overrides ~w(provider model)
  @optional_delivery_fields ~w(channel to accountId threadId)
  @space "[\\x{0009}-\\x{000D}\\x{0020}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
  @leading_space Regex.compile!("\\A" <> @space <> "+", "u")
  @trailing_space Regex.compile!(@space <> "+\\z", "u")

  @doc "Prepare a routine against the latest serialized entry without changing legacy defaults."
  def prepare(attrs, current) do
    original = attrs
    attrs = stringify_keys(attrs)
    current = if is_map(current), do: stringify_keys(current)

    if attrs["automation_contract_version"] === 1 or
         (current && current["automation_contract_version"] === 1) do
      attrs
      |> preserve_origin(current)
      |> merge_delivery(current)
      |> clear_optional_fields(@optional_overrides)
      |> maybe_create_defaults(current)
    else
      original
    end
  end

  @doc "Validate the effective delivery after presence-aware merge, including cold loads."
  def validate_delivery(%{"automation_contract_version" => 1} = attrs) do
    case Map.fetch(attrs, "delivery") do
      :error -> :ok
      {:ok, %{"mode" => mode}} when mode in ["announce", "none"] -> :ok
      {:ok, %{"mode" => "webhook", "to" => target}} -> validate_webhook_target(target)
      _ -> {:error, {:invalid_routine, :delivery}}
    end
  end

  def validate_delivery(_attrs), do: :ok

  defp validate_webhook_target(target) when is_binary(target) do
    case URI.new(target) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        :ok

      _ ->
        {:error, {:invalid_routine, :delivery}}
    end
  end

  defp validate_webhook_target(_target), do: {:error, {:invalid_routine, :delivery}}

  defp preserve_origin(attrs, %{"automation_contract_version" => 1} = current) do
    attrs = Map.put(attrs, "automation_contract_version", 1)

    case Map.fetch(current, "automation_origin") do
      {:ok, origin} -> Map.put(attrs, "automation_origin", origin)
      :error -> Map.delete(attrs, "automation_origin")
    end
  end

  defp preserve_origin(attrs, _current), do: attrs

  defp merge_delivery(attrs, current) do
    previous = if is_map(current), do: current["delivery"]

    case Map.fetch(attrs, "delivery") do
      {:ok, delivery} when is_map(delivery) ->
        delivery = if is_map(previous), do: Map.merge(previous, delivery), else: delivery
        Map.put(attrs, "delivery", clear_optional_fields(delivery, @optional_delivery_fields))

      :error when is_map(previous) ->
        Map.put(attrs, "delivery", previous)

      _ ->
        attrs
    end
  end

  defp clear_optional_fields(attrs, fields) do
    Enum.reduce(fields, attrs, fn field, acc ->
      if Map.get(acc, field, :omitted) == nil, do: Map.delete(acc, field), else: acc
    end)
  end

  # A persisted cadence identity also identifies a cold-loaded existing entry.
  # Loading it must not reapply create defaults omitted by an earlier update.
  defp maybe_create_defaults(attrs, nil) do
    if is_binary(attrs["schedule_fingerprint"]) do
      attrs
    else
      attrs
      |> Map.put_new("enabled", true)
      |> Map.put("name", create_name(attrs))
      |> Map.put("session_target", create_session_target(attrs))
      |> Map.put_new("wake_mode", "now")
      |> Map.put_new("delivery", %{"mode" => "announce"})
      |> Map.put_new("tool_profile", "native_agent")
      |> default_one_shot()
    end
  end

  defp maybe_create_defaults(attrs, _current), do: attrs

  defp create_session_target(attrs) do
    case Map.get(attrs, "session_target", "current") do
      "current" -> default_session_target(attrs)
      target -> target
    end
  end

  defp default_session_target(%{"automation_origin" => %{"session_id" => session_id}})
       when is_binary(session_id) do
    if trim(session_id) == "", do: "isolated", else: "current"
  end

  defp default_session_target(_attrs), do: "isolated"

  defp default_one_shot(%{"schedule" => %{"kind" => "at"}} = attrs),
    do: Map.put_new(attrs, "deleteAfterRun", true)

  defp default_one_shot(attrs), do: attrs

  defp create_name(attrs) do
    case attrs["name"] do
      name when is_binary(name) ->
        case trim(name) do
          "" -> infer_name(attrs)
          name -> name
        end

      _ ->
        infer_name(attrs)
    end
  end

  defp infer_name(attrs) do
    prompt = if is_binary(attrs["prompt"]), do: attrs["prompt"], else: ""

    first_line =
      prompt
      |> String.split("\n")
      |> Enum.map(&trim/1)
      |> Enum.find(&(&1 != ""))

    if first_line, do: truncate(first_line, 60), else: schedule_name(attrs["schedule"])
  end

  defp schedule_name(%{"kind" => "cron", "expr" => expr}) when is_binary(expr),
    do: "Cron: " <> truncate(expr, 52)

  defp schedule_name(%{"kind" => "every", "everyMs" => period}) when is_integer(period),
    do: "Every: #{period}ms"

  defp schedule_name(%{"kind" => "at"}), do: "One-shot"
  defp schedule_name(_schedule), do: "Automation"

  # The reference counts UTF-16 units and reserves one unit for the ellipsis.
  # Work in code points so a two-unit emoji can never be split at the boundary.
  defp truncate(text, limit) do
    points = String.to_charlist(text)
    length = Enum.reduce(points, 0, fn point, acc -> acc + utf16_width(point) end)

    if length <= limit do
      text
    else
      {prefix, _width} =
        Enum.reduce_while(points, {[], 0}, fn point, {prefix, width} ->
          next_width = width + utf16_width(point)

          if next_width <= limit - 1,
            do: {:cont, {[point | prefix], next_width}},
            else: {:halt, {prefix, width}}
        end)

      prefix |> Enum.reverse() |> List.to_string() |> trim_end() |> Kernel.<>("…")
    end
  end

  defp utf16_width(point) when point > 0xFFFF, do: 2
  defp utf16_width(_point), do: 1

  defp trim(text), do: Regex.replace(@leading_space, text, "") |> trim_end()
  defp trim_end(text), do: Regex.replace(@trailing_space, text, "")

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), if(is_map(value), do: stringify_keys(value), else: value)}
    end)
  end
end
