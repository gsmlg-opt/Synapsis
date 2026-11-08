defmodule Synapsis.Web.Fetch.Document do
  @moduledoc "Immutable readable-document computation, returned only after helper and broker retirement."
  alias Synapsis.Web.Fetch.PortSession

  @timeout 5_000
  @keys ~w(url finalUrl status contentType extractMode extractor externalContent truncated length rawLength text title warning)
  @required ~w(url finalUrl status contentType extractMode extractor externalContent truncated length rawLength text)

  def prepare(bytes, metadata, opts) do
    deadline = Keyword.get(opts, :deadline, now() + @timeout)
    node = Keyword.get(opts, :node_executable)

    with true <- is_binary(bytes) and byte_size(bytes) <= 750_000 and is_map(metadata),
         true <- is_binary(node) and Path.type(node) == :absolute,
         true <- is_integer(deadline) and deadline > now() and deadline - now() <= @timeout,
         {:ok, broker} <-
           PortSession.start_link(
             node_executable: node,
             helper_path:
               Keyword.get(
                 opts,
                 :helper_path,
                 Path.join(:code.priv_dir(:synapsis_core), "web_fetch/stdio.mjs")
               ),
             observer_pid: Keyword.get(opts, :observer_pid),
             owner_pid: self(),
             caller_pid: self()
           ) do
      monitor = Process.monitor(broker)
      Process.unlink(broker)

      try do
        request = %{
          "protocol" => 1,
          "id" =>
            "document:" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
          "operation" => "readable_document",
          "input" => Map.put(metadata, "bytes", Base.encode64(bytes))
        }

        prepared = broker_call(fn -> PortSession.plan(broker, request, deadline) end)
        retired = retire(broker, monitor, deadline)

        with {:ok, %{"result" => result}} <- prepared,
             :ok <- retired,
             true <- now() < deadline and valid_result?(result) do
          {:ok, result}
        else
          false -> {:error, :invalid_document}
          error -> error
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  @doc false
  def valid_result?(result) when is_map(result) and not is_struct(result) do
    Map.keys(result) -- @keys == [] and @required -- Map.keys(result) == [] and
      Enum.all?(~w(url finalUrl contentType extractMode extractor text), &valid_text?(result[&1])) and
      result["contentType"] != "" and result["extractMode"] in ["markdown", "text"] and
      is_integer(result["status"]) and result["status"] in 100..599 and
      is_integer(result["length"]) and result["length"] >= 0 and
      is_integer(result["rawLength"]) and result["rawLength"] >= 0 and
      result["length"] == utf16_length(result["text"]) and is_boolean(result["truncated"]) and
      result["externalContent"] == %{
        "untrusted" => true,
        "source" => "web_fetch",
        "wrapped" => true
      } and
      Enum.all?(~w(title warning), &(not Map.has_key?(result, &1) or valid_text?(result[&1]))) and
      :erlang.external_size(result) <= 262_144
  end

  def valid_result?(_), do: false

  defp valid_text?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 262_144

  defp utf16_length(text) do
    if String.valid?(text),
      do: div(byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})), 2),
      else: -1
  end

  defp retire(broker, monitor, deadline) do
    status = broker_call(fn -> PortSession.status(broker) end)
    closed = broker_call(fn -> PortSession.close(broker) end)

    with %{
           phase: :settled,
           outcome: :completed,
           cleanup_confirmed: true,
           exit_status: 0,
           port_released: true,
           port: port
         } <- status,
         true <- is_port(port) and Port.info(port) == nil,
         {:ok, ^status} <- closed do
      receive do
        {:DOWN, ^monitor, :process, ^broker, :normal} -> :ok
        {:DOWN, ^monitor, :process, ^broker, _} -> {:error, :helper_failed}
      after
        max(0, deadline - now()) -> {:error, :timeout}
      end
    else
      _ -> {:error, :helper_retirement_unconfirmed}
    end
  end

  defp broker_call(callback) do
    callback.()
  catch
    :exit, _ -> {:error, :helper_failed}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
