defmodule Synapsis.Filesystem.ReadContent do
  @moduledoc """
  Prepares an immutable byte snapshot through the packaged source read helper.

  Local owns capture and releases its path lease first. This owner never opens a
  target path. The existing PortSession owns the helper process; text is decoded
  there and normalized/paged exactly once by TextRead after normal retirement.
  Windows system-encoding resolution and native-only codec fallback remain
  prerequisites for full model-tool cutover.
  """

  alias Synapsis.Filesystem.Planner.PortSession
  alias Synapsis.Filesystem.TextRead

  @timeout 5_000
  @safe_integer 9_007_199_254_740_991
  @options [
    :node_executable,
    :helper_path,
    :observer_pid,
    :deadline,
    :prefix,
    :max_bytes,
    :model_budget,
    :model_has_vision,
    :auto_resize_images,
    :decode_mode,
    :windows_encoding
  ]

  @doc "Returns source content/details after actual helper and broker retirement."
  def prepare(bytes, args, opts) do
    with true <- is_binary(bytes) and valid_args?(args) and valid_options?(opts),
         deadline = Keyword.get(opts, :deadline, now() + @timeout),
         :ok <- valid_deadline(deadline),
         {:ok, broker} <- PortSession.start_link(broker_options(opts)) do
      monitor = Process.monitor(broker)
      # Caller/owner monitors remain in PortSession. A failed broker must not
      # turn its link into a caller crash before this owner can inspect cleanup.
      Process.unlink(broker)

      try do
        request = %{
          "protocol" => 1,
          "id" => "read:" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
          "operation" => "read_content",
          "input" => helper_input(bytes, opts)
        }

        prepared = broker_call(fn -> PortSession.plan(broker, request, deadline) end)
        retired = retire(broker, monitor, deadline)

        with {:ok, envelope} <- prepared,
             :ok <- retired,
             :ok <- current(deadline),
             {:ok, result} <- render(envelope["result"], bytes, args, opts),
             :ok <- current(deadline) do
          {:ok, result}
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    else
      false -> {:error, :invalid_input}
      error -> error
    end
  end

  defp broker_options(opts) do
    options = [
      node_executable: Keyword.fetch!(opts, :node_executable),
      helper_path:
        Keyword.get_lazy(opts, :helper_path, fn ->
          Path.join(:code.priv_dir(:synapsis_core), "filesystem_read/stdio.mjs")
        end),
      owner_pid: self(),
      caller_pid: self()
    ]

    if Keyword.has_key?(opts, :observer_pid),
      do: Keyword.put(options, :observer_pid, Keyword.fetch!(opts, :observer_pid)),
      else: options
  end

  defp helper_input(bytes, opts) do
    input = %{
      "bytes" => Base.encode64(bytes),
      "autoResizeImages" => Keyword.get(opts, :auto_resize_images, true),
      "decodeMode" =>
        if(Keyword.get(opts, :decode_mode, :local) == :local, do: "local", else: "utf8")
    }

    Enum.reduce(
      [{:model_has_vision, "modelHasVision"}, {:windows_encoding, "windowsEncoding"}],
      input,
      fn {option, field}, result ->
        case Keyword.fetch(opts, option) do
          {:ok, value} -> Map.put(result, field, value)
          :error -> result
        end
      end
    )
  end

  defp retire(broker, monitor, deadline) do
    status = broker_call(fn -> PortSession.status(broker) end)
    closed = broker_call(fn -> PortSession.close(broker) end)

    with {:ok, ^status} <- closed do
      receive do
        {:DOWN, ^monitor, :process, ^broker, :normal} ->
          if completed?(status), do: :ok, else: {:error, :planner_failed}

        {:DOWN, ^monitor, :process, ^broker, _} ->
          {:error, :planner_failed}
      after
        remaining(deadline) -> {:error, :timeout}
      end
    else
      _ -> {:error, :planner_failed}
    end
  end

  defp completed?(%{
         phase: :settled,
         outcome: :completed,
         cleanup_confirmed: true,
         exit_status: 0,
         port_released: true,
         port: port
       })
       when is_port(port),
       do: Port.info(port) == nil

  defp completed?(_), do: false

  defp broker_call(callback) do
    callback.()
  catch
    :exit, _ -> {:error, :planner_failed}
  end

  defp render(%{"kind" => "text", "text" => text}, bytes, args, opts) do
    page_options =
      opts
      |> Keyword.take([:prefix, :max_bytes, :model_budget])
      |> Keyword.put(:source_bytes, byte_size(bytes))

    TextRead.page(text, args, page_options)
  end

  defp render(%{"kind" => "result", "result" => result}, _bytes, _args, opts) do
    prefix = Keyword.get(opts, :prefix, "")
    [first | rest] = result["content"]
    text = prefix <> first["text"]

    content =
      [%{type: "text", text: text}] ++
        Enum.map(rest, fn image ->
          %{type: "image", data: image["data"], mimeType: image["mimeType"]}
        end)

    details = %{kind: result["details"]["kind"], content: text}

    details =
      case result["details"] do
        %{"mimeType" => mime} -> Map.put(details, :mimeType, mime)
        _ -> details
      end

    {:ok, %{content: content, details: details}}
  end

  defp valid_args?(args) do
    is_map(args) and not is_struct(args) and Map.keys(args) -- ~w(offset cursor limit) == [] and
      Enum.all?(args, fn
        {"offset", n} -> is_integer(n) and n >= 1 and n <= @safe_integer
        {"cursor", n} -> is_integer(n) and n >= 0 and n <= @safe_integer
        {"limit", n} -> is_number(n)
      end)
  end

  defp valid_options?(opts) do
    Keyword.keyword?(opts) and Keyword.keys(opts) -- @options == [] and
      absolute?(Keyword.get(opts, :node_executable)) and Enum.all?(opts, &valid_option?/1)
  end

  defp valid_option?({name, path}) when name in [:node_executable, :helper_path],
    do: absolute?(path)

  defp valid_option?({:observer_pid, pid}), do: is_pid(pid)
  defp valid_option?({:deadline, deadline}), do: is_integer(deadline)
  defp valid_option?({:prefix, prefix}), do: is_binary(prefix) and String.valid?(prefix)
  defp valid_option?({:max_bytes, n}), do: is_integer(n) and n > 0 and n <= @safe_integer
  defp valid_option?({:model_budget, nil}), do: true

  defp valid_option?({:model_budget, %{maxChars: chars, maxContextChars: context} = budget}),
    do:
      not is_struct(budget) and map_size(budget) == 2 and is_number(chars) and
        is_number(context) and chars >= 0 and context >= 0

  defp valid_option?({name, value}) when name in [:model_has_vision, :auto_resize_images],
    do: is_boolean(value)

  defp valid_option?({:decode_mode, mode}), do: mode in [:local, :utf8]

  defp valid_option?({:windows_encoding, encoding}),
    do:
      is_binary(encoding) and String.valid?(encoding) and String.trim(encoding) != "" and
        not String.contains?(encoding, "\0")

  defp valid_option?(_), do: false

  defp absolute?(path),
    do:
      is_binary(path) and String.valid?(path) and byte_size(path) in 1..4_096 and
        Path.type(path) == :absolute and not String.contains?(path, "\0")

  defp valid_deadline(deadline) do
    remaining = remaining(deadline)
    if remaining > 0 and remaining <= @timeout, do: :ok, else: {:error, :invalid_deadline}
  end

  defp current(deadline), do: if(now() < deadline, do: :ok, else: {:error, :timeout})
  defp remaining(deadline), do: max(0, deadline - now())
  defp now, do: System.monotonic_time(:millisecond)
end
