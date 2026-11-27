defmodule Synapsis.Voice.DeviceCallIntent do
  @moduledoc "Durable connection and microphone intent for a fixed Device Voice session."

  alias Synapsis.Session.Store

  @suffix "device_voice_call"
  @timeout 5_000

  def load(session_id) do
    case Store.value_snapshot(session_id, @suffix) do
      {:ok, %{value: %{active: active, muted: muted, options: options} = intent}}
      when is_boolean(active) and is_boolean(muted) ->
        case endpoint_options(options) do
          {:ok, ^options} -> {:ok, intent}
          _ -> {:error, :invalid_device_call_intent}
        end

      {:ok, _} ->
        {:error, :invalid_device_call_intent}

      other ->
        other
    end
  end

  def save(session_id, active, muted, options) when is_boolean(active) and is_boolean(muted) do
    deadline = System.monotonic_time(:millisecond) + @timeout

    with {:ok, options} <- endpoint_options(options),
         {:ok, revision} <- revision(session_id),
         remaining when remaining > 0 <- deadline - System.monotonic_time(:millisecond),
         intent = %{active: active, muted: muted, options: options},
         :ok <-
           Store.put_value_if_revision(session_id, @suffix, intent, revision, timeout: remaining) do
      {:ok, intent}
    else
      remaining when is_integer(remaining) -> {:error, :timeout}
      error -> error
    end
  end

  def save(_, _, _, _), do: {:error, :invalid_device_call_intent}

  defp revision(session_id) do
    case Store.value_snapshot(session_id, @suffix) do
      :not_found -> {:ok, 0}
      {:ok, %{revision: revision}} -> {:ok, revision}
      error -> error
    end
  end

  defp endpoint_options(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.all?(options, fn
           {:mode, "host"} -> true
           {key, value} when key in [:input_device, :output_device] -> valid_device?(value)
           _ -> false
         end) and length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) do
      {:ok, Keyword.delete(options, :mode)}
    else
      {:error, :invalid_device_call_intent}
    end
  end

  defp endpoint_options(_), do: {:error, :invalid_device_call_intent}
  defp valid_device?(nil), do: true

  defp valid_device?(device),
    do: is_binary(device) and byte_size(device) <= 512 and String.valid?(device)
end
